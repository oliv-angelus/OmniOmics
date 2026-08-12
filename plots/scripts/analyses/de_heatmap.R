# Heatmap of the top N differentially expressed genes, variance-stabilized
# and row-centered (z-score), hierarchically clustered -- standard practice
# documented directly in the DESeq2 vignette (Love, Huber & Anders 2014, DOI
# 10.1186/s13059-014-0550-8) and reinforced by Conesa et al. (2016), "A
# survey of best practices for RNA-seq data analysis", Genome Biology, 17,
# 13, DOI 10.1186/s13059-016-0881-8 (comprehensive RNA-seq best-practices
# review covering DE visualization). Built with ggplot2 (not pheatmap) for
# consistency with this app's own theme system, same reasoning
# core_microbiome.R already uses for MAGMA's heatmap. DEFINE-only; see
# plots/manifest.yaml for parameter descriptions.
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
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(alpha = "0.05", top_n = "30"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
if (is.null(args$test_group) || args$test_group == "") stop("--test_group is required")
group_var <- args$group_var
reference_group <- args$reference_group
test_group <- args$test_group
alpha <- as.numeric(args$alpha)
top_n <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "white"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[de_heatmap] reading cached count matrix from %s", args$count_matrix_rds)
count_data <- readRDS(args$count_matrix_rds)
log_line("[de_heatmap] count matrix: %d genes x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var, reference_group)
coef_name <- deseq_coef_name(dds, group_var, test_group, reference_group)
log_line("[de_heatmap] comparison: %s vs %s", test_group, reference_group)
res_df <- as.data.frame(results(dds, name = coef_name)) %>% tibble::rownames_to_column("locus_tag") %>% filter(!is.na(padj))

sig_genes <- res_df %>% filter(padj < alpha) %>% arrange(padj) %>% head(top_n) %>% pull(locus_tag)
if (length(sig_genes) == 0) {
  log_line("[de_heatmap] no genes passed padj < %g -- writing an empty result, no plot", alpha)
  dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
  write_json(
    list(analysis_id = "de_heatmap", group_var = group_var, reference_group = reference_group,
         comparison_level = test_group, n_genes = 0, genes = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  saveRDS(list(full_results = res_df), file.path(args$out_dir, "de_heatmap.rds"))
  log_line("[de_heatmap] wrote data.json (empty), de_heatmap.rds -- no preview.png")
  quit(save = "no", status = 0)
}
log_line("[de_heatmap] %d gene(s) selected (top %d by padj < %g)", length(sig_genes), top_n, alpha)

vsd <- vst_blind(dds)
mat <- assay(vsd)[sig_genes,, drop = FALSE]
# Row-center (z-score) -- shows each gene's OWN pattern across samples,
# independent of its absolute expression level, exactly the standard recipe.
mat_z <- t(scale(t(mat)))

gene_info <- count_data$gene_info
gene_labels <- ifelse(is.na(gene_info[sig_genes, "Gene"]) | gene_info[sig_genes, "Gene"] == "-",
                       sig_genes, gene_info[sig_genes, "Gene"])
rownames(mat_z) <- gene_labels

# Hierarchical clustering on both axes -- genes with similar patterns group
# together, samples with similar profiles group together (same real
# clustering-heatmap recipe pheatmap/ComplexHeatmap use by default).
row_order <- gene_labels[hclust(dist(mat_z))$order]
col_order <- colnames(mat_z)[hclust(dist(t(mat_z)))$order]

df <- as.data.frame(as.table(mat_z))
colnames(df) <- c("Gene", "Sample", "Zscore")
df$Gene <- factor(df$Gene, levels = row_order)
df$Sample <- factor(df$Sample, levels = col_order)
df$Group <- count_data$coldata[as.character(df$Sample), group_var]

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(df, aes(x = Sample, y = Gene, fill = Zscore)) +
  geom_tile(color = "white", linewidth = 0.2) +
  scale_fill_distiller(palette = "RdBu", name = "Z-score") +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5),
    axis.text.y = element_text(face = "italic", size = 9),
    panel.grid = element_blank()
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Top ", length(sig_genes), " DE Genes (VST, row z-score): ", test_group, " vs ", reference_group)
height <- max(6, length(sig_genes) * 0.25)
width <- max(8, ncol(mat_z) * 0.6)
final_plot <- with_title_bar(p, title, size = 7, title_height = 0.08, font_family = font_family, plot_width_in = width)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "de_heatmap", group_var = group_var, reference_group = reference_group,
       comparison_level = test_group, n_genes = length(sig_genes),
       genes = lapply(sig_genes, function(g) list(
         locus_tag = g, gene = gene_info[g, "Gene"], padj = res_df$padj[res_df$locus_tag == g]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(palette = "RdBu", legend_position = "right", show_labels = FALSE,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(mat_z = mat_z, full_results = res_df), file.path(args$out_dir, "de_heatmap.rds"))

log_line("[de_heatmap] wrote data.json, default_style.json, de_heatmap.rds, preview.png")
