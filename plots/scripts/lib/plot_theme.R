# The Plots tab's one visual "design system", extracted ONCE from
# microbiome.R (the user's own validated thesis script) and reused by every
# analysis in scripts/analyses/ -- this is deliberately the single place that
# defines what "looks like an OmniOmics figure" means, so nothing drifts
# panel-by-panel the way copy-pasted ggplot theme blocks would.
suppressMessages({
  library(ggplot2)
  library(patchwork)
  library(RColorBrewer)
})

#' The shared panel look: serif font by default, gray90 panel with white
#' gridlines, black axis text -- present in every plot in microbiome.R
#' regardless of plot type. `bg`/`font_family` are overridable (the Plots
#' tab's "Personalizar" panel writes a style.json with these, see
#' style_io.R's read_style_from_path) so a user can pick a different
#' background/font without touching this file -- everything else
#' (legend.position, axis text angle, facet strip styling,...) is still
#' added with `+ theme(...)` on top of this by the calling script.
#'
#' `font_scale` uniformly multiplies the base axis text/title sizes below
#' (1.0 = every analysis's original hardcoded size) -- a user-facing "Tamanho
#' da fonte" slider in the Personalizar panel. It only scales THIS base size;
#' a script's own later `+ theme(axis.text.y = element_text(size = 11,...))`
#' override (e.g. differential_abundance_deseq2's italic genus labels) still
#' wins for that specific element, same as any other layered theme call --
#' a deliberate, minimal scope, not every hardcoded size in every script.
#' Relative luminance of a color name/hex, 0 (black) to 1 (white).
.luminance <- function(bg) {
  rgbv <- tryCatch(grDevices::col2rgb(bg)[, 1] / 255, error = function(e) c(1, 1, 1))
  0.299 * rgbv[1] + 0.587 * rgbv[2] + 0.114 * rgbv[3]
}

#' The background blended toward black (if it is light) or white (if dark).
#' Used for the optional panel border, where a strong `amount` gives a clearly
#' visible outline against any background the color picker can produce.
.contrast_color <- function(bg, amount) {
  rgbv <- tryCatch(grDevices::col2rgb(bg)[, 1] / 255, error = function(e) c(1, 1, 1))
  target <- if (.luminance(bg) > 0.5) 0 else 1
  mixed <- rgbv * (1 - amount) + target * amount
  grDevices::rgb(mixed[1], mixed[2], mixed[3])
}

#' Grid color: white, the ggplot2 theme_grey look this app has always had,
#' except on a background too light for white to register at all.
#'
#' The grid used to be hardcoded white, which worked only because every
#' analysis defaulted to a gray background. That is still the default, so
#' white stays the normal answer -- but the Personalizar panel's color picker
#' can produce any background, and on a white or near-white one a white grid
#' is invisible, which would make the grid toggle look broken rather than off.
#' There, and only there, the grid blends toward black instead.
#'
#' The 0.06 threshold is a real boundary, not a round number: gray90 (the
#' default) sits 0.10 below white, comfortably on the white-grid side, while
#' pure white sits at 0 and a near-white tint has too little headroom for a
#' white line to be seen.
.grid_color <- function(bg, amount) {
  if (1 - .luminance(bg) >= 0.06) return("white")
  .contrast_color(bg, amount)
}

#' `show_grid` / `show_border` come from the Personalizar panel via `style`
#' rather than as bare arguments, so the 30-odd call sites stay identical --
#' every analysis already has `style` in scope. Defaults match what the
#' analyses looked like before the toggles existed: grid on, no panel border.
base_theme <- function(bg = "gray90", font_family = "serif", font_scale = 1.0, style = NULL) {
  show_grid <- if (is.null(style$show_grid)) TRUE else isTRUE(style$show_grid)
  show_border <- isTRUE(style$show_panel_border)
  grid_major <- if (show_grid) element_line(color = .grid_color(bg, 0.14), linewidth = 0.5) else element_blank()
  grid_minor <- if (show_grid) element_line(color = .grid_color(bg, 0.08), linewidth = 0.25) else element_blank()
  theme(
    text = element_text(family = font_family),
    axis.text = element_text(size = 12 * font_scale, color = "black"),
    axis.title = element_text(size = 13 * font_scale, face = "bold", color = "black"),
    panel.background = element_rect(fill = bg),
    panel.grid.major = grid_major,
    panel.grid.minor = grid_minor,
    # fill = NA is required, not cosmetic: a panel.border with a fill paints
    # OVER the data, since ggplot draws the border after the layers.
    panel.border = if (show_border) element_rect(fill = NA, color = .contrast_color(bg, 0.85), linewidth = 0.6) else element_blank(),
    plot.margin = unit(c(0, 0.5, 0.5, 0.5), "cm")
  )
}

