# Beta diversity (PCoA/NMDS/CAP ordination + PERMANOVA) on gene-family- (or
# taxon-, via --annotation_column) aggregated counts -- the DOGMA analogue
# of MAGMA/PRISM's beta_diversity.R, reusing phyloseq/vegan's own
# ordination engine unchanged via lib/build_dogma_table.R's
# build_dogma_phyloseq. No unifrac/wunifrac here (unlike PRISM's own
# beta_diversity.R usage) -- there is no real phylogeny between arbitrary
# functional categories to build a tree from, only bray/jaccard make sense.
# Answers "is the community's overall functional/taxonomic profile
# different between conditions", complementing dogma_functional_
# composition/differential's "which specific gene family changed".
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

suppressMessages({
  library(phyloseq)
  library(vegan)
  library(ggplot2)
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(
  annotation_column = "eggnog_KEGG_ko",
  ordination_method = "PCoA",
  distance_method = "bray",
  permutations = "999",
  seed = "123"
))

if (is.null(args$group_var) || args$group_var == "") {
  stop("--group_var is required")
}

annotation_col <- args$annotation_column
group_var   <- args$group_var
ord_method  <- args$ordination_method
dist_method <- args$distance_method
permutations <- as.integer(args$permutations)
seed        <- as.integer(args$seed)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[dogma_functional_beta_diversity] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
ps <- build_dogma_phyloseq(loaded$long_table, annotation_col, loaded$coldata)
log_line("[dogma_functional_beta_diversity] aggregated phyloseq object: %d gene families/taxa x %d samples (by %s)", ntaxa(ps), nsamples(ps), annotation_col)

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

# Same real guard as beta_diversity.R -- PCoA/NMDS/CAP need >=3 samples for
# a 2-axis ordination.
if (nsamples(ps) < 3) {
  stop(sprintf("Beta diversity needs at least 3 samples to compute a 2-axis ordination (this run has %d).",
               nsamples(ps)))
}

# Real, edge case: phyloseq's
# own rarefy_even_depth crashes outright on a single-taxon object
# ("attempt to set 'rownames' on an object with no dimensions", confirmed
# by reproducing it directly against a minimal 1-row phyloseq object) -- a
# real internal phyloseq limitation, not fixable from outside it. Also the
# scientifically correct place to stop regardless (a single category has
# zero compositional variation to ordinate/PERMANOVA by).
if (ntaxa(ps) < 2) {
  stop(sprintf(
    "Aggregating by '%s' leaves only %d gene famil%s/taxon across this whole run -- too few for a meaningful beta diversity ordination (and phyloseq's own rarefaction crashes outright on exactly one). Try a different --annotation_column with more real categories.",
    annotation_col, ntaxa(ps), if (ntaxa(ps) == 1) "y" else "ies"))
}

set.seed(seed)
min_reads <- min(sample_sums(ps))
ps_rar <- rarefy_even_depth(ps, sample.size = min_reads, replace = FALSE, rngseed = seed, verbose = FALSE)
log_line("[dogma_functional_beta_diversity] rarefied to %d reads/sample (%d gene families/taxa survived)", min_reads, ntaxa(ps_rar))

dist_matrix <- phyloseq::distance(ps_rar, method = dist_method)

# Same real all-zero-distance guard as beta_diversity.R (see that script's
# own comment for the full unifrac-specific story) -- kept here for the
# general case (e.g. every sample ending up compositionally identical
# after aggregation+rarefaction), not just unifrac's presence/absence quirk.
if (max(dist_matrix) == 0) {
  stop(sprintf(
    "Every pairwise %s distance in this dataset is 0 -- check whether this dataset's samples are more similar than expected after aggregating by '%s'. There is no compositional variation left to ordinate.",
    dist_method, annotation_col))
}

meta <- data.frame(sample_data(ps_rar))

set.seed(seed)
permanova <- adonis2(dist_matrix ~ meta[[group_var]], permutations = permutations)
p_value <- permanova$`Pr(>F)`[1]
log_line("[dogma_functional_beta_diversity] PERMANOVA: %s (%d permutations)", format_p_value(p_value), permutations)

# CAP is a CONSTRAINED ordination (dbRDA, Anderson & Willis 2003) and
# phyloseq's ordinate() requires a formula for it -- without one it hands
# capscale a NULL formula and dies with an opaque dispatch error. Same fix,
# same reasoning as beta_diversity.R: constrain on --group_var, the factor
# PERMANOVA above tests.
ord <- if (ord_method == "CAP") {
  ordinate(ps_rar, method = "CAP", distance = dist_method,
           formula = stats::as.formula(paste("~", group_var)))
} else {
  ordinate(ps_rar, method = ord_method, distance = dist_method)
}

# Same real rank-deficiency guard as beta_diversity.R -- a handful of gene
# families (very plausible after aggregating down from raw ORFs, more so
# than MAGMA's usual taxon counts) can leave PCoA with <2 usable axes even
# with enough samples.
n_pcoa_axes <- if (inherits(ord, "pcoa")) ncol(ord$vectors) else NA
if (!is.na(n_pcoa_axes) && n_pcoa_axes < 2) {
  stop(sprintf(
    "This dataset's %d gene families/taxa (by %s) don't carry enough independent compositional variation for a 2-axis %s ordination (only %d usable axis after correcting for negative eigenvalues).",
    ntaxa(ps_rar), annotation_col, ord_method, n_pcoa_axes))
}

if (inherits(ord, "pcoa")) {
  site_scores <- as.data.frame(ord$vectors[, 1:2, drop = FALSE])
} else {
  site_scores <- as.data.frame(scores(ord, choices = 1:2, display = "sites"))
}
axis_cols <- colnames(site_scores)[1:2]
df <- cbind(site_scores, data.frame(sample_data(ps_rar))[rownames(site_scores),, drop = FALSE])
df$SampleID <- rownames(df)

axis_variance <- tryCatch({
  round(ord$values$Relative_eig[1:2] * 100, 1)
}, error = function(e) c(NA, NA))

points <- lapply(seq_len(nrow(df)), function(i) {
  list(
    sample = df$SampleID[i],
    axis1 = df[[axis_cols[1]]][i],
    axis2 = df[[axis_cols[2]]][i],
    group = as.character(df[[group_var]][i])
  )
})

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(
    analysis_id = "dogma_functional_beta_diversity",
    annotation_column = annotation_col,
    group_var = group_var,
    ordination_method = ord_method,
    distance_method = dist_method,
    permanova_p_value = p_value,
    permanova_text = format_p_value(p_value),
    permutations = permutations,
    axis1_label = paste0(ord_method, " 1", if (!is.na(axis_variance[1])) paste0(" (", axis_variance[1], "%)") else ""),
    axis2_label = paste0(ord_method, " 2", if (!is.na(axis_variance[2])) paste0(" (", axis_variance[2], "%)") else ""),
    points = points
  ),
  file.path(args$out_dir, "data.json"),
  auto_unbox = TRUE, pretty = TRUE, na = "null"
)

