# Sample-to-sample Euclidean distance heatmap on variance-stabilized,
# gene-family-aggregated counts -- the DOGMA analogue of DEFINE's
# sample_distance_heatmap.R (same DESeq2-vignette QC recipe). See
# dogma_sample_pca.R / lib/build_dogma_table.R for why the aggregation step
# exists here and not in DEFINE's version.
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
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(annotation_column = "eggnog_KEGG_ko"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
annotation_col <- args$annotation_column
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "white"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[dogma_sample_distance_heatmap] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
count_data <- aggregate_dogma_counts(loaded$long_table, annotation_col, loaded$coldata)
log_line("[dogma_sample_distance_heatmap] aggregated count matrix: %d gene families x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var)
vsd <- vst_blind(dds)

sample_dist <- dist(t(assay(vsd)))
dist_matrix <- as.matrix(sample_dist)

hc <- hclust(sample_dist)
sample_order <- rownames(dist_matrix)[hc$order]

df <- as.data.frame(as.table(dist_matrix))
colnames(df) <- c("SampleA", "SampleB", "Distance")
df$SampleA <- factor(df$SampleA, levels = sample_order)
df$SampleB <- factor(df$SampleB, levels = sample_order)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(df, aes(x = SampleA, y = SampleB, fill = Distance)) +
  geom_tile(color = "white", linewidth = 0.3) +
  scale_fill_distiller(palette = "Spectral", name = "Euclidean\ndistance") +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5),
    panel.grid = element_blank()
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Sample Distance (VST, ", annotation_col, "-aggregated, hierarchically clustered): ", group_var)
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.08, font_family = font_family)
side <- max(6, ncol(dist_matrix) * 0.5)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = side, height = side, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = side, height = side),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "dogma_sample_distance_heatmap", annotation_column = annotation_col, group_var = group_var,
       sample_order = sample_order, distances = lapply(seq_len(nrow(df)), function(i) as.list(df[i, ]))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(palette = "Spectral", legend_position = "right", show_labels = FALSE,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(dist_matrix = dist_matrix, hc = hc), file.path(args$out_dir, "dogma_sample_distance_heatmap.rds"))

log_line("[dogma_sample_distance_heatmap] wrote data.json, default_style.json, dogma_sample_distance_heatmap.rds, preview.png")
