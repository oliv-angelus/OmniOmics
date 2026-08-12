# The mobilome of a genome collection: plasmids, prophages and insertion
# sequences, plus the question that ties them to the resistome -- is a
# resistance gene sitting on a mobile element or on the chromosome?
#
# That question is why this analysis exists. A resistance gene on the
# chromosome is inherited vertically and stays in its lineage; the same gene on
# a conjugative plasmid can cross between species. Which of the two it is
# changes what the result means for surveillance, and neither the AMR heatmap
# nor the plasmid profile answers it alone -- it needs both, joined on the
# contig.
#
# One analysis with a --view toggle rather than four near-identical cards,
# the same shape the community/functional cards already use.
#
# Every column and literal value read here was verified against the tools' own
# source code -- see docs/tool_output_samples/VERIFIED_FORMATS.md.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
# For CHECKV_QUALITY_LEVELS: the five tiers are an ORDERED categorical scale
# and the order is part of the format, so it lives beside the reader that
# verified it rather than being restated (and left to drift) here.
source(file.path(lib_dir, "build_sigma_table.R"))

suppressMessages({
  library(dplyr)
  library(ggplot2)
  library(jsonlite)
})

VIEWS <- c("amr_location", "plasmid_mobility", "plasmid_replicons", "prophage_quality",
           "is_families", "bgc_class", "bgc_family")

#' Collapses everything outside the top-N into "Others", as an ordered factor.
#'
#' unique() on the levels is load-bearing, not defensive tidiness: a tool can
#' report a category LITERALLY named "Others" -- antiSMASH has an "other"
#' product class -- and it then appears both in the kept set and as the
#' collapse bucket, which factor() rejects outright ("factor level is
#' duplicated"). Shared by the three views that collapse a long tail, so the
#' collision is handled once rather than three times.
top_n_factor <- function(values, n) {
  values[is.na(values) | values == ""] <- "unclassified"
  keep <- names(sort(table(values), decreasing = TRUE))[seq_len(min(n, length(unique(values))))]
  collapsed <- ifelse(values %in% keep, values, "Others")
  factor(collapsed, levels = unique(c(keep, "Others"))[unique(c(keep, "Others")) %in% collapsed])
}

args <- parse_cli_args(defaults = list(view = "amr_location", top_n = "25"))
view <- args$view
top_n <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

if (!(view %in% VIEWS)) {
  stop(sprintf("--view must be one of: %s (got '%s')", paste(VIEWS, collapse = ", "), view))
}

log_line("[sigma_mobilome] reading cached SIGMA table from %s", args$sigma_table_rds)
loaded <- readRDS(args$sigma_table_rds)
mob <- loaded$mobilome %||% list()
bgc <- loaded$bgc %||% list()

