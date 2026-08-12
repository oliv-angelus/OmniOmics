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

args <- parse_cli_args(defaults = list(metric = "all", samples = ""))
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

# --samples restricts the figure to a subset; the x axis of a real run with
# dozens of samples is unreadable otherwise.
selected <- trimws(strsplit(args$samples %||% "", ",", fixed = TRUE)[[1]])
selected <- selected[nzchar(selected)]
if (length(selected) > 0) {
  unknown <- setdiff(selected, unique(df$sample))
  if (length(unknown) > 0) {
    stop(sprintf("--samples names %d sample(s) this run has no MetaQuast output for: %s. Available: %s",
                 length(unknown), paste(unknown, collapse = ", "), paste(sort(unique(df$sample)), collapse = ", ")))
  }
  df <- df[df$sample %in% selected, , drop = FALSE]
  log_line("[magma_assembly_quality] restricted to %d of the run's samples", length(selected))
}

df$variant <- factor(df$variant, levels = c("metaquast", "metaquast_prokaryotic"),
                     labels = c("Full assembly", "Prokaryotic (Tiara-filtered)"))
palette <- resolve_palette(levels(df$variant), style)

# Every column build_magma_assembly_table.R parses from MetaQuast's
# transposed_report.tsv, not just the two the first version drew. N50/L50 are
# a pair worth reading together: N50 is the contig length at which half the
# assembly is in contigs at least that long, L50 is HOW MANY contigs that
# takes -- a high N50 with a high L50 means a few long contigs among many.
METRICS <- list(
  n50            = list(col = "n50",            label = "N50 (bp)",                  comma = TRUE),
  total_length   = list(col = "total_length",   label = "Total assembly length (bp)", comma = TRUE),
  num_contigs    = list(col = "num_contigs",    label = "Contigs",                    comma = TRUE),
  largest_contig = list(col = "largest_contig", label = "Largest contig (bp)",        comma = TRUE),
  l50            = list(col = "l50",            label = "L50 (contigs)",              comma = TRUE),
  gc             = list(col = "gc_pct",         label = "GC (%)",                     comma = FALSE)
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
  p <- ggplot(sub, aes(x = sample, y = .data[[spec$col]], fill = variant)) +
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
  stop(sprintf("MetaQuast reported no values for metric '%s' in this run.", metric_arg))
}
log_line("[magma_assembly_quality] plotting %d metric panel(s): %s", length(panels), paste(wanted, collapse = ", "))

combined <- wrap_plots(panels, ncol = 1)
n_samples <- length(unique(df$sample))
width <- max(9, 0.5 * n_samples)
final_plot <- with_title_bar(combined, "Assembly Quality", size = 10, font_family = font_family, plot_width_in = width)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "magma_assembly_quality", metric = metric_arg,
       samples = lapply(unique(df$sample), function(s) {
         rows <- df[df$sample == s, , drop = FALSE]
         setNames(lapply(seq_len(nrow(rows)), function(i)
           as.list(rows[i, c("num_contigs", "total_length", "largest_contig", "gc_pct", "n50", "l50")])),
                 as.character(rows$variant))
       })),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

height <- 4 * length(panels) + 1
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(levels(df$variant), legend_position = "top", show_labels = TRUE,
                                          background = bg, font_family = font_family, palette = palette),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(df, file.path(args$out_dir, "magma_assembly_quality.rds"))

log_line("[magma_assembly_quality] wrote data.json, default_style.json, magma_assembly_quality.rds, preview.png, plot_final.rds")
