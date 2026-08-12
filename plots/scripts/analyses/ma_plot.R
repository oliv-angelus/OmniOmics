# MA plot (mean normalized expression vs. log2 fold change) -- DESeq2's own
# standard DE-result summary plot (`plotMA`), with the vignette-recommended
# shrunk fold changes (Love, Huber & Anders 2014, DOI 10.1186/s13059-014-0550-8;
# shrinkage estimator: Zhu, Ibrahim & Love 2019, Bioinformatics, "Heavy-tailed
# prior distributions for sequence count data: removing the noise and
# preserving large differences", DOI 10.1093/bioinformatics/bty895 -- apeglm).
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
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(alpha = "0.05"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
if (is.null(args$test_group) || args$test_group == "") stop("--test_group is required")
group_var <- args$group_var
reference_group <- args$reference_group
test_group <- args$test_group
alpha <- as.numeric(args$alpha)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[ma_plot] reading cached count matrix from %s", args$count_matrix_rds)
count_data <- readRDS(args$count_matrix_rds)
log_line("[ma_plot] count matrix: %d genes x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var, reference_group)
coef_name <- deseq_coef_name(dds, group_var, test_group, reference_group)
log_line("[ma_plot] comparison: %s vs %s", test_group, reference_group)

# apeglm gives better-behaved (less noisy) shrunk fold changes for low-count
# genes than the raw MLE estimate -- the DESeq2 vignette's own current
# recommendation. Falls back to unshrunk results if apeglm isn't installed
# or fails for any reason (e.g. an interaction-term design apeglm can't
# handle) rather than erroring the whole analysis out over a plot-quality
# refinement.
res <- tryCatch(
  lfcShrink(dds, coef = coef_name, type = "apeglm", quiet = TRUE),
  error = function(e) {
    log_line("[ma_plot] lfcShrink(apeglm) failed (%s) -- falling back to unshrunk results", conditionMessage(e))
    results(dds)
  }
)

res_df <- as.data.frame(res) %>%
  tibble::rownames_to_column("locus_tag") %>%
  filter(!is.na(padj)) %>%
  mutate(Significant = padj < alpha)

gene_info <- count_data$gene_info
res_df$Gene <- gene_info[res_df$locus_tag, "Gene"]

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(res_df, aes(x = baseMean, y = log2FoldChange, color = Significant)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray40") +
  geom_point(alpha = 0.6, size = 1.6) +
  scale_x_log10() +
  scale_color_manual(values = c(`TRUE` = "#D95F02", `FALSE` = "gray60"),
                      labels = c(`TRUE` = paste0("padj < ", alpha), `FALSE` = "not significant"), name = NULL) +
  labs(x = "Mean of normalized counts", y = "Log2 fold change (shrunk)") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "top")
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("MA Plot: ", test_group, " vs ", reference_group, " (", sum(res_df$Significant), " significant)")
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.1, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 10, height = 8, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = 10, height = 8),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "ma_plot", group_var = group_var, reference_group = reference_group,
       comparison_level = test_group, alpha = alpha, n_significant = sum(res_df$Significant),
       genes = lapply(seq_len(nrow(res_df)), function(i) list(
         locus_tag = res_df$locus_tag[i], gene = res_df$Gene[i], base_mean = res_df$baseMean[i],
         log2fc = res_df$log2FoldChange[i], padj = res_df$padj[i], significant = res_df$Significant[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(
  palette = list(`TRUE` = "#D95F02", `FALSE` = "#999999"),
  legend_position = "top", show_labels = FALSE, background = bg, font_family = font_family
)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(results = res_df, dds = dds), file.path(args$out_dir, "ma_plot.rds"))

log_line("[ma_plot] wrote data.json, default_style.json, ma_plot.rds, preview.png")