palette <- resolve_palette(df[[group_var]], style)

n_samples <- nrow(df)
show_point_labels <- n_samples <= 40

effective_style <- default_style_for_groups(df[[group_var]], legend_position = "right", show_labels = show_point_labels,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(ps_rar = ps_rar, ordination = ord, permanova = permanova),
        file.path(args$out_dir, "dogma_functional_beta_diversity.rds"))

p <- ggplot(df, aes(x =.data[[axis_cols[1]]], y =.data[[axis_cols[2]]],
                     color =.data[[group_var]], fill =.data[[group_var]])) +
  stat_ellipse(geom = "polygon", alpha = 0.2, type = "t", level = 0.95, show.legend = FALSE) +
  geom_point(size = 5, alpha = 0.9, shape = 21, color = "black", stroke = 0.5) +
  scale_color_manual(values = palette, name = "Group") +
  scale_fill_manual(values = palette, name = "Group") +
  labs(x = paste0(ord_method, " 1"), y = paste0(ord_method, " 2")) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "right",
        legend.background = element_rect(fill = "gray95", color = "gray80"))

if (show_point_labels) {
  p <- p + geom_text_repel(aes(label = SampleID), size = 5, family = font_family, color = "black",
                            box.padding = 0.5, point.padding = 0.5, max.overlaps = 20, show.legend = FALSE)
}
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Functional Beta Diversity (", annotation_col, ", ", toupper(dist_method), ")  |  PERMANOVA: ", format_p_value(p_value))
final_plot <- with_title_bar(p, title, size = 10, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = 10, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = 12, height = 10),
        file.path(args$out_dir, "plot_final.rds"))

log_line("[dogma_functional_beta_diversity] wrote data.json, default_style.json, dogma_functional_beta_diversity.rds, preview.png")
