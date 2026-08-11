# Real taxonomic composition analysis (stacked relative-abundance bars,
# top N taxa + "Others"), direct translation of microbiome.R's section 9.
# See plots/manifest.yaml for parameter descriptions.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "composition_panels.R"))

suppressMessages({
  library(phyloseq)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(RColorBrewer)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(rank = "all", top_n = "20"))
top_n_taxa <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[taxonomic_composition] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[taxonomic_composition] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

ranks_to_plot <- resolve_ranks_to_plot(ps, args$rank)

panels <- lapply(ranks_to_plot, function(rk)
  build_taxonomic_panel(ps, rk, top_n_taxa, style, bg, font_family, font_scale, hide_x_axis, hide_y_axis))
names(panels) <- ranks_to_plot

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

ranks_json <- taxonomic_panels_json(panels)

write_json(
  list(analysis_id = "taxonomic_composition", ranks = ranks_json),
  file.path(args$out_dir, "data.json"),
  auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# Named palette exported for editing is the FIRST plotted rank's -- in
# "all" mode each rank panel gets its own independently-computed top-N
# taxa, so there's no single shared key space across panels; the first
# rank's palette is still a real, useful starting point for the common
# case of a single --rank being requested (the primary interactive use
# case -- pick a rank, tweak its colors, replot).
effective_style <- list(
  palette = as.list(panels[[1]]$palette),
  legend_position = "right",
  show_labels = FALSE,
  background = bg,
  font_family = font_family
)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(ps = ps, panels = panels), file.path(args$out_dir, "taxonomic_composition.rds"))

final_plot <- combine_taxonomic_panels(panels)
n_panels <- length(panels)
# Stacked bars get unreadably thin once there are many samples on the x-axis
# -- width grows with nsamples(ps) instead of staying fixed at a count tuned
# for the ~25-sample demo fixture, confirmed cramped at 80 samples.
plot_width <- max(14, nsamples(ps) * 0.18)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = 7 * n_panels, units = "in", dpi = 120, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = plot_width, height = 7 * n_panels),
        file.path(args$out_dir, "plot_final.rds"))

log_line("[taxonomic_composition] wrote data.json, default_style.json, taxonomic_composition.rds, preview.png (%d rank panel(s))", n_panels)
