# Sample PCA on variance-stabilized, gene-family-aggregated counts -- the
# DOGMA analogue of DEFINE's sample_pca.R (same DESeq2-vignette-recommended
# QC/exploratory plot, Love, Huber & Anders 2014, DOI 10.1186/s13059-014-0550-8),
# built on aggregate_dogma_counts instead of a single pre-merged count
# table -- see lib/build_dogma_table.R's header for why DOGMA needs that
# extra aggregation step (no co-assembly, so raw transcript/ORF IDs are
# never comparable across samples the way DEFINE's shared reference is).
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
  library(ggplot2)
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(annotation_column = "eggnog_KEGG_ko"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
annotation_col <- args$annotation_column
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[dogma_sample_pca] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
count_data <- aggregate_dogma_counts(loaded$long_table, annotation_col, loaded$coldata)
log_line("[dogma_sample_pca] aggregated count matrix: %d gene families x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var)
vsd <- vst_blind(dds)

# plotPCA(returnData=TRUE) does the real work (top-500-most-variable-features
# prcomp, per the DESeq2 vignette) -- reused as-is, same as sample_pca.R.
pca_data <- plotPCA(vsd, intgroup = group_var, returnData = TRUE)
percent_var <- round(100 * attr(pca_data, "percentVar"))
pca_data$SampleID <- rownames(pca_data)

palette <- resolve_palette(pca_data[[group_var]], style)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(pca_data, aes(x = PC1, y = PC2, color =.data[[group_var]], fill =.data[[group_var]])) +
  stat_ellipse(geom = "polygon", alpha = 0.15, type = "t", level = 0.95, show.legend = FALSE) +
  geom_point(size = 5, alpha = 0.9, shape = 21, color = "black", stroke = 0.5) +
  geom_text_repel(aes(label = SampleID), size = 4, family = font_family, color = "black",
                   box.padding = 0.5, point.padding = 0.5, max.overlaps = 20, show.legend = FALSE) +
  scale_color_manual(values = palette, name = group_var) +
  scale_fill_manual(values = palette, name = group_var) +
  labs(x = paste0("PC1 (", percent_var[1], "%)"), y = paste0("PC2 (", percent_var[2], "%)")) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "right", legend.background = element_rect(fill = "gray95", color = "gray80"))
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Sample PCA (VST, ", annotation_col, "-aggregated): ", group_var)
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.1, font_family = font_family, plot_width_in = 10)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 10, height = 8, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = 10, height = 8),
        file.path(args$out_dir, "plot_final.rds"))

records <- lapply(seq_len(nrow(pca_data)), function(i) {
  list(sample = pca_data$SampleID[i], group = as.character(pca_data[[group_var]][i]),
       pc1 = pca_data$PC1[i], pc2 = pca_data$PC2[i])
})
write_json(
  list(analysis_id = "dogma_sample_pca", annotation_column = annotation_col, group_var = group_var,
       percent_var_pc1 = percent_var[1], percent_var_pc2 = percent_var[2], samples = records),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(pca_data[[group_var]], legend_position = "right", show_labels = TRUE,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(pca_data = pca_data, percent_var = percent_var), file.path(args$out_dir, "dogma_sample_pca.rds"))

log_line("[dogma_sample_pca] wrote data.json, default_style.json, dogma_sample_pca.rds, preview.png")
