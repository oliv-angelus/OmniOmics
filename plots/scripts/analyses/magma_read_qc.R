# Real before-vs-after read-cleaning comparison: total reads and Q30 rate
# per sample, from whichever QC tool actually ran for that sample's read
# type (fastp for short/hybrid, NanoPlot for long -- see
# build_magma_qc_table.R). Answers a basic, always-worth-checking question
# every pipeline run raises: how much did cleaning actually remove, and did
# quality improve the way it's supposed to.

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

suppressMessages({
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(jsonlite)
})

args <- parse_cli_args()
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0

log_line("[magma_read_qc] reading cached QC table from %s", args$magma_qc_table_rds)
loaded <- readRDS(args$magma_qc_table_rds)
df <- loaded$qc_table
if (is.null(df) || nrow(df) == 0) {
  stop("No fastp or NanoPlot output found for any sample in this run -- was QC active?")
}
log_line("[magma_read_qc] %d row(s) across %d sample(s)", nrow(df), length(unique(df$sample)))

df$stage <- factor(df$stage, levels = c("before", "after"),
                   labels = c("Before cleaning", "After cleaning"))
palette <- resolve_palette(levels(df$stage), style)

reads_df <- df %>% filter(!is.na(total_reads))
p_reads <- ggplot(reads_df, aes(x = sample, y = total_reads, fill = stage)) +
  geom_col(position = "dodge", width = 0.7) +
  scale_y_continuous(labels = function(x) format(x, big.mark = ",", scientific = FALSE)) +
  scale_fill_manual(values = palette, name = NULL) +
  labs(x = NULL, y = "Reads") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "top")

qual_df <- df %>% filter(!is.na(q30_rate))
panels <- list(p_reads)
if (nrow(qual_df) > 0) {
  p_qual <- ggplot(qual_df, aes(x = sample, y = q30_rate * 100, fill = stage)) +
    geom_col(position = "dodge", width = 0.7) +
    scale_fill_manual(values = palette, name = NULL) +
    labs(x = NULL, y = "Q30 rate (%)") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "none")
  panels[[length(panels) + 1]] <- p_qual
}

combined <- wrap_plots(panels, ncol = 1)
n_samples <- length(unique(df$sample))
final_plot <- with_title_bar(combined, "Read Cleaning: Before vs. After", size = 10, font_family = font_family)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "magma_read_qc",
       samples = lapply(unique(df$sample), function(s) {
         rows <- df[df$sample == s, , drop = FALSE]
         list(sample = s, tool = rows$tool[1],
             before = as.list(rows[rows$stage == "Before cleaning", c("total_reads", "total_bases", "q30_rate", "gc_content", "mean_length", "n50")]),
             after = as.list(rows[rows$stage == "After cleaning", c("total_reads", "total_bases", "q30_rate", "gc_content", "mean_length", "n50")]))
       })),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

width <- max(9, 0.5 * n_samples); height <- 4 * length(panels) + 1
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(levels(df$stage), legend_position = "top", show_labels = TRUE,
                                          background = bg, font_family = font_family, palette = palette),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(df, file.path(args$out_dir, "magma_read_qc.rds"))

log_line("[magma_read_qc] wrote data.json, default_style.json, magma_read_qc.rds, preview.png, plot_final.rds")
