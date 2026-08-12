# Real Good's Coverage analysis (per-sample sequencing depth adequacy),
# direct translation of microbiome.R's section 5. See plots/manifest.yaml
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
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(cutoff = "0.98"))
cutoff <- as.numeric(args$cutoff)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)
accent_color <- style$accent_color %||% "#4682B4"

log_line("[goods_coverage] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[goods_coverage] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

get_goods_coverage <- function(x) {
  n_singletons <- sum(x == 1)
  total <- sum(x)
  if (total == 0) return(NA_real_)
  1 - (n_singletons / total)
}

otu_mat <- as(otu_table(ps), "matrix")
if (!taxa_are_rows(ps)) otu_mat <- t(otu_mat)
coverage <- apply(otu_mat, 2, get_goods_coverage)

dados_cov <- data.frame(SampleID = names(coverage), Goods_Coverage = coverage, row.names = NULL)

p <- ggplot(dados_cov, aes(x = reorder(SampleID, Goods_Coverage), y = Goods_Coverage)) +
  geom_col(fill = accent_color, color = "black", width = 0.7) +
  geom_hline(yintercept = cutoff, color = "red", linetype = "dashed", linewidth = 0.8) +
  coord_flip() +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "none")
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

final_plot <- with_title_bar(p, "Good's Coverage", size = 8, title_height = 0.1, font_family = font_family, plot_width_in = 12)
height <- max(4, nrow(dados_cov) * 0.35)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = 12, height = height),
        file.path(args$out_dir, "plot_final.rds"))

samples_json <- lapply(seq_len(nrow(dados_cov)), function(i) {
  list(sample = dados_cov$SampleID[i], coverage = dados_cov$Goods_Coverage[i])
})

write_json(
  list(analysis_id = "goods_coverage", cutoff = cutoff, samples = samples_json),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(accent_color = accent_color, legend_position = "none", show_labels = FALSE,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(dados_cov, file.path(args$out_dir, "goods_coverage.rds"))

log_line("[goods_coverage] wrote data.json, default_style.json, goods_coverage.rds, preview.png")
