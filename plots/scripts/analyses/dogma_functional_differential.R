# Differential gene-family expression for DOGMA, via DESeq2 -- the piece
# DOGMA's own pipeline explicitly stops short of (see notes/DOGMA.md:
# "Differential expression (DESeq2/edgeR) is explicitly out of scope...
# the user is writing their own R scripts for the Gráficos tab"). This IS
# that R script. Real design note: DOGMA has no co-assembly (per-sample
# only), so raw transcript/ORF IDs are never comparable across samples --
# aggregate_dogma_counts (lib/build_dogma_table.R) bridges this by
# summing Salmon read counts per functional-annotation category per
# sample instead, the same real, literature-established fix CoMW uses
# (cited in notes/DOGMA.md) -- and its return shape is deliberately
# IDENTICAL to build_count_matrix.R's, so deseq_helpers.R's run_deseq
# and this analysis's own logic are a direct copy of DEFINE's
# volcano_plot.R, unchanged, not reimplemented.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir, "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "build_dogma_table.R"))
source(file.path(lib_dir, "deseq_helpers.R"))

suppressMessages({
  library(DESeq2)
  library(dplyr)
  library(ggplot2)
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(annotation_column = "eggnog_KEGG_ko", alpha = "0.05", min_lfc = "1", label_top_n = "15"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
if (is.null(args$test_group) || args$test_group == "") stop("--test_group is required")
annotation_col <- args$annotation_column
group_var <- args$group_var
reference_group <- args$reference_group
test_group <- args$test_group
alpha <- as.numeric(args$alpha)
min_lfc <- as.numeric(args$min_lfc)
label_top_n <- as.integer(args$label_top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[dogma_functional_differential] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
log_line("[dogma_functional_differential] %d ORF rows, %d sample x domain unit(s), aggregating by '%s'",
         nrow(loaded$long_table), length(unique(loaded$long_table$sample_domain)), annotation_col)

count_data <- aggregate_dogma_counts(loaded$long_table, annotation_col, loaded$coldata)
log_line("[dogma_functional_differential] aggregated count matrix: %d gene families x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var, reference_group)
coef_name <- deseq_coef_name(dds, group_var, test_group, reference_group)
log_line("[dogma_functional_differential] comparison: %s vs %s", test_group, reference_group)

res_df <- as.data.frame(results(dds, name = coef_name)) %>%
  tibble::rownames_to_column("gene_family") %>%
  filter(!is.na(padj))

res_df <- res_df %>%
  mutate(Direction = case_when(
    padj < alpha & log2FoldChange > min_lfc ~ test_group,
    padj < alpha & log2FoldChange < -min_lfc ~ reference_group,
    TRUE ~ "NS"
  ))

palette <- resolve_palette(setdiff(unique(res_df$Direction), "NS"), style)
palette[["NS"]] <- style$palette[["NS"]] %||% "gray70"

top_hits <- res_df %>% filter(Direction != "NS") %>% arrange(padj) %>% head(label_top_n)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(res_df, aes(x = log2FoldChange, y = -log10(padj), color = Direction)) +
  geom_vline(xintercept = c(-min_lfc, min_lfc), linetype = "dashed", color = "gray50") +
  geom_hline(yintercept = -log10(alpha), linetype = "dashed", color = "gray50") +
  geom_point(alpha = 0.7, size = 1.8) +
  geom_text_repel(data = top_hits, aes(label = gene_family), size = 3.2, family = font_family, color = "black",
                   max.overlaps = 30, box.padding = 0.4, show.legend = FALSE) +
  scale_color_manual(values = palette, name = paste0("Enriched in (padj < ", alpha, ", |log2FC| > ", min_lfc, ")")) +
  labs(x = "Log2 Fold Change", y = expression(-log[10](padj))) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(legend.position = "top")
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

n_sig <- sum(res_df$Direction != "NS")
title <- paste0("Functional Differential Abundance (", annotation_col, "): ", test_group, " vs ", reference_group, " (", n_sig, " significant)")
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.1, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 10, height = 9, units = "in", dpi = 150, bg = "white")

write_json(
  list(analysis_id = "dogma_functional_differential", annotation_column = annotation_col, group_var = group_var,
       reference_group = reference_group, comparison_level = test_group, alpha = alpha, min_lfc = min_lfc, n_significant = n_sig,
       gene_families = lapply(seq_len(nrow(res_df)), function(i) list(
         gene_family = res_df$gene_family[i], log2fc = res_df$log2FoldChange[i],
         padj = res_df$padj[i], direction = res_df$Direction[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(setdiff(unique(res_df$Direction), "NS"), legend_position = "top",
                                             show_labels = TRUE, background = bg, font_family = font_family,
                                             palette = palette[setdiff(unique(res_df$Direction), "NS")])
effective_style$palette[["NS"]] <- palette[["NS"]]
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(res_df, file.path(args$out_dir, "dogma_functional_differential.rds"))

log_line("[dogma_functional_differential] wrote data.json, default_style.json, dogma_functional_differential.rds, preview.png")
