# "Which taxa respond to the grouping variable at all?" -- DESeq2's likelihood
# ratio test, comparing the full model (~ group) against ~ 1.
#
# This is a different question from differential_abundance_deseq2, not a
# variant of it. That analysis runs a Wald contrast: "does polluted differ from
# control", which with three or more groups answers about two of them and
# ignores the rest. A gradient design (control / moderate / polluted) is built
# to ask whether a taxon responds to the gradient at all, and that is what the
# LRT tests. The usual workflow is both: LRT first to find the responders, then
# pairwise contrasts to say where the difference sits.
#
# Why this is its own analysis rather than a toggle on the pairwise one, which
# would have been less code: results() after an LRT still carries a
# log2FoldChange column, but it belongs to ONE arbitrary coefficient of the
# full model, not to the effect the test measured. The pairwise analysis
# filters and plots exactly that column, so a toggle would have kept the axis
# label and silently changed what the axis means. The figure here shows the
# thing the LRT actually identifies instead: each significant taxon's PATTERN
# across every group.
#
# Method: Love, Huber & Anders 2014 (Genome Biol 15:550,
# doi:10.1186/s13059-014-0550-8) and DESeq2's own vignette section on
# likelihood ratio tests.

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
source(file.path(lib_dir, "deseq_helpers.R"))

suppressMessages({
  library(phyloseq)
  library(DESeq2)
  library(dplyr)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(alpha = "0.05", top_n = "30", rank = "Genus"))
alpha <- as.numeric(args$alpha)
top_n <- as.integer(args$top_n)
rank <- args$rank
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var

log_line("[differential_abundance_lrt] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[differential_abundance_lrt] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

meta <- data.frame(sample_data(ps))
if (!(group_var %in% colnames(meta))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(meta), collapse = ", ")))
}

# Aggregated to the requested rank before testing, same convention every other
# taxon-level analysis uses -- testing at raw ASV level with a lineage-collapsed
# table would just be testing the same rows under a less readable name.
ps_glom <- if (rank %in% rank_names(ps)) tax_glom(ps, taxrank = rank, NArm = FALSE) else ps

# phyloseq_to_deseq2, not a hand-built DESeqDataSetFromMatrix: it is the same
# conversion differential_abundance_deseq2 already uses, and it handles the
# otu_table orientation and the sample_data coercion that a manual build gets
# wrong (confirmed by getting it wrong first -- a non-conformable-arrays error
# from inside DESeqDataSetFromMatrix). The +1 pseudocount is the same one that
# analysis applies, for the same reason: DESeq2's geometric means cannot take
# an exact zero in every sample.
otu_table(ps_glom) <- otu_table(ps_glom) + 1
dds_raw <- phyloseq_to_deseq2(ps_glom, as.formula(paste("~", group_var)))

log_line("[differential_abundance_lrt] LRT: ~ %s vs ~ 1, on %d features", group_var, nrow(dds_raw))
dds <- run_deseq_lrt(dds_raw, group_var)
res <- results(dds, cooksCutoff = FALSE)

res_df <- as.data.frame(res)
res_df$feature <- rownames(res_df)
sig <- res_df %>% filter(!is.na(padj), padj < alpha) %>% arrange(padj)
log_line("[differential_abundance_lrt] %d of %d features respond to '%s' (padj < %g)",
         nrow(sig), nrow(res_df), group_var, alpha)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

if (nrow(sig) == 0) {
  # A real, reportable outcome: nothing responds. Written out rather than
  # drawn, same convention the DE heatmap already uses.
  write_json(list(analysis_id = "differential_abundance_lrt", group_var = group_var,
                  alpha = alpha, n_tested = nrow(res_df), n_significant = 0, features = list()),
             file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null")
  saveRDS(res_df, file.path(args$out_dir, "differential_abundance_lrt.rds"))
  log_line("[differential_abundance_lrt] no feature passed padj < %g -- wrote an empty result, no plot", alpha)
  quit(save = "no", status = 0)
}

# The pattern, which is what the LRT identified: each significant taxon's mean
# variance-stabilised abundance per group, row-centred so taxa at very
# different absolute abundances are comparable in one panel.
vsd <- vst_blind(dds)
mat <- assay(vsd)[head(sig$feature, top_n), , drop = FALSE]
groups <- as.character(colData(dds)[colnames(mat), group_var])
group_means <- t(apply(mat, 1, function(row) tapply(row, groups, mean)))
z <- t(scale(t(group_means)))

tax_labels <- NULL
if (rank %in% rank_names(ps_glom)) {
  tt <- as.data.frame(tax_table(ps_glom))
  tax_labels <- as.character(tt[rownames(z), rank])
  tax_labels[is.na(tax_labels) | tax_labels == ""] <- rownames(z)[is.na(tax_labels) | tax_labels == ""]
}
labels <- tax_labels %||% rownames(z)
# Same reason de_heatmap needed it: a rank label is not unique (two different
# features can collapse to the same genus name), and a duplicated factor level
# is a hard error rather than a cosmetic problem.
dups <- labels[duplicated(labels)]
labels[labels %in% dups] <- paste0(labels[labels %in% dups], " (", rownames(z)[labels %in% dups], ")")
rownames(z) <- labels

df <- as.data.frame(as.table(z))
colnames(df) <- c("Feature", "Group", "Zscore")
# Ordered by the test's own ranking, most significant at the top.
df$Feature <- factor(df$Feature, levels = rev(labels))

p <- ggplot(df, aes(x = Group, y = Feature, fill = Zscore)) +
  geom_tile(color = "white", linewidth = 0.3) +
  scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B", midpoint = 0,
                       name = "Row z-score") +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(axis.text.y = element_text(size = 9, face = "italic"), legend.position = "right",
        panel.grid = element_blank())
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- sprintf("Responds to %s (LRT, padj < %g): %d of %d %s features, top %d shown",
                 group_var, alpha, nrow(sig), nrow(res_df), rank, nrow(z))
width <- max(8, 2 + ncol(z) * 1.2)
final_plot <- with_title_bar(p, title, size = 7, title_height = 0.08,
                             font_family = font_family, plot_width_in = width)

write_json(
  list(analysis_id = "differential_abundance_lrt", group_var = group_var, rank = rank,
       alpha = alpha, n_tested = nrow(res_df), n_significant = nrow(sig),
       features = lapply(seq_len(min(nrow(sig), top_n)), function(i) list(
         feature = sig$feature[i], taxon = labels[i],
         base_mean = sig$baseMean[i], stat = sig$stat[i], pvalue = sig$pvalue[i], padj = sig$padj[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

height <- max(5, 1 + nrow(z) * 0.22)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(list(palette = list(), legend_position = "right", show_labels = FALSE,
                      background = bg, font_family = font_family,
                      show_grid = FALSE, show_panel_border = FALSE),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(list(results = res_df, matrix = z), file.path(args$out_dir, "differential_abundance_lrt.rds"))

log_line("[differential_abundance_lrt] wrote data.json, default_style.json, differential_abundance_lrt.rds, preview.png, plot_final.rds")
