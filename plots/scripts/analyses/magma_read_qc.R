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

args <- parse_cli_args(defaults = list(metric = "all", samples = ""))
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

# --samples restricts the figure to a subset. A real run has dozens of
# samples and the x axis becomes unreadable well before that; the underlying
# table is unchanged, only what is drawn.
selected <- trimws(strsplit(args$samples %||% "", ",", fixed = TRUE)[[1]])
selected <- selected[nzchar(selected)]
if (length(selected) > 0) {
  unknown <- setdiff(selected, unique(df$sample))
  if (length(unknown) > 0) {
    stop(sprintf("--samples names %d sample(s) this run has no QC output for: %s. Available: %s",
                 length(unknown), paste(unknown, collapse = ", "), paste(sort(unique(df$sample)), collapse = ", ")))
  }
  df <- df[df$sample %in% selected, , drop = FALSE]
  log_line("[magma_read_qc] restricted to %d of the run's samples", length(selected))
}

df$stage <- factor(df$stage, levels = c("before", "after"),
                   labels = c("Before cleaning", "After cleaning"))
palette <- resolve_palette(levels(df$stage), style)

# Every metric build_magma_qc_table.R actually parses, not just the two the
# first version drew. Which ones have data depends on which QC tool ran for
# the sample's read type: fastp reports quality and GC, NanoPlot reports read
# length and read-length N50, both report read and base counts. A metric with
# no data anywhere in the run is skipped rather than drawn empty.
#
# `scale` exists because q30_rate is stored as a fraction and read as a
# percentage; everything else is plotted as parsed.
METRICS <- list(
  reads  = list(col = "total_reads",  label = "Reads",                scale = 1,   comma = TRUE),
  bases  = list(col = "total_bases",  label = "Bases",                scale = 1,   comma = TRUE),
  q30    = list(col = "q30_rate",     label = "Q30 rate (%)",         scale = 100, comma = FALSE),
  gc     = list(col = "gc_content",   label = "GC content (%)",       scale = 100, comma = FALSE),
  length = list(col = "mean_length",  label = "Mean read length (bp)", scale = 1,  comma = TRUE),
  n50    = list(col = "n50",          label = "Read length N50 (bp)", scale = 1,   comma = TRUE)
)

metric_arg <- args$metric
if (!(metric_arg %in% c("all", names(METRICS)))) {
  stop(sprintf("--metric must be 'all' or one of: %s (got '%s')",
               paste(names(METRICS), collapse = ", "), metric_arg))
}
wanted <- if (metric_arg == "all") names(METRICS) else metric_arg

build_panel <- function(spec, show_legend) {
  sub <- df[!is.na(df[[spec$col]]), , drop = FALSE]
  if (nrow(sub) == 0) return(NULL)
  p <- ggplot(sub, aes(x = sample, y = .data[[spec$col]] * spec$scale, fill = stage)) +
    geom_col(position = "dodge", width = 0.7) +
    scale_fill_manual(values = palette, name = NULL) +
    labs(x = NULL, y = spec$label) +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1),
          legend.position = if (show_legend) "top" else "none")
  if (spec$comma) {
    p <- p + scale_y_continuous(labels = function(x) format(x, big.mark = ",", scientific = FALSE))
  }
  p
}

panels <- list()
for (m in wanted) {
  p <- build_panel(METRICS[[m]], show_legend = length(panels) == 0)
  if (!is.null(p)) panels[[length(panels) + 1]] <- p
}
if (length(panels) == 0) {
  stop(sprintf("No QC data for metric '%s' in this run -- fastp reports reads/bases/Q30/GC, NanoPlot reports reads/bases/read length/read-length N50, so which metrics exist depends on the read type each sample was run as.",
               metric_arg))
}
log_line("[magma_read_qc] plotting %d metric panel(s): %s", length(panels), paste(wanted, collapse = ", "))

combined <- wrap_plots(panels, ncol = 1)
n_samples <- length(unique(df$sample))
width <- max(9, 0.5 * n_samples)
final_plot <- with_title_bar(combined, "Read Cleaning: Before vs. After", size = 10, font_family = font_family, plot_width_in = width)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "magma_read_qc", metric = metric_arg,
       samples = lapply(unique(df$sample), function(s) {
         rows <- df[df$sample == s, , drop = FALSE]
         list(sample = s, tool = rows$tool[1],
             before = as.list(rows[rows$stage == "Before cleaning", c("total_reads", "total_bases", "q30_rate", "gc_content", "mean_length", "n50")]),
             after = as.list(rows[rows$stage == "After cleaning", c("total_reads", "total_bases", "q30_rate", "gc_content", "mean_length", "n50")]))
       })),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

height <- 4 * length(panels) + 1
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(levels(df$stage), legend_position = "top", show_labels = TRUE,
                                          background = bg, font_family = font_family, palette = palette),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(df, file.path(args$out_dir, "magma_read_qc.rds"))

log_line("[magma_read_qc] wrote data.json, default_style.json, magma_read_qc.rds, preview.png, plot_final.rds")
