# Community taxonomy for MAGMA, from either of the run's two independently
# built classifications -- or from both at once.
#
# MAGMA classifies the same reads twice, by genuinely different methods:
# Kraken2/Bracken matches nucleotide k-mers, Kaiju translates and matches
# proteins (see 01_qc_tax.smk's consolidate_taxonomy / _kaiju). They are not
# interchangeable line-by-line: Kaiju tends to assign more reads in samples
# with a lot of taxonomic novelty, because amino-acid similarity survives
# more sequence divergence than nucleotide k-mer matching.
#
# --classifier picks which question is being asked:
#   kraken2  stacked relative-abundance bars from the Kraken2/Bracken table
#   kaiju    the same figure from the Kaiju table
#   compare  how much the two agree -- total abundance per taxon side by
#            side, plus which taxa each classifier calls that the other
#            misses. Agreement between two independent methods is itself
#            evidence, not merely a choice between them.
#
# One analysis rather than three, so the classifier is a toggle on a single
# card instead of near-duplicate cards. The bar-chart modes reuse the same
# panel builder as the shared taxonomic_composition.R (lib/composition_panels.R)
# rather than a second copy of that logic.

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
source(file.path(lib_dir, "composition_panels.R"))

suppressMessages({
  library(phyloseq)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(patchwork)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(classifier = "kraken2", rank = "all", top_n = "20"))
classifier <- args$classifier
top_n_taxa <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

VALID <- c("kraken2", "kaiju", "compare")
if (!(classifier %in% VALID)) {
  stop(sprintf("--classifier must be one of: %s (got '%s')", paste(VALID, collapse = ", "), classifier))
}

# Both cached objects live in the same folder: /api/plots/load builds every
# input shape a pipeline needs into one out_dir (see main.py's
# INPUT_SHAPE_INFO), and this analysis is handed the Kraken one.
kraken_rds <- args$phyloseq_rds
kaiju_rds <- file.path(dirname(kraken_rds), "phyloseq_kaiju.rds")

read_kaiju <- function() {
  if (!file.exists(kaiju_rds)) {
    stop(sprintf(paste0("No Kaiju-classified object at %s -- this run was loaded before Kaiju support ",
                        "existed, or its results folder has no abundance_table_final_kaiju_RAW.tsv. ",
                        "Reload this run's metadata (Trocar metadados) to rebuild both classifiers."),
                 kaiju_rds))
  }
  readRDS(kaiju_rds)
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

if (classifier == "compare") {
  ps_kraken <- readRDS(kraken_rds)
  ps_kaiju <- read_kaiju()
  log_line("[magma_community_taxonomy] compare: Kraken2/Bracken %d taxa, Kaiju %d taxa, %d samples",
           ntaxa(ps_kraken), ntaxa(ps_kaiju), nsamples(ps_kraken))

  # Summed at the finest rank both objects share -- neither classifier's own
  # leaf identifiers match the other's, so the lineage string is the only
  # common ground.
  summarize_one <- function(ps, label) {
    rank <- if ("Species" %in% rank_names(ps)) "Species" else rank_names(ps)[length(rank_names(ps))]
    glom <- tax_glom(ps, taxrank = rank, NArm = FALSE)
    df <- psmelt(glom)
    df[[rank]] <- as.character(df[[rank]])
    df[[rank]][is.na(df[[rank]])] <- "Unclassified"
    df %>% group_by(taxon = .data[[rank]]) %>%
      summarise(total_reads = sum(Abundance), .groups = "drop") %>%
      mutate(classifier = label)
  }

  combined <- bind_rows(summarize_one(ps_kraken, "Kraken2/Bracken"), summarize_one(ps_kaiju, "Kaiju"))
  wide <- combined %>% pivot_wider(names_from = classifier, values_from = total_reads, values_fill = 0)
  kcol <- "Kraken2/Bracken"; jcol <- "Kaiju"
  wide$total <- wide[[kcol]] + wide[[jcol]]
  wide <- wide %>% arrange(desc(total))

  n_shared <- sum(wide[[kcol]] > 0 & wide[[jcol]] > 0)
  n_kraken_only <- sum(wide[[kcol]] > 0 & wide[[jcol]] == 0)
  n_kaiju_only <- sum(wide[[kcol]] == 0 & wide[[jcol]] > 0)
  log_line("[magma_community_taxonomy] %d taxa found by both, %d Kraken2-only, %d Kaiju-only",
           n_shared, n_kraken_only, n_kaiju_only)

  top_taxa <- wide %>% slice_head(n = top_n_taxa) %>% pull(taxon)
  plot_df <- combined %>%
    mutate(Taxon_Plot = ifelse(taxon %in% top_taxa, taxon, "Others")) %>%
    group_by(classifier, Taxon_Plot) %>%
    summarise(total_reads = sum(total_reads), .groups = "drop")
  order <- if ("Others" %in% plot_df$Taxon_Plot) c(top_taxa, "Others") else top_taxa
  plot_df$Taxon_Plot <- factor(plot_df$Taxon_Plot, levels = order)
  plot_df$classifier <- factor(plot_df$classifier, levels = c("Kraken2/Bracken", "Kaiju"))

  palette <- resolve_palette(as.character(plot_df$Taxon_Plot), style)
  p <- ggplot(plot_df, aes(x = classifier, y = total_reads, fill = Taxon_Plot)) +
    geom_col(position = "fill", width = 0.65) +
    scale_y_continuous(labels = scales::percent) +
    scale_fill_manual(values = palette, name = "Taxon") +
    labs(x = NULL, y = "Relative abundance (combined across samples)") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(legend.position = "right")

  title <- sprintf("Classifier Concordance  |  %d shared, %d Kraken2-only, %d Kaiju-only",
                   n_shared, n_kraken_only, n_kaiju_only)
  final_plot <- with_title_bar(p, title, size = 10, font_family = font_family)

  write_json(
    list(analysis_id = "magma_community_taxonomy", classifier = "compare",
         n_taxa_kraken = sum(wide[[kcol]] > 0), n_taxa_kaiju = sum(wide[[jcol]] > 0),
         n_shared = n_shared, n_kraken_only = n_kraken_only, n_kaiju_only = n_kaiju_only,
         taxa = lapply(seq_len(nrow(wide)), function(i) list(
           taxon = wide$taxon[i], kraken_reads = wide[[kcol]][i], kaiju_reads = wide[[jcol]][i],
           found_by = if (wide[[kcol]][i] > 0 && wide[[jcol]][i] > 0) "both"
                      else if (wide[[kcol]][i] > 0) "kraken_only" else "kaiju_only"))),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  width <- 9; height <- 7
  effective_style <- default_style_for_groups(as.character(plot_df$Taxon_Plot), legend_position = "right",
                                              show_labels = TRUE, background = bg,
                                              font_family = font_family, palette = palette)
  saveRDS(wide, file.path(args$out_dir, "magma_community_taxonomy.rds"))
} else {
  ps <- if (classifier == "kaiju") read_kaiju() else readRDS(kraken_rds)
  log_line("[magma_community_taxonomy] %s: %d taxa x %d samples", classifier, ntaxa(ps), nsamples(ps))

  ranks_to_plot <- resolve_ranks_to_plot(ps, args$rank)
  panels <- lapply(ranks_to_plot, function(rk)
    build_taxonomic_panel(ps, rk, top_n_taxa, style, bg, font_family, font_scale, hide_x_axis, hide_y_axis))
  names(panels) <- ranks_to_plot

  write_json(
    list(analysis_id = "magma_community_taxonomy", classifier = classifier,
         ranks = taxonomic_panels_json(panels)),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  final_plot <- combine_taxonomic_panels(panels)
  width <- max(12, nsamples(ps) * 0.35)
  height <- 7 * length(panels)
  # First plotted rank's palette, same convention taxonomic_composition.R
  # uses: in "all" mode each rank has its own independent top-N, so there is
  # no single shared key space to export.
  effective_style <- list(palette = as.list(panels[[1]]$palette), legend_position = "right",
                          show_labels = FALSE, background = bg, font_family = font_family)
  saveRDS(list(ps = ps, panels = panels), file.path(args$out_dir, "magma_community_taxonomy.rds"))
}

ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 120, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

log_line("[magma_community_taxonomy] wrote data.json, default_style.json, magma_community_taxonomy.rds, preview.png, plot_final.rds")