#' Blanks out one or both cartesian axes (title + tick text + ticks)
#' entirely -- the Personalizar panel's "Ocultar eixo X"/"Ocultar eixo Y"
#' toggles. Applied as its own final `+ theme(...)` layer AFTER a script's
#' complete plot (base_theme + every other `+ theme(...)` call), not
#' folded into base_theme itself -- several callers add their own
#' axis.text.x/axis.text.y overrides after base_theme (e.g.
#' taxonomic_composition's/core_microbiome's rotated sample labels), and
#' ggplot2 themes merge with "last one wins" per element, so a hide baked
#' into base_theme would just get silently undone by those later calls.
#' Calling this last, on the fully-built plot, guarantees it always wins
#' regardless of what came before. Only meaningful for the 9 analyses that
#' use base_theme at all -- cooccurrence_network (theme_void, no
#' cartesian axes), venn_diagram, and upset_plot (ComplexUpset's own
#' internally-composed sub-plots) don't call this; the Personalizar panel
#' hides these two controls for those three rather than offering a checkbox
#' that would silently do nothing (see plot_style_panel.dart's
#' _kNoAxisControlAnalyses).
apply_axis_visibility <- function(plot, hide_x_axis = FALSE, hide_y_axis = FALSE) {
  if (isTRUE(hide_x_axis)) {
    plot <- plot + theme(axis.text.x = element_blank(), axis.title.x = element_blank(), axis.ticks.x = element_blank())
  }
  if (isTRUE(hide_y_axis)) {
    plot <- plot + theme(axis.text.y = element_blank(), axis.title.y = element_blank(), axis.ticks.y = element_blank())
  }
  plot
}

#' The bold gray70 title-bar panel every figure in microbiome.R stacks on top
#' of itself via patchwork (see e.g. section 8's `label_beta`). A plain
#' ggplot object, not text alone, because that's what lets it sit in a
#' patchwork layout next to the real plot. The gray70 accent itself is a
#' fixed design choice, not user-customizable (only the plot panel's own
#' background is) -- font_family still applies, since it's text.
title_bar <- function(label, size = 10, font_family = "serif") {
  ggplot() +
    annotate("text", x = 1, y = 1, label = label, size = size,
              fontface = "bold", family = font_family, hjust = 0.5, lineheight = 0.9) +
    xlim(0, 2) + ylim(0.5, 1.5) +
    theme_void() +
    theme(panel.background = element_rect(fill = "gray70", color = NA))
}

#' Real rendered width (inches) of `label` at `size`/bold/`font_family` --
#' measured via grid's own text metrics (a real text grob), not a guessed
#' characters-per-inch heuristic (font/weight/size all change how many
#' characters fit per inch, so a fixed guess is wrong for some combination of
#' them). `size` here is a ggplot2 "size" unit (as passed to
#' `annotate("text", size =...)`), converted to points via ggplot2's own `.pt`
#' constant, matching exactly what title_bar actually renders.
#'
#' Text metrics are NOT device-independent, which is the whole reason the
#' wrapping used to be wrong. grid measures on whatever device is current, and
#' under Rscript nothing is open, so measurement fell to the null device --
#' whose serif metrics are much narrower than the ones ggsave renders with. For
#' one real title the three disagree badly:
#'
#'   null device (what this used to measure on)   7.79 in
#'   grDevices::png (cairo)                       8.00 in
#'   ragg::agg_png (what ggsave actually uses)    9.67 in
#'
#' A title measured at 7.79in and given 7.8in of room therefore rendered at
#' 9.67in and ran off both ends of the bar. Callers must measure inside
#' `on_render_device()` so these numbers refer to the same font as the output.
title_text_width_in <- function(label, size, font_family) {
  grid::convertWidth(
    grid::grobWidth(grid::textGrob(label, gp = grid::gpar(fontsize = size *.pt, fontface = "bold", fontfamily = font_family))),
    "inches", valueOnly = TRUE
  )
}

