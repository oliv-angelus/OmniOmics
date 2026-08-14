# Where each recovered MAG actually lives: relative abundance of every MAG
# across every sample, from CoverM's cross-sample mapping.
#
# This is the figure that reconnects the MAGs to the community they came from.
# MAGMA maps every sample's reads back against the dereplicated MAG set
# (10_MAG_COVERAGE), so the abundance matrix already exists -- a MAG assembled
# from one sample carries a real, measured abundance in all the others, which is
# what distinguishes "recovered here" from "present here".
#
# Rows can be grouped by any per-MAG column the loader carries (GTDB lineage,
# MIMAG tier, dereplication status). Columns deliberately cannot: the loader's
# coldata is per-MAG, holding the metadata each MAG inherits from its *source*
# sample, so it describes 9 MAGs rather than the 18 samples the abundance matrix
# spans. Grouping samples would need the loader to retain the sample-level
# metadata table as well; pretending otherwise here would silently mislabel
# columns.
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
  library(dplyr)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(
  group_by = "gtdbtk_phylum",
  only_dereplicated = "true",
  transform = "sqrt",
  min_abundance = "0"
))
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[magma_mag_abundance] reading cached MAG table from %s", args$magma_mag_table_rds)
loaded <- readRDS(args$magma_mag_table_rds)
mag_table <- loaded$mag_table
ab <- loaded$abundance

if (is.null(ab) || nrow(ab) == 0) {
  stop(paste("This run has no cross-sample MAG abundance. CoverM has to have run",
             "(10_MAG_COVERAGE) after dereplication."))
}

only_derep <- tolower(args$only_dereplicated) %in% c("true", "yes", "1")
if (only_derep && "dereplicated" %in% colnames(mag_table)) {
  keep <- mag_table$mag[!is.na(mag_table$dereplicated) & mag_table$dereplicated]
  # A run where dRep kept nothing is a real state, not an error to hide: say so
  # rather than silently falling back to the full set.
  if (length(keep) == 0) stop("No MAG survived dereplication in this run.")
  ab <- ab[ab$mag %in% keep, , drop = FALSE]
}

min_ab <- suppressWarnings(as.numeric(args$min_abundance))
if (is.na(min_ab)) min_ab <- 0
if (min_ab > 0) {
  # Filters MAGs, not cells: blanking individual cells below a threshold would
  # make a MAG look absent from a sample where it was measured and simply rare.
  kept <- ab %>% group_by(mag) %>% summarise(peak = max(rel_abundance, na.rm = TRUE)) %>%
    filter(peak >= min_ab) %>% pull(mag)
  dropped <- length(unique(ab$mag)) - length(kept)
  if (length(kept) == 0) {
    stop(sprintf("No MAG reaches %.2f%% in any sample. Lower the threshold.", min_ab))
  }
  if (dropped > 0) log_line("[magma_mag_abundance] %d MAG(s) below %.2f%% everywhere", dropped, min_ab)
  ab <- ab[ab$mag %in% kept, , drop = FALSE]
}

group_by_col <- args$group_by
if (!is.null(group_by_col) && group_by_col != "" && !group_by_col %in% colnames(mag_table)) {
  stop(sprintf("group_by '%s' is not a per-MAG column. Available: %s",
               group_by_col, paste(colnames(mag_table), collapse = ", ")))
}
has_group <- !is.null(group_by_col) && group_by_col != ""

# Order MAGs by their group, then by overall abundance inside it, so related
# genomes sit together and the dominant ones lead -- reading order carries
# information instead of being alphabetical by accident.
totals <- ab %>% group_by(mag) %>% summarise(total = sum(rel_abundance, na.rm = TRUE))
order_tbl <- totals %>% left_join(mag_table[, c("mag", if (has_group) group_by_col)], by = "mag")
if (has_group) {
  order_tbl[[group_by_col]][is.na(order_tbl[[group_by_col]])] <- "unassigned"
  order_tbl <- order_tbl %>% arrange(.data[[group_by_col]], desc(total))
} else {
  order_tbl <- order_tbl %>% arrange(desc(total))
}
ab$mag <- factor(ab$mag, levels = rev(order_tbl$mag))

