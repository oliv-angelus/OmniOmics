# UpSet plot of taxa present (above --min_abundance) per level of
# --group_var -- the many-groups alternative to venn_diagram.R (which caps
# at 4 sets; Shade & Handelsman 2012). Set computation is a direct copy of
# venn_diagram.R's (kept independently checkable there too);
# only the plotting library and the no-cap validation differ.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))

suppressMessages({
  library(phyloseq)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(ComplexUpset)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(rank = "Genus", min_abundance = "0.0"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
rank <- args$rank
min_abundance <- as.numeric(args$min_abundance)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"

log_line("[upset_plot] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[upset_plot] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

groups <- unique(as.character(data.frame(sample_data(ps))[[group_var]]))
groups <- groups[!is.na(groups)]
# No upper cap -- that's the entire point of this analysis vs. venn_diagram's
# 4-set limit. Still needs >= 2 sets to compare, same as Venn.
if (length(groups) < 2) stop(sprintf("group_var '%s' needs at least 2 levels to compare -- found %d.", group_var, length(groups)))

ps_rel <- transform_sample_counts(ps, function(x) x / sum(x))
ps_glom <- if (rank == "ASV") ps_rel else tax_glom(ps_rel, taxrank = rank, NArm = FALSE)
tax_info <- as.data.frame(tax_table(ps_glom))

taxon_label <- function(taxon_id) {
  if (rank == "ASV") return(taxon_id)
  label <- tax_info[taxon_id, rank]
  if (is.na(label)) "Unclassified" else label
}

present_sets <- lapply(groups, function(g) {
  ps_g <- prune_samples(sample_names(ps_glom)[data.frame(sample_data(ps_glom))[[group_var]] == g], ps_glom)
  mean_abund <- taxa_sums(ps_g) / nsamples(ps_g)
  taxon_ids <- names(mean_abund)[mean_abund > min_abundance]
  unique(vapply(taxon_ids, taxon_label, character(1)))
})
names(present_sets) <- groups

log_line("[upset_plot] set sizes: %s", paste(sprintf("%s=%d", groups, lengths(present_sets)), collapse = ", "))

all_taxa <- unique(unlist(present_sets))
if (length(all_taxa) == 0) stop("No taxon met --min_abundance in any group -- try lowering it.")

# Every non-empty intersection (2^n - 1 combinations) -- same brute-force,
# independently-checkable computation venn_diagram.R uses, kept identical so
# data.json stays directly comparable between the two analyses. For a large
# group count this is more combinations than the plot itself will show (see
# n_intersections below), but it's the same computation regardless of group
# count and cheap relative to the DIAMOND/DESeq2/etc. steps elsewhere in the
# app.
intersections <- list()
for (k in seq_along(groups)) {
  combos <- combn(groups, k, simplify = FALSE)
  for (combo in combos) {
    in_all <- Reduce(intersect, present_sets[combo])
    if (length(in_all) > 0) {
      intersections[[paste(combo, collapse = " & ")]] <- in_all
    }
  }
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

intersections_json <- lapply(names(intersections), function(nm) {
  list(sets = nm, n_taxa = length(intersections[[nm]]), taxa = intersections[[nm]])
})

write_json(
  list(analysis_id = "upset_plot", group_var = group_var, rank = rank, min_abundance = min_abundance,
       set_sizes = as.list(stats::setNames(lengths(present_sets), groups)),
       intersections = intersections_json),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# Resolved BEFORE building effective_style, same reasoning/bug precedent as
# every other group-palette analysis (see style_io.R's default_style_for_groups
# docstring): write exactly the palette the plot uses, not a fresh one.
palette <- resolve_palette(groups, style)

effective_style <- default_style_for_groups(groups, legend_position = "none", show_labels = FALSE,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(present_sets = present_sets, intersections = intersections), file.path(args$out_dir, "upset_plot.rds"))

# Binary presence/absence matrix, one row per observed taxon, one logical
# column per group -- ComplexUpset's expected input shape (a data.frame with
# `groups` as the "indicator" columns, passed as its own `intersect` arg).
presence_df <- data.frame(
  taxon = all_taxa,
  stringsAsFactors = FALSE
)
for (g in groups) presence_df[[g]] <- all_taxa %in% present_sets[[g]]

# Above ~40 present intersection combinations the bar strip becomes as
# unreadable as an unlabeled point cloud (same class of large-N cramping
# already handled elsewhere -- see taxonomic_composition's/core_microbiome's
# width scaling and beta_diversity's/rda's/rarefaction_curve's label-drop
# threshold) -- ComplexUpset's own `n_intersections` caps the bar strip to
# the N largest, which is the standard published mitigation (the same
# largest-first prioritization `upset` already sorts by).
n_present_combos <- length(intersections)
n_intersections_shown <- min(n_present_combos, 40)

# One `upset_query` per group colors that group's own "Set size" bar with
# our regular Dark2 (or user-overridden) palette -- ComplexUpset's
# documented way to recolor a specific set's row/bar (`set = <name>`
# targets the set-size panel; there is no non-hacky way to also tint the
# matrix dots per-group without per-intersection color blending, so those
# stay ComplexUpset's own black/gray "on/off" dots, same scope-cut
# reasoning already applied to core_microbiome's/goods_coverage's
# non-multi-key-palette analyses).
queries <- lapply(groups, function(g) ComplexUpset::upset_query(set = g, fill = unname(palette[[g]])))

p <- ComplexUpset::upset(
  presence_df, groups,
  name = group_var,
  width_ratio = 0.25,
  min_size = 1,
  n_intersections = n_intersections_shown,
  queries = queries,
  sort_sets = "descending"
)

# ComplexUpset composes its own sub-plots via patchwork internally; `&`
# broadcasts one theme addition across every one of them (matrix, bars, set
# size panel) in one shot -- the same trick used for the Venn diagram's plain
# `theme(...)` call, just via patchwork's operator since this is several
# ggplot objects, not one.
# Two deliberate details, both user-reported defects:
#
# colour = NA is not optional. element_rect(fill = ...) with no colour does
# not keep theme_grey's borderless panel -- ComplexUpset's sub-plots have
# panel.background = element_blank, and an element_rect merged onto a blank
# inherits its missing properties from the top-level `rect` element, i.e.
# colour "black". That drew a black box around every sub-plot, which is what
# made the set-size bars look like they overflowed their panel.
#
# And plot.background is deliberately NOT repainted. plot.background covers
# the plot margin too, while title_bar() only paints its panel -- so the
# body spanned edge-to-edge and the title band did not, coming out narrower
# than the figure by exactly one plot margin on each side.
p <- p & theme(
  text = element_text(family = font_family, color = "black"),
  panel.background = element_rect(fill = bg, colour = NA)
)

title <- paste0("Shared/Unique Taxa (", rank, ", > ", min_abundance * 100, "% mean rel. abundance): ", group_var,
                 if (n_present_combos > n_intersections_shown) paste0(" -- top ", n_intersections_shown, " of ", n_present_combos, " intersections") else "")

# wrap_elements protects ComplexUpset's own nested patchwork layout from
# being flattened by with_title_bar's outer `/`. A nested patchwork loses its
# own height ratios when a parent layout combines it, which is what crashes
# taxonomic_composition's multi-panel path without this. venn_diagram.R does
# not need it: ggVennDiagram returns a single plain ggplot, not a nested
# patchwork the way ComplexUpset does.
width <- max(9, n_intersections_shown * 0.35)
final_plot <- with_title_bar(patchwork::wrap_elements(full = p), title, size = 6, title_height = 0.08, font_family = font_family, plot_width_in = width)

height <- max(6, 4 + length(groups) * 0.3)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

log_line("[upset_plot] wrote data.json, default_style.json, upset_plot.rds, preview.png (%d sets, %d/%d intersections shown)",
          length(groups), n_intersections_shown, n_present_combos)