#' Evaluates `expr` with a device open that matches the one ggsave will render
#' the PNG with, so any text measured inside it uses the font the output will
#' actually use. See title_text_width_in for what goes wrong without this.
#' Falls back to evaluating `expr` as-is if ragg is unavailable -- a wrong
#' measurement is still better than refusing to draw the figure.
on_render_device <- function(width_in, height_in, expr) {
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(tempfile(fileext = ".png"), width = width_in, height = height_in,
                  units = "in", res = 150)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  force(expr)
}

#' Width in inches of the region a stacked title bar will actually span.
#'
#' patchwork aligns the bar to the plot's PANEL, not to the figure, so the
#' y-axis labels on the left and the legend on the right are subtracted before
#' the bar sees the width. That was previously approximated as a flat 65% of
#' the figure, calibrated by eye; it is measurable instead. Everything between
#' the first and last panel column belongs to the panel region (with facets,
#' the inter-panel gaps included), so the answer is the figure width minus the
#' fixed chrome outside them -- no need to resolve the panels' own "null" units.
#'
#' Must be called inside on_render_device(): the chrome widths depend on text
#' metrics too.
#'
#' Measures ~0.15in wide against the rendered bar (the panel's own inset), which
#' TITLE_BAR_PADDING_IN covers. Returns NA when `plot` is not a plain ggplot
#' (a patchwork, say), leaving the caller to fall back.
measure_panel_width_in <- function(plot, width_in) {
  tryCatch({
    g <- ggplot2::ggplotGrob(plot)
    fixed <- grid::convertWidth(g$widths, "in", valueOnly = TRUE)  # null units -> 0
    cols <- g$layout[grepl("^panel", g$layout$name), "l"]
    if (!length(cols)) return(NA_real_)
    left <- if (min(cols) > 1) sum(fixed[seq_len(min(cols) - 1)]) else 0
    right <- if (max(cols) < length(fixed)) sum(fixed[seq(max(cols) + 1, length(fixed))]) else 0
    width_in - left - right
  }, error = function(e) NA_real_)
}

#' Slack left between the title text and the bar's ends: the ~0.15in by which
#' measure_panel_width_in reads wide, plus enough that a title which only just
#' fits still looks placed rather than jammed against the edges.
TITLE_BAR_PADDING_IN <- 0.4

#' Wraps `title` onto as many lines as needed so no line exceeds
#' `max_width_in` inches when actually rendered. Needed because
#' `annotate("text",...)` (what title_bar uses) never wraps or shrinks on
#' its own, so a long title (e.g. de_heatmap's "Top N DE Genes (VST, row
#' z-score): X vs Y") visibly overflowed past the gray70 title bar's left AND
#' right edges on any plot narrow enough that the title's real rendered width
#' exceeded the plot's own width -- most pronounced at small RNA-seq sample
#' counts, where the plot itself is narrow. Returns `title` unchanged (one
#' line) if it already fits, which is the common case.
wrap_title_to_width <- function(title, max_width_in, size, font_family) {
  if (title_text_width_in(title, size, font_family) <= max_width_in) return(title)
  wrap_chars <- max(10, nchar(title) - 1)
  repeat {
    wrapped_lines <- strwrap(title, width = wrap_chars)
    widest_in <- max(vapply(wrapped_lines, title_text_width_in, numeric(1), size = size, font_family = font_family))
    if (widest_in <= max_width_in || wrap_chars <= 10) break
    wrap_chars <- wrap_chars - 2
  }
  paste(wrapped_lines, collapse = "\n")
}