transform <- tolower(args$transform)
if (!transform %in% c("none", "sqrt", "log10")) {
  stop(sprintf("--transform must be one of: none, sqrt, log10 (got '%s')", transform))
}
# A handful of dominant MAGs otherwise flatten everything else to one colour.
# sqrt is the default rather than log10 because abundance is legitimately zero
# in some samples and log10 has to fudge those; sqrt does not.
ab$shown <- switch(transform,
                   none  = ab$rel_abundance,
                   sqrt  = sqrt(ab$rel_abundance),
                   log10 = log10(ab$rel_abundance + 0.01))
legend_title <- switch(transform,
                       none  = "Relative\nabundance (%)",
                       sqrt  = "Relative\nabundance (%)\n[sqrt scale]",
                       log10 = "Relative\nabundance (%)\n[log10 scale]")

if (has_group) {
  ab$group <- mag_table[[group_by_col]][match(as.character(ab$mag), mag_table$mag)]
  ab$group[is.na(ab$group)] <- "unassigned"
}

n_mags <- length(unique(ab$mag))
n_samples <- length(unique(ab$sample))
log_line("[magma_mag_abundance] %d MAG(s) x %d sample(s), transform=%s", n_mags, n_samples, transform)

p <- ggplot(ab, aes(x = sample, y = mag, fill = shown)) +
  geom_tile(colour = "white", linewidth = 0.3) +
  scale_fill_viridis_c(name = legend_title, option = "mako", direction = -1,
                       # The real percentages on the legend, not the transformed
                       # values, so a reader can quote a number off the figure.
                       labels = function(v) switch(transform,
                                                   none  = sprintf("%.1f", v),
                                                   sqrt  = sprintf("%.1f", v^2),
                                                   log10 = sprintf("%.2f", 10^v - 0.01))) +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 7.5 * font_scale),
        axis.text.y = element_text(size = 7.5 * font_scale),
        panel.grid = element_blank(),
        legend.position = "right")

if (has_group) {
  p <- p + facet_grid(rows = vars(group), scales = "free_y", space = "free_y",
                             switch = "y") +
    theme(strip.placement = "outside",
          strip.text.y.left = element_text(angle = 0, size = 7.5 * font_scale))
}

p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

# Short on purpose. The first version appended the MAG and sample counts and,
# rendered, the title bar came out narrower than the panel and clipped the text
# at BOTH ends -- the facet strip column on the left shifts the panel, so the
# width with_title_bar is given no longer matches where the title sits. Both
# counts are already readable off the axes, and data.json carries them.
title <- paste0("MAG Abundance Across Samples",
                if (only_derep) "  |  dereplicated" else "")
plot_width <- max(9, 3 + n_samples * 0.42)
plot_height <- max(6, 2.4 + n_mags * 0.32)
# with_title_bar's own 0.65 allowance (see plot_theme.R) was calibrated on
# plots whose chrome is a y-axis plus a legend. Faceting adds a strip column
# down the left that eats roughly another fifth of the figure before the title
# bar sees it, and at 0.65 the title still clipped at both ends when rendered.
# Handing over a smaller width makes it wrap earlier, which is the cheap half
# of the fix; the proper one is for with_title_bar to measure the panel rather
# than guess, and that is a change to shared code every analysis depends on.
title_width <- plot_width * (if (has_group) 0.72 else 1)
final_plot <- with_title_bar(p, title, size = 9, title_height = 0.1,
                             font_family = font_family, plot_width_in = title_width)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = plot_height, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = plot_width, height = plot_height),
        file.path(args$out_dir, "plot_final.rds"))

peaks <- ab %>% group_by(mag) %>%
  summarise(peak_sample = sample[which.max(rel_abundance)],
            peak_abundance = max(rel_abundance, na.rm = TRUE),
            mean_abundance = mean(rel_abundance, na.rm = TRUE), .groups = "drop") %>%
  arrange(desc(peak_abundance))

write_json(
  list(analysis_id = "magma_mag_abundance",
       n_mags = n_mags, n_samples = n_samples,
       transform = transform, only_dereplicated = only_derep,
       group_by = if (has_group) group_by_col else NULL,
       mags = lapply(seq_len(nrow(peaks)), function(i) list(
         mag = as.character(peaks$mag[i]),
         peak_sample = as.character(peaks$peak_sample[i]),
         peak_abundance = peaks$peak_abundance[i],
         mean_abundance = peaks$mean_abundance[i]))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null")

log_line("[magma_mag_abundance] done")
