# Genome size vs. GC content across every genome in the run, coloured by
# taxonomy or any other grouping column.
#
# This is the standard orientation figure of an isolate collection, and it
# earns its place by catching a specific, common problem that neither
# CheckM2 nor QUAST reports: a genome whose size and GC do not sit where its
# assigned taxonomy says they should. Genome size and GC content are strongly
# conserved within a genus, so an isolate landing far from its own cluster is
# either misassigned, contaminated, or a genuinely unusual strain -- and which
# of those it is, is exactly what the surrounding cluster tells you. The
# quality overview (completeness vs. contamination) cannot show this, because
# a chimera of two organisms with complementary marker sets scores well on
# both of its axes.
#
# --y_metric switches the vertical axis among the QUAST/CheckM2 measurements
# already in the genome table, so the same layout also serves "size vs.
# contiguity" and "size vs. coding density" without a separate card.

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
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(y_metric = "gc", label_genomes = "true"))
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var

log_line("[sigma_genome_landscape] reading cached SIGMA table from %s", args$sigma_table_rds)
loaded <- readRDS(args$sigma_table_rds)
df <- loaded$genome_summary
coldata <- loaded$coldata

if (!(group_var %in% colnames(coldata))) {
  stop(sprintf("group_var '%s' is not available. Available columns: %s",
               group_var, paste(colnames(coldata), collapse = ", ")))
}
df$Group <- as.character(coldata[df$sample, group_var])
df$Group[is.na(df$Group)] <- "Unassigned"

# GC is reported by both QUAST (percent) and CheckM2 (fraction) -- QUAST's is
# used because it is measured on the same assembly QUAST's other metrics
# describe, and its percent scale needs no conversion.
Y_METRICS <- list(
  gc            = list(col = "quast_gc_pct",             label = "GC content (%)"),
  n50           = list(col = "quast_n50",                label = "N50 (bp)"),
  contigs       = list(col = "quast_num_contigs",        label = "Contigs"),
  coding        = list(col = "checkm2_coding_sequences", label = "Coding sequences"),
  completeness  = list(col = "checkm2_completeness",     label = "Completeness (%)"),
  coverage      = list(col = "coverm_mean",              label = "Mean coverage (x)")
)
y_key <- args$y_metric
if (!(y_key %in% names(Y_METRICS))) {
  stop(sprintf("--y_metric must be one of: %s (got '%s')", paste(names(Y_METRICS), collapse = ", "), y_key))
}
y_spec <- Y_METRICS[[y_key]]

if (!(y_spec$col %in% colnames(df))) {
  stop(sprintf("This run has no '%s' column -- the tool that produces it did not run.", y_spec$col))
}
plot_df <- df[!is.na(df$quast_total_length) & !is.na(df[[y_spec$col]]), , drop = FALSE]
if (nrow(plot_df) == 0) {
  stop(sprintf("No genome in this run has both an assembly length and a %s value.", y_spec$label))
}
log_line("[sigma_genome_landscape] %d genome(s), y = %s, grouped by %s",
         nrow(plot_df), y_spec$col, group_var)

palette <- resolve_palette(sort(unique(plot_df$Group)), style)
show_labels <- !identical(tolower(args$label_genomes), "false")

# Size on the x axis in megabases: a bacterial genome is 1-10 Mb and raw base
# counts make the axis unreadable for no gain.
plot_df$size_mb <- plot_df$quast_total_length / 1e6

p <- ggplot(plot_df, aes(x = size_mb, y = .data[[y_spec$col]], color = Group)) +
  geom_point(size = 4, alpha = 0.9) +
  scale_color_manual(values = palette, name = group_var) +
  labs(x = "Assembly size (Mb)", y = y_spec$label) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "right")

if (show_labels) {
  p <- p + geom_text_repel(aes(label = sample), size = 3.4, family = font_family, color = "black",
                           box.padding = 0.4, point.padding = 0.3, max.overlaps = 20, show.legend = FALSE)
}
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- sprintf("Genome Landscape: assembly size vs. %s (%d genomes)", y_spec$label, nrow(plot_df))
width <- 12
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.08,
                             font_family = font_family, plot_width_in = width)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "sigma_genome_landscape", group_var = group_var, y_metric = y_key,
       genomes = lapply(seq_len(nrow(plot_df)), function(i) list(
         genome = plot_df$sample[i], group = plot_df$Group[i],
         assembly_size_bp = plot_df$quast_total_length[i],
         y_value = plot_df[[y_spec$col]][i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

height <- 8
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(sort(unique(plot_df$Group)), legend_position = "right",
                                          show_labels = show_labels, background = bg,
                                          font_family = font_family, palette = palette),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(plot_df, file.path(args$out_dir, "sigma_genome_landscape.rds"))

log_line("[sigma_genome_landscape] wrote data.json, default_style.json, sigma_genome_landscape.rds, preview.png, plot_final.rds")
