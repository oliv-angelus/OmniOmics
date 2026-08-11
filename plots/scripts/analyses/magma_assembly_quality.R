# Real per-sample assembly-quality overview: N50 and total assembly length
# from MetaQuast, for the full assembly and the Tiara-filtered prokaryotic
# subset side by side -- the gap between the two is itself informative (how
# much of the assembly Tiara flagged as eukaryotic/organelle and excluded
# from the prokaryotic path). See build_magma_assembly_table.R.

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

log_line("[magma_assembly_quality] reading cached assembly table from %s", args$magma_qc_table_rds)
loaded <- readRDS(args$magma_qc_table_rds)
df <- loaded$assembly_table
if (is.null(df) || nrow(df) == 0) {
  stop("No MetaQuast output found for any sample in this run.")
}
log_line("[magma_assembly_quality] %d row(s) across %d sample(s)", nrow(df), length(unique(df$sample)))

df$variant <- factor(df$variant, levels = c("metaquast", "metaquast_prokaryotic"),
                     labels = c("Full assembly", "Prokaryotic (Tiara-filtered)"))
palette <- resolve_palette(levels(df$variant), style)

p_n50 <- ggplot(df, aes(x = sample, y = n50, fill = variant)) +
  geom_col(position = "dodge", width = 0.7) +
  scale_y_continuous(labels = function(x) format(x, big.mark = ",", scientific = FALSE)) +
  scale_fill_manual(values = palette, name = NULL) +
  labs(x = NULL, y = "N50 (bp)") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "top")

p_len <- ggplot(df, aes(x = sample, y = total_length, fill = variant)) +
  geom_col(position = "dodge", width = 0.7) +
  scale_y_continuous(labels = function(x) format(x, big.mark = ",", scientific = FALSE)) +
  scale_fill_manual(values = palette, name = NULL) +
  labs(x = NULL, y = "Total assembly length (bp)") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "none")

combined <- wrap_plots(list(p_n50, p_len), ncol = 1)
n_samples <- length(unique(df$sample))
final_plot <- with_title_bar(combined, "Assembly Quality", size = 10, font_family = font_family)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "magma_assembly_quality",
       samples = lapply(unique(df$sample), function(s) {
         rows <- df[df$sample == s, , drop = FALSE]
         setNames(lapply(seq_len(nrow(rows)), function(i)
           as.list(rows[i, c("num_contigs", "total_length", "largest_contig", "gc_pct", "n50", "l50")])),
                 as.character(rows$variant))
       })),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

width <- max(9, 0.5 * n_samples); height <- 9
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(levels(df$variant), legend_position = "top", show_labels = TRUE,
                                          background = bg, font_family = font_family, palette = palette),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(df, file.path(args$out_dir, "magma_assembly_quality.rds"))

log_line("[magma_assembly_quality] wrote data.json, default_style.json, magma_assembly_quality.rds, preview.png, plot_final.rds")