#' Stacks `plot` under a title_bar(title), same plot_layout(heights=...)
#' proportion used throughout microbiome.R (title gets ~10-15% of the height).
#' `plot_width_in`, when given, MUST be the same width the caller is about
#' to pass to `ggsave` -- lets the title auto-wrap (see
#' wrap_title_to_width) to actually fit that real output width instead of
#' silently overflowing it. Optional and backward-compatible: omitting it
#' (NULL) keeps the exact old one-line-always behavior, for any call site
#' not yet retrofitted to pass its own width through.
with_title_bar <- function(plot, title, size = 10, title_height = 0.1, font_family = "serif",
                           plot_width_in = NULL, plot_height_in = NULL) {
  if (!is.null(plot_width_in)) {
    # Both halves of this used to be guesses, and they were wrong in opposite
    # directions: the title was measured on the null device (~20% narrower than
    # the font ggsave renders) and then fitted to a flat 65% of the figure width
    # (narrower than the bar really is). The two errors did not cancel, and
    # titles ran off both ends of the bar -- scripts/check_title_clipping.py
    # exists to catch exactly that. Both are now measured: the text against the
    # rendering device's own font, the bar against the plot's actual panel.
    height_in <- if (is.null(plot_height_in)) plot_width_in else plot_height_in
    title <- on_render_device(plot_width_in, height_in, {
      available <- measure_panel_width_in(plot, plot_width_in)
      # A patchwork or anything else with no measurable panel keeps the old
      # conservative fraction: it over-wraps, and an extra line beats clipping.
      if (!is.finite(available) || available <= TITLE_BAR_PADDING_IN) {
        available <- plot_width_in * 0.65
      } else {
        available <- available - TITLE_BAR_PADDING_IN
      }
      wrap_title_to_width(title, available, size, font_family)
    })
  }
  n_lines <- length(strsplit(title, "\n", fixed = TRUE)[[1]])
  title_height <- title_height * n_lines
  title_bar(title, size = size, font_family = font_family) / plot + patchwork::plot_layout(heights = c(title_height, 1))
}

#' colorRampPalette(brewer.pal(8, "Dark2"))(n) named by `labels` -- the exact
#' group-coloring recipe reused for every categorical grouping variable
#' (alpha/beta diversity groups, DESeq2 enrichment direction, network
#' phyla, RDA groups,...) throughout microbiome.R.
dark2_palette <- function(labels) {
  labels <- unique(labels)
  stats::setNames(grDevices::colorRampPalette(RColorBrewer::brewer.pal(8, "Dark2"))(length(labels)), labels)
}

#' Layers a style's saved `palette` overrides (user hex-picked colors from
#' the Plots tab's "Personalizar" panel, see style_io.R) on top of an
#' already-computed named color vector -- for palettes that aren't the
#' plain Dark2 ramp (e.g. taxonomic_composition's Paired+Dark2+Set2 ramp
#' with a fixed black "Others"). A key the style doesn't cover (a new level
#' that didn't exist when the style was first saved, or no style at all)
#' keeps its computed color -- overrides layer on top, they never leave a
#' label uncolored.
apply_palette_overrides <- function(base_colors, style = NULL) {
  overrides <- style$palette
  if (is.null(overrides)) return(base_colors)
  for (name in names(overrides)) {
    if (name %in% names(base_colors)) base_colors[[name]] <- overrides[[name]]
  }
  base_colors
}

#' Same coloring recipe as dark2_palette, with a style's overrides applied
#' -- the common case (alpha/beta diversity groups, DESeq2 enrichment
#' direction, RDA groups, IndVal indicated groups, Venn sets,...).
resolve_palette <- function(labels, style = NULL) {
  apply_palette_overrides(dark2_palette(labels), style)
}

#' Formats a p-value the same way every analysis in microbiome.R does:
#' "p < 0.001" below that threshold, otherwise "p = 0.0123" (4 decimals).
format_p_value <- function(p) {
  if (is.na(p)) return("p = NA (not enough samples/permutations to test)")
  if (p < 0.001) return("p < 0.001")
  paste("p =", format(round(p, 4), nsmall = 4))
}
