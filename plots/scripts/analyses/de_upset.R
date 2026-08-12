# Multi-comparison DE gene overlap -- every non-reference level of group_var
# gets its own DESeq2 contrast against the same reference (fit ONCE, each
# comparison is just a different coefficient of that one model -- no re-
# fitting per comparison), split into up-/down-regulated gene sets, then
# UpSet-plotted separately (same ComplexUpset recipe as MAGMA's
# upset_plot.R, ported to gene sets instead of taxon sets -- see that
# script's own citations for why ComplexUpset over UpSetR). Modeled directly
# on the user's own real prior multi-condition RNA-seq workflow (Acid/Basic/
# Temperature vs Control -> UpSet of up-regulated + UpSet of down-regulated
# -> a "core" gene list per direction, the intersection present in every
# comparison) -- same statistical content, this app's own house visual style
# (serif/background/title-bar), not a visual clone of the reference figures.
# DEFINE-only; see plots/manifest.yaml for parameter descriptions.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "deseq_helpers.R"))

suppressMessages({
  library(DESeq2)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(ComplexUpset)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(alpha = "0.05", min_lfc = "1"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
group_var <- args$group_var
reference_group <- args$reference_group
alpha <- as.numeric(args$alpha)
min_lfc <- as.numeric(args$min_lfc)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"

log_line("[de_upset] reading cached count matrix from %s", args$count_matrix_rds)
count_data <- readRDS(args$count_matrix_rds)
log_line("[de_upset] count matrix: %d genes x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var, reference_group)

# One coefficient per non-reference level, all from the SAME fitted model --
# resultsNames(dds)[1] is always "Intercept", every one after it is a real
# "<group_var>_<level>_vs_<reference>" comparison (DESeq2's own treatment-
# contrast naming, confirmed against its documented behavior).
comparison_coefs <- resultsNames(dds)[-1]
if (length(comparison_coefs) < 2) {
  stop(sprintf(
    "de_upset needs at least 2 non-reference levels of '%s' to compare (found %d) -- with only one, this is the same as volcano_plot/de_heatmap and there's nothing to overlap.",
    group_var, length(comparison_coefs)
  ))
}
comparison_levels <- sub("_vs_.*$", "", sub(paste0("^", group_var, "_"), "", comparison_coefs))
log_line("[de_upset] %d comparisons vs reference '%s': %s", length(comparison_levels), reference_group, paste(comparison_levels, collapse = ", "))

up_sets <- list()
down_sets <- list()
for (i in seq_along(comparison_coefs)) {
  res <- as.data.frame(results(dds, name = comparison_coefs[i])) %>%
    tibble::rownames_to_column("locus_tag") %>%
    filter(!is.na(padj))
  lvl <- comparison_levels[i]
  up_sets[[lvl]] <- res %>% filter(padj < alpha, log2FoldChange > min_lfc) %>% pull(locus_tag)
  down_sets[[lvl]] <- res %>% filter(padj < alpha, log2FoldChange < -min_lfc) %>% pull(locus_tag)
  log_line("[de_upset] %s vs %s: %d up, %d down (padj < %g, |log2FC| > %g)",
            lvl, reference_group, length(up_sets[[lvl]]), length(down_sets[[lvl]]), alpha, min_lfc)
}

# Every non-empty intersection (2^n - 1 combinations) -- same brute-force,
# independently-checkable computation upset_plot.R uses for taxa, applied
# here to gene sets instead.
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
# The "core" set -- present in EVERY comparison, the reference user workflow's
# own specific deliverable (core_UP_3condicoes.txt/core_DOWN_3condicoes.txt) --
# is just the intersection using every level, i.e. the one keyed by all names.
core_key <- paste(comparison_levels, collapse = " & ")
core_up <- up_intersections[[core_key]] %||% character(0)
core_down <- down_intersections[[core_key]] %||% character(0)
log_line("[de_upset] core (DE in all %d comparisons): %d up, %d down", length(comparison_levels), length(core_up), length(core_down))

palette <- resolve_palette(comparison_levels, style)

build_presence_df <- function(sets) {
  all_genes <- unique(unlist(sets))
  df <- data.frame(gene = all_genes, stringsAsFactors = FALSE)
  for (lvl in names(sets)) df[[lvl]] <- all_genes %in% sets[[lvl]]
  df
}

build_upset_panel <- function(sets, direction_label) {
  if (length(unlist(sets)) == 0) return(NULL)
  df <- build_presence_df(sets)
  # A real, reproduced crash: ComplexUpset errors deep inside ggplot2's own
  # rendering ("Aesthetics must be either length 1 or the same as the
  # data") when a `upset_query(set =...)` targets a set with ZERO members
  # -- entirely plausible in real multi-comparison data, e.g. one condition
  # simply has no significant genes in this direction while others do (not
  # a degenerate/synthetic-only edge case). Only query sets that actually
  # have at least one member; an empty set still gets its own (zero-height)
  # bar from ComplexUpset itself, just without a custom color -- same
  # "don't crash over a cosmetic detail" reasoning already used elsewhere
  # (e.g. ma_plot's lfcShrink fallback).
  non_empty_levels <- comparison_levels[lengths(sets[comparison_levels]) > 0]
  queries <- lapply(non_empty_levels, function(lvl) ComplexUpset::upset_query(set = lvl, fill = unname(palette[[lvl]])))
  p <- ComplexUpset::upset(df, comparison_levels, name = group_var, width_ratio = 0.25, min_size = 1, queries = queries, sort_sets = "descending")
  p <- p & theme(text = element_text(family = font_family, color = "black"),
                 # colour = NA and no plot.background repaint, both deliberate: patchwork's
                 # `&` adds this to each of ComplexUpset's sub-plots, whose own
                 # panel.background is element_blank -- and an element_rect merged onto a
                 # blank does not inherit theme_grey's borderless panel, it falls back to
                 # the top-level `rect` element, i.e. a BLACK border around every
                 # sub-plot. Painting plot.background as well made the body span
                 # edge-to-edge while the title bar only paints its panel, so the title
                 # band came out narrower than the figure by exactly one plot margin.
                 panel.background = element_rect(fill = bg, colour = NA))
  with_title_bar(patchwork::wrap_elements(full = p), paste0(direction_label, "-regulated (padj < ", alpha, ", |log2FC| > ", min_lfc, ")"),
                 size = 6, title_height = 0.1, font_family = font_family,
                 plot_width_in = max(9, length(comparison_levels) * 2.5))
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

up_panel <- build_upset_panel(up_sets, "Up")
down_panel <- build_upset_panel(down_sets, "Down")
panels <- Filter(Negate(is.null), list(up_panel, down_panel))
if (length(panels) == 0) {
  log_line("[de_upset] no DE genes in either direction for any comparison -- writing an empty result, no plot")
  write_json(
    list(analysis_id = "de_upset", group_var = group_var, reference_group = reference_group,
         comparisons = comparison_levels, core_up = list(), core_down = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  quit(save = "no", status = 0)
}

# wrap_elements around each panel is required, not cosmetic -- same real
# bug already found and fixed for taxonomic_composition.R:
# each panel here is already its own nested patchwork (with_title_bar's own
# title-bar/plot `/` stack, itself wrapping ComplexUpset's own internal
# multi-panel layout). Combining two or more such nested patchwork objects
# with a bare `/` makes patchwork flatten them into one shared patch list,
# discarding each panel's own layout and crashing wrap_dims ("need N
# panels, but only provide N-1") the moment there's more than one
# panel -- confirmed, reproduces with exactly 2 panels (up+down),
# not just a many-panel scaling issue. wrap_elements protects each panel
# as one opaque unit instead.
final_plot <- Reduce(`/`, lapply(panels, patchwork::wrap_elements)) + patchwork::plot_layout(heights = rep(1, length(panels)))
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = max(9, length(comparison_levels) * 2.5), height = 6 * length(panels),
       units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = max(9, length(comparison_levels) * 2.5), height = 6 * length(panels)),
        file.path(args$out_dir, "plot_final.rds"))

# Plain one-gene-per-line text files alongside data.json -- the exact
# deliverable shape the reference workflow's own core_UP_3condicoes.txt/
# core_DOWN_3condicoes.txt used, not just numbers buried in JSON.
writeLines(core_up, file.path(args$out_dir, "core_up_genes.txt"))
writeLines(core_down, file.path(args$out_dir, "core_down_genes.txt"))

format_intersections <- function(intersections) {
  lapply(names(intersections), function(nm) list(sets = nm, n_genes = length(intersections[[nm]]), genes = intersections[[nm]]))
}
write_json(
  list(analysis_id = "de_upset", group_var = group_var, reference_group = reference_group,
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
        file.path(args$out_dir, "de_upset.rds"))

log_line("[de_upset] wrote data.json, default_style.json, de_upset.rds, core_up_genes.txt, core_down_genes.txt, preview.png")
