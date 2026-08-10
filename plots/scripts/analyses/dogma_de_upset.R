# Multi-comparison differential-gene-family overlap -- the DOGMA analogue
# of DEFINE's de_upset.R (same ComplexUpset recipe, same one-model-fit/
# per-coefficient-comparison design; see that script's own header for the
# full citation trail). Entirely generic over "locus_tag"-shaped IDs in the
# original, so this ports over gene-family IDs (e.g. "ko:K00370") with only
# the aggregation-step and label changes.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "build_dogma_table.R"))
source(file.path(lib_dir, "deseq_helpers.R"))

suppressMessages({
  library(DESeq2)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(ComplexUpset)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(annotation_column = "eggnog_KEGG_ko", alpha = "0.05", min_lfc = "1"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
annotation_col <- args$annotation_column
group_var <- args$group_var
reference_group <- args$reference_group
alpha <- as.numeric(args$alpha)
min_lfc <- as.numeric(args$min_lfc)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"

log_line("[dogma_de_upset] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
count_data <- aggregate_dogma_counts(loaded$long_table, annotation_col, loaded$coldata)
log_line("[dogma_de_upset] aggregated count matrix: %d gene families x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var, reference_group)

comparison_coefs <- resultsNames(dds)[-1]
if (length(comparison_coefs) < 2) {
  stop(sprintf(
    "dogma_de_upset needs at least 2 non-reference levels of '%s' to compare (found %d) -- with only one, this is the same as dogma_ma_plot/dogma_de_heatmap and there's nothing to overlap.",
    group_var, length(comparison_coefs)
  ))
}
comparison_levels <- sub("_vs_.*$", "", sub(paste0("^", group_var, "_"), "", comparison_coefs))
log_line("[dogma_de_upset] %d comparisons vs reference '%s': %s", length(comparison_levels), reference_group, paste(comparison_levels, collapse = ", "))

up_sets <- list()
down_sets <- list()
for (i in seq_along(comparison_coefs)) {
  res <- as.data.frame(results(dds, name = comparison_coefs[i])) %>%
    tibble::rownames_to_column("gene_family") %>%
    filter(!is.na(padj))
  lvl <- comparison_levels[i]
  up_sets[[lvl]] <- res %>% filter(padj < alpha, log2FoldChange > min_lfc) %>% pull(gene_family)
  down_sets[[lvl]] <- res %>% filter(padj < alpha, log2FoldChange < -min_lfc) %>% pull(gene_family)
  log_line("[dogma_de_upset] %s vs %s: %d up, %d down (padj < %g, |log2FC| > %g)",
            lvl, reference_group, length(up_sets[[lvl]]), length(down_sets[[lvl]]), alpha, min_lfc)
}

all_intersections <- function(sets) {
  names_ <- names(sets)
  out <- list()
  for (k in seq_along(names_)) {
    for (combo in combn(names_, k, simplify = FALSE)) {
      in_all <- Reduce(intersect, sets[combo])
      if (length(in_all) > 0) out[[paste(combo, collapse = " & ")]] <- in_all
    }
  }
  out
}
up_intersections <- all_intersections(up_sets)
down_intersections <- all_intersections(down_sets)
core_key <- paste(comparison_levels, collapse = " & ")
core_up <- up_intersections[[core_key]] %||% character(0)
core_down <- down_intersections[[core_key]] %||% character(0)
log_line("[dogma_de_upset] core (DE in all %d comparisons): %d up, %d down", length(comparison_levels), length(core_up), length(core_down))

palette <- resolve_palette(comparison_levels, style)

build_presence_df <- function(sets) {
  all_families <- unique(unlist(sets))
  df <- data.frame(gene_family = all_families, stringsAsFactors = FALSE)
  for (lvl in names(sets)) df[[lvl]] <- all_families %in% sets[[lvl]]
  df
}

build_upset_panel <- function(sets, direction_label) {
  if (length(unlist(sets)) == 0) return(NULL)
  df <- build_presence_df(sets)
  # Same real ComplexUpset crash already documented in de_upset.R -- only
  # query sets with >=1 member.
  non_empty_levels <- comparison_levels[lengths(sets[comparison_levels]) > 0]
  queries <- lapply(non_empty_levels, function(lvl) ComplexUpset::upset_query(set = lvl, fill = unname(palette[[lvl]])))
  p <- ComplexUpset::upset(df, comparison_levels, name = group_var, width_ratio = 0.25, min_size = 1, queries = queries, sort_sets = "descending")
  p <- p & theme(text = element_text(family = font_family, color = "black"),
                 panel.background = element_rect(fill = bg), plot.background = element_rect(fill = bg, color = NA))
  with_title_bar(patchwork::wrap_elements(full = p), paste0(direction_label, "-regulated (", annotation_col, ", padj < ", alpha, ", |log2FC| > ", min_lfc, ")"),
                 size = 6, title_height = 0.1, font_family = font_family)
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

up_panel <- build_upset_panel(up_sets, "Up")
down_panel <- build_upset_panel(down_sets, "Down")
panels <- Filter(Negate(is.null), list(up_panel, down_panel))
if (length(panels) == 0) {
  log_line("[dogma_de_upset] no DE gene families in either direction for any comparison -- writing an empty result, no plot")
  write_json(
    list(analysis_id = "dogma_de_upset", annotation_column = annotation_col, group_var = group_var, reference_group = reference_group,
         comparisons = comparison_levels, core_up = list(), core_down = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  quit(save = "no", status = 0)
}

# wrap_elements around each panel required -- see de_upset.R's own
# comment on this exact bug (found here first, then confirmed pre-existing
# in DEFINE's original de_upset.R too and fixed there as well).
final_plot <- Reduce(`/`, lapply(panels, patchwork::wrap_elements)) + patchwork::plot_layout(heights = rep(1, length(panels)))
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = max(9, length(comparison_levels) * 2.5), height = 6 * length(panels),
       units = "in", dpi = 150, bg = "white", limitsize = FALSE)

writeLines(core_up, file.path(args$out_dir, "core_up_gene_families.txt"))
writeLines(core_down, file.path(args$out_dir, "core_down_gene_families.txt"))

format_intersections <- function(intersections) {
  lapply(names(intersections), function(nm) list(sets = nm, n_gene_families = length(intersections[[nm]]), gene_families = intersections[[nm]]))
}
write_json(
  list(analysis_id = "dogma_de_upset", annotation_column = annotation_col, group_var = group_var, reference_group = reference_group,
       comparisons = comparison_levels, alpha = alpha, min_lfc = min_lfc,
       up_set_sizes = as.list(stats::setNames(lengths(up_sets), comparison_levels)),
       down_set_sizes = as.list(stats::setNames(lengths(down_sets), comparison_levels)),
       up_intersections = format_intersections(up_intersections),
       down_intersections = format_intersections(down_intersections),
       core_up = core_up, core_down = core_down),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(comparison_levels, legend_position = "none", show_labels = FALSE,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(up_sets = up_sets, down_sets = down_sets, up_intersections = up_intersections, down_intersections = down_intersections),
        file.path(args$out_dir, "dogma_de_upset.rds"))

log_line("[dogma_de_upset] wrote data.json, default_style.json, dogma_de_upset.rds, core_up_gene_families.txt, core_down_gene_families.txt, preview.png")
