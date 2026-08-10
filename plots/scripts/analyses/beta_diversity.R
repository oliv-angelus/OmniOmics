# Real beta diversity analysis (PCoA/NMDS/CAP ordination + PERMANOVA),
# direct translation of microbiome.R's section 8. See plots/manifest.yaml
# for parameter descriptions.
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
  library(vegan)
  library(ggplot2)
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(
  ordination_method = "PCoA",
  distance_method = "bray",
  permutations = "999",
  seed = "123"
))

if (is.null(args$group_var) || args$group_var == "") {
  stop("--group_var is required")
}

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

log_line("[beta_diversity] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[beta_diversity] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

# A 2D ordination needs at least 2 non-trivial axes, which PCoA/NMDS/CAP can
# only produce from >= 3 samples (an n=2 dataset has rank 1 -- confirmed by
# hitting this against a 2-sample demo run: PCoA's `ord$vectors`
# only had 1 column, so 1:2 indexing errored out with a raw "index out of
# bounds" instead of a message that tells the user what's actually wrong).
if (nsamples(ps) < 3) {
  stop(sprintf("Beta diversity needs at least 3 samples to compute a 2-axis ordination (this run has %d).",
               nsamples(ps)))
}

# UniFrac-class methods need a real phy_tree (a tip-labeled phylogeny,
# only present when this run's phyloseq object was built at ASV/species
# resolution with a real tree attached -- see build_phyloseq.R's
# find_prism_tree_files/.build_phyloseq_asv_level, currently PRISM-only
# and only for runs where >=3 taxa were actually detected). Checked here
# with a clear, actionable message instead of letting phyloseq::distance
# fail deep inside its own UniFrac code with a much less obvious error
# ("Could not find tree...").
if (dist_method %in% c("unifrac", "wunifrac") &&
    is.null(tryCatch(phy_tree(ps, errorIfNULL = FALSE), error = function(e) NULL))) {
  stop(sprintf(
    "--distance_method %s needs a real phylogenetic tree, which this run's phyloseq object doesn't have. This is currently only available for PRISM runs where a tree was actually built (see prism_tree.nwk in the run's output) -- MAGMA/DOGMA's lineage-based taxonomy has no placed sequences to build a tree from, and PRISM skips tree-building when fewer than 3 taxa were detected. Use bray or jaccard instead.",
    dist_method))
}

# phyloseq's rarefy_even_depth fails on a single-taxon object with
# "attempt to set 'rownames' on an object with no dimensions": R drops
# dimensions when subsetting a 1-row matrix and phyloseq doesn't guard
# against it. A single taxon also carries no compositional variation to
# ordinate, so stop here with a clear message.
if (ntaxa(ps) < 2) {
  stop(sprintf("This dataset has only %d taxon -- too few for a meaningful beta diversity ordination (and phyloseq's own rarefaction crashes outright on exactly one).", ntaxa(ps)))
}

set.seed(seed)
min_reads <- min(sample_sums(ps))
ps_rar <- rarefy_even_depth(ps, sample.size = min_reads, replace = FALSE, rngseed = seed, verbose = FALSE)
log_line("[beta_diversity] rarefied to %d reads/sample (%d taxa survived)", min_reads, ntaxa(ps_rar))

dist_matrix <- phyloseq::distance(ps_rar, method = dist_method)

# Unweighted UniFrac considers presence/absence per branch, not abundance,
# so a dataset where every sample carries the same set of taxa yields an
# all-zero distance matrix. ape::pcoa then fails inside its
# eigenvalue-correction step ("row names contain missing values"), so
# report the degenerate input directly instead.
if (max(dist_matrix) == 0) {
  stop(sprintf(
    "Every pairwise %s distance in this dataset is 0 -- %s. There is no compositional variation left to ordinate. Try wunifrac (weights by abundance) or bray/jaccard instead.",
    dist_method,
    if (dist_method == "unifrac")
      "every sample contains the exact same set of detected taxa, and unweighted UniFrac only considers presence/absence, not relative abundance"
    else
      "check whether this dataset's samples are more similar than expected"
  ))
}

meta <- data.frame(sample_data(ps_rar))

set.seed(seed)
permanova <- adonis2(dist_matrix ~ meta[[group_var]], permutations = permutations)
p_value <- permanova$`Pr(>F)`[1]
log_line("[beta_diversity] PERMANOVA: %s (%d permutations)", format_p_value(p_value), permutations)

ord <- ordinate(ps_rar, method = ord_method, distance = dist_method)

# Deliberately NOT phyloseq::plot_ordination to build the site scores --
# its internal `is_empty(sdf)` check on the sample_data data.frame uses
# `length(sdf)`, which for a data.frame counts *columns*, not rows. A
# metadata table with a single column (exactly what --group_var alone
# produces, e.g. this script's own minimal test fixture) reads as "empty"
# and plot_ordination silently drops sample_data entirely -- no color, no
# group, no error, just a plain unlabeled ordination. Extracting scores
# directly and joining sample_data ourselves sidesteps that pitfall
# entirely instead of requiring metadata to happen to have >=2 columns.
#
# Also deliberately NOT the generic vegan::scores(ord,...) for the PCoA
# case specifically: phyloseq defines scores.pcoa (for ape's "pcoa" class,
# what ordinate(method="PCoA") returns) but never registers it as a real S3
# method -- methods("scores") doesn't list it, so UseMethod("scores") only
# finds it when the *call itself* originates from inside phyloseq's own
# namespace (e.g. from within plot_ordination). Called from this script it
# silently falls through to scores.default and errors ("cannot find
# scores"), confirmed by reading phyloseq's actual (unexported) scores.pcoa
# source. ape::pcoa's own $vectors matrix is exactly what that internal
# method reads from, so read it directly instead of relying on dispatch.
# NMDS/CAP go through ordinate to vegan's own "metaMDS"/"rda" classes,
# which DO have properly registered scores methods.
# With very few taxa the ordination can be rank-deficient enough that PCoA
# recovers only one usable (non-negative-eigenvalue) axis even with >= 3
# samples, since ordinate(..., distance = "bray") routes through
# ape::pcoa's eigenvalue correction. Indexing [, 1:2] on that 1-column
# matrix would raise a bare subscript error, so check the axis count first.
n_pcoa_axes <- if (inherits(ord, "pcoa")) ncol(ord$vectors) else NA
if (!is.na(n_pcoa_axes) && n_pcoa_axes < 2) {
  stop(sprintf(
    "This dataset's %d taxa don't carry enough independent compositional variation for a 2-axis %s ordination (only %d usable axis after correcting for negative eigenvalues). Beta diversity ordination needs more taxonomic resolution/richness than this run has.",
    ntaxa(ps_rar), ord_method, n_pcoa_axes))
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
}, error = function(e) c(NA, NA))  # not every ordination method exposes eigenvalues (e.g. NMDS)

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
    analysis_id = "beta_diversity",
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