#' Refuses a view whose tool did not run, naming the tool -- an empty figure
#' would otherwise be indistinguishable from "this genome collection genuinely
#' has no plasmids", which is a completely different result.
require_table <- function(tbl, tool, what) {
  if (is.null(tbl) || nrow(tbl) == 0) {
    stop(sprintf("This run has no %s output, so '%s' cannot be drawn. %s is an optional step in SIGMA -- enable it and re-run to get this view.",
                 tool, view, what))
  }
  tbl
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
records <- list()
extra <- list()

if (view == "amr_location") {
  contigs <- require_table(mob$contigs, "MOB-suite", "Plasmid reconstruction")
  hits <- loaded$gene_hits
  if (is.null(hits) || nrow(hits) == 0) stop("This run has no AMR/virulence gene hits to locate.")
  if (!("contig" %in% colnames(hits))) {
    stop("The cached table was built before gene hits carried their contig -- reload this run (Trocar metadados) to rebuild it.")
  }
  hits$contig <- sub("[[:space:]].*$", "", as.character(hits$contig))

  joined <- left_join(hits, contigs[, c("sample", "contig", "molecule_type", "predicted_mobility")],
                      by = c("sample", "contig"))
  # Reported, not silently tolerated: a zero match rate means the two tools
  # disagree about contig naming, which is exactly the failure this join was
  # written to survive (see .first_token in build_sigma_table.R). Saying so is
  # the difference between "no plasmid-borne AMR" and "the join broke".
  matched <- sum(!is.na(joined$molecule_type))
  log_line("[sigma_mobilome] %d of %d gene hit(s) matched a MOB-suite contig (%.1f%%)",
           matched, nrow(joined), 100 * matched / nrow(joined))
  if (matched == 0) {
    stop("None of this run's gene hits could be matched to a MOB-suite contig -- the two tools are reporting different contig identifiers, so the plasmid/chromosome location cannot be determined. This is a naming mismatch, not an absence of plasmid-borne genes.")
  }

  joined$Location <- ifelse(is.na(joined$molecule_type), "unplaced",
                            ifelse(joined$molecule_type == "plasmid",
                                   ifelse(is.na(joined$predicted_mobility) | joined$predicted_mobility == "",
                                          "plasmid", paste0("plasmid (", joined$predicted_mobility, ")")),
                                   "chromosome"))
  # Ordered so the reader's eye goes chromosome -> increasingly mobile.
  lev <- c("chromosome", "plasmid (non-mobilizable)", "plasmid (mobilizable)",
           "plasmid (conjugative)", "plasmid", "unplaced")
  joined$Location <- factor(joined$Location, levels = lev[lev %in% unique(joined$Location)])

  agg <- joined %>% count(sample, Location, name = "n_genes")
  palette <- resolve_palette(levels(agg$Location), style)
  p <- ggplot(agg, aes(x = sample, y = n_genes, fill = Location)) +
    geom_col(width = 0.75) +
    scale_fill_manual(values = palette, name = NULL) +
    labs(x = NULL, y = "AMR / virulence gene hits") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
  title <- sprintf("Where the resistance genes sit  |  %d/%d hits placed on a MOB-suite contig",
                   matched, nrow(joined))
  fill_levels <- levels(agg$Location)
  records <- lapply(seq_len(nrow(agg)), function(i)
    list(genome = agg$sample[i], location = as.character(agg$Location[i]), n_genes = agg$n_genes[i]))
  extra <- list(hits_total = nrow(joined), hits_placed = matched)

} else if (view %in% c("plasmid_mobility", "plasmid_replicons")) {
  plasmids <- require_table(mob$plasmids, "MOB-suite", "Plasmid reconstruction")
  if (view == "plasmid_mobility") {
    plasmids$Key <- ifelse(is.na(plasmids$predicted_mobility) | plasmids$predicted_mobility == "",
                           "unknown", plasmids$predicted_mobility)
    lev <- c("conjugative", "mobilizable", "non-mobilizable", "unknown")
    plasmids$Key <- factor(plasmids$Key, levels = lev[lev %in% unique(plasmids$Key)])
    y_lab <- "Reconstructed plasmids"
    title <- "Plasmid mobility per genome"
  } else {
    # rep_type(s) is a comma-separated list (mob-suite utils.py:1139) -- a
    # plasmid carrying two replicons genuinely belongs to both, so it is
    # counted in both rather than the pair becoming its own bucket.
    plasmids <- plasmids %>%
      mutate(rep_types = ifelse(is.na(rep_types) | rep_types == "" | rep_types == "-", "untyped", rep_types)) %>%
      tidyr::separate_rows(rep_types, sep = ",") %>%
      mutate(rep_types = trimws(rep_types)) %>%
      filter(nzchar(rep_types))
    plasmids$Key <- top_n_factor(plasmids$rep_types, top_n)
    y_lab <- "Plasmid replicon hits"
    title <- "Plasmid replicon types per genome"
  }
  agg <- plasmids %>% count(sample, Key, name = "n")
  palette <- resolve_palette(levels(agg$Key), style)
  p <- ggplot(agg, aes(x = sample, y = n, fill = Key)) +
    geom_col(width = 0.75) +
    scale_fill_manual(values = palette, name = NULL) +
    labs(x = NULL, y = y_lab) +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
  fill_levels <- levels(agg$Key)
  records <- lapply(seq_len(nrow(agg)), function(i)
    list(genome = agg$sample[i], key = as.character(agg$Key[i]), n = agg$n[i]))

} else if (view == "prophage_quality") {
  checkv <- require_table(mob$checkv, "CheckV", "Viral/prophage detection")
  checkv$Key <- factor(ifelse(is.na(checkv$checkv_quality), "Not-determined", checkv$checkv_quality),
                       levels = CHECKV_QUALITY_LEVELS[CHECKV_QUALITY_LEVELS %in%
                                  unique(ifelse(is.na(checkv$checkv_quality), "Not-determined", checkv$checkv_quality))])
  agg <- checkv %>% count(sample, Key, name = "n")
  palette <- resolve_palette(levels(agg$Key), style)
  p <- ggplot(agg, aes(x = sample, y = n, fill = Key)) +
    geom_col(width = 0.75) +
    scale_fill_manual(values = palette, name = "CheckV quality") +
    labs(x = NULL, y = "Predicted proviruses") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
  title <- "Prophage content per genome, by CheckV completeness tier"
  fill_levels <- levels(agg$Key)
  records <- lapply(seq_len(nrow(agg)), function(i)
    list(genome = agg$sample[i], checkv_quality = as.character(agg$Key[i]), n = agg$n[i]))

} else if (view == "bgc_class") {
  # Class comes from BiG-SCAPE's record_annotations.tsv, which carries
  # antiSMASH's own product class per region -- antiSMASH itself writes no
  # tabular output at all, so this is the cheap path to the same information.
  regions <- require_table(bgc$regions, "BiG-SCAPE", "Secondary-metabolite clustering")
  regions$Key <- top_n_factor(regions$bgc_class, top_n)
  agg <- regions %>% count(sample, Key, name = "n")
  palette <- resolve_palette(levels(agg$Key), style)
  p <- ggplot(agg, aes(x = sample, y = n, fill = Key)) +
    geom_col(width = 0.75) +
    scale_fill_manual(values = palette, name = "BGC class") +
    labs(x = NULL, y = "Biosynthetic gene clusters") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
  title <- sprintf("Biosynthetic gene clusters by class (%d regions)", nrow(regions))
  fill_levels <- levels(agg$Key)
  records <- lapply(seq_len(nrow(agg)), function(i)
    list(genome = agg$sample[i], bgc_class = as.character(agg$Key[i]), n = agg$n[i]))

} else if (view == "bgc_family") {
  # Gene cluster families: BiG-SCAPE groups similar BGCs across genomes, so a
  # family present in several genomes is a shared biosynthetic capability
  # while a singleton family is that genome's own. Counting DISTINCT families
  # per genome, not regions, is what makes the two different questions.
  fams <- require_table(bgc$families, "BiG-SCAPE", "Secondary-metabolite clustering")
  shared <- fams %>% distinct(sample, family) %>% count(family, name = "n_genomes")
  fams <- left_join(distinct(fams, sample, family), shared, by = "family")
  fams$Key <- ifelse(fams$n_genomes == 1, "unique to one genome",
                     ifelse(fams$n_genomes >= 3, "shared by 3+ genomes", "shared by 2 genomes"))
  fams$Key <- factor(fams$Key, levels = c("unique to one genome", "shared by 2 genomes", "shared by 3+ genomes"))
  agg <- fams %>% count(sample, Key, name = "n")
  palette <- resolve_palette(levels(agg$Key), style)
  p <- ggplot(agg, aes(x = sample, y = n, fill = Key)) +
    geom_col(width = 0.75) +
    scale_fill_manual(values = palette, name = NULL) +
    labs(x = NULL, y = "Distinct gene cluster families") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
  title <- sprintf("Gene cluster families per genome (%d distinct families in the run)",
                   length(unique(fams$family)))
  fill_levels <- levels(agg$Key)
  records <- lapply(seq_len(nrow(agg)), function(i)
    list(genome = agg$sample[i], sharing = as.character(agg$Key[i]), n_families = agg$n[i]))

} else {
  isescan <- require_table(mob$isescan, "ISEScan", "Insertion-sequence detection")
  isescan$Key <- top_n_factor(isescan$is_family, top_n)
  agg <- isescan %>% count(sample, Key, name = "n")
  palette <- resolve_palette(levels(agg$Key), style)
  p <- ggplot(agg, aes(x = sample, y = n, fill = Key)) +
    geom_col(width = 0.75) +
    scale_fill_manual(values = palette, name = "IS family") +
    labs(x = NULL, y = "Insertion sequences") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
  title <- "Insertion-sequence families per genome"
  fill_levels <- levels(agg$Key)
  records <- lapply(seq_len(nrow(agg)), function(i)
    list(genome = agg$sample[i], is_family = as.character(agg$Key[i]), n = agg$n[i]))
}

p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)
n_genomes <- length(unique(agg$sample))
width <- max(10, n_genomes * 0.55)
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.08,
                             font_family = font_family, plot_width_in = width)

write_json(
  c(list(analysis_id = "sigma_mobilome", view = view, records = records), extra),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

height <- 7
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(fill_levels, legend_position = "right", show_labels = FALSE,
                                          background = bg, font_family = font_family, palette = palette),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(agg, file.path(args$out_dir, "sigma_mobilome.rds"))

log_line("[sigma_mobilome] view=%s: wrote data.json, default_style.json, sigma_mobilome.rds, preview.png, plot_final.rds", view)