# Resolved BEFORE building effective_style below, so the palette actually
# used in the plot is exactly what gets written to default_style.json --
# see default_style_for_groups's docstring: computing a fresh palette here
# would overwrite the overrides actually applied to the plot.
palette <- resolve_palette(df[[group_var]], style)

# Every point gets a SampleID label -- fine for a handful of samples, but
# past a few dozen, points crowd together (especially inside tight ellipses)
# and ggrepel's max.overlaps starts silently dropping most of them anyway,
# so the labels stop being useful and just add visual noise. Confirmed
# cramped at 80 samples/8 groups; below the threshold, keep
# labeling every point as before.
n_samples <- nrow(df)
show_point_labels <- n_samples <= 40

effective_style <- default_style_for_groups(df[[group_var]], legend_position = "right", show_labels = show_point_labels,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(ps_rar = ps_rar, ordination = ord, permanova = permanova),
        file.path(args$out_dir, "beta_diversity.rds"))

# Static preview image, written alongside data.json.
p <- ggplot(df, aes(x =.data[[axis_cols[1]]], y =.data[[axis_cols[2]]],
                     color =.data[[group_var]], fill =.data[[group_var]])) +
  stat_ellipse(geom = "polygon", alpha = 0.2, type = "t", level = 0.95, show.legend = FALSE) +
  geom_point(size = 5, alpha = 0.9, shape = 21, color = "black", stroke = 0.5) +
  scale_color_manual(values = palette, name = "Group") +
  scale_fill_manual(values = palette, name = "Group") +
  labs(x = paste0(ord_method, " 1"), y = paste0(ord_method, " 2")) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(legend.position = "right",
        legend.background = element_rect(fill = "gray95", color = "gray80"))

if (show_point_labels) {
  p <- p + geom_text_repel(aes(label = SampleID), size = 5, family = font_family, color = "black",
                            box.padding = 0.5, point.padding = 0.5, max.overlaps = 20, show.legend = FALSE)
}
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Beta Diversity (", toupper(dist_method), ")  |  PERMANOVA: ", format_p_value(p_value))
final_plot <- with_title_bar(p, title, size = 10, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = 10, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = 12, height = 10),
        file.path(args$out_dir, "plot_final.rds"))

log_line("[beta_diversity] wrote data.json, default_style.json, beta_diversity.rds, preview.png")
