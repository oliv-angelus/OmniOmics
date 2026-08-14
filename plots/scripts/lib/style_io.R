# Reads/writes the small style JSON that is the actual contract between the R
# compute step and the Plots tab's "Personalizar" panel: default_style.json
# is what the compute step derives from the data (Dark2 colors per
# group/taxon, a legend position, a label toggle, background/font); a
# subsequent run reads back a user-edited style.json (built by the Flutter
# side, then passed in explicitly via --style_json, see
# read_style_from_path) and re-runs the analysis with those overrides
# applied (see plot_theme.R's resolve_palette/base_theme). Re-running the
# real computation on every style tweak, rather than keeping a restyle-only
# fast path, is a deliberate simplification: these analyses finish in a few
# seconds against real data, so the extra cost is small compared to the
# machinery a recompute-free path would need.
suppressMessages(library(jsonlite))

# Expects plot_theme.R (dark2_palette) to already be sourced by the caller --
# not self-sourced here to avoid fragile "find my own path" tricks; every
# analysis script sources lib/*.R together in a fixed order anyway.

#' Builds the default style from a categorical grouping vector, in the same
#' Dark2 palette every analysis in microbiome.R already uses (see
#' plot_theme.R's dark2_palette). background/font_family are always included
#' (even though every analysis' own default is already "gray90"/"serif") so
#' the Flutter "Personalizar" panel always has a complete, consistent shape
#' to seed its editable state from, regardless of which analysis produced it.
#'
#' `palette`, when given, is written as-is instead of a fresh dark2_palette
#' -- pass the SAME resolve_palette(groups, style) result the plot itself
#' was built with here, or default_style.json silently diverges from the
#' real plot: a real bug caught (the app's own "Personalizar"
#' feature verification), where every one of the 6 callers computed the
#' overridden palette for the plot correctly but then wrote a *fresh,
#' un-overridden* one to default_style.json regardless -- so re-opening the
#' customize panel after a replot would show the color swatches silently
#' reverting to the original Dark2 defaults instead of what was actually
#' just applied.
default_style_for_groups <- function(groups, legend_position = "right", show_labels = FALSE,
                                      background = "gray90", font_family = "serif", palette = NULL) {
  list(
    palette = as.list(palette %||% dark2_palette(groups)),
    legend_position = legend_position,
    show_labels = show_labels,
    background = background,
    font_family = font_family,
    # Seeds the Personalizar panel's own toggles with the same defaults
    # base_theme applies when a style has neither key (see plot_theme.R).
    show_grid = TRUE,
    show_panel_border = FALSE
  )
}

write_style_json <- function(style, path) {
  write_json(style, path, auto_unbox = TRUE, pretty = TRUE)
}

#' Reads style.json if a user has already edited one for this run, otherwise
#' falls back to default_style.json (or NULL if neither exists yet, e.g. the
#' compute step is being run for the very first time).
read_effective_style <- function(run_dir) {
  edited <- file.path(run_dir, "style.json")
  default <- file.path(run_dir, "default_style.json")
  if (file.exists(edited)) return(fromJSON(edited, simplifyVector = FALSE))
  if (file.exists(default)) return(fromJSON(default, simplifyVector = FALSE))
  NULL
}

#' Recursively fixes up any bare hex-color string found in a parsed style
#' list -- a real, load-bearing defense, not speculative: flutter_colorpicker
#' 1.1.0's `toHexString` extension has an upstream bug where it ignores its
#' own `includeHashSign`/`enableAlpha` arguments and always returns an
#' 8-digit ARGB hex with NO leading '#' (e.g. black comes back as
#' "FF000000", alpha-first, not "#000000") -- the app's own color-picker call
#' site is now fixed to call the package's un-broken colorToHex directly
#' instead, but any style.json a user already saved with the OLD buggy value
#' is still sitting on disk and would otherwise crash the very next replot
#' with ggplot2's own unhelpful "Unknown colour name: FF000000" (confirmed:
#' this is exactly the reported crash). A bare 8-digit string here is
#' Flutter's ARGB byte order (alpha first), not R's own "#RRGGBBAA" (alpha
#' last) -- naively prepending '#' would silently reinterpret it as a
#' near-transparent wrong color instead of fixing it, so the alpha byte is
#' dropped and the remaining 6 digits (the real RGB) are used with a '#'
#' added. A bare 6-digit string (no alpha ever included) just gets '#' added.
#' Every other value (font family names, "gray90", legend_position, booleans,
#' numbers) is untouched -- the regexes only match strings that are ENTIRELY
#' 6 or 8 hex digits.
normalize_style_colors <- function(x) {
  if (is.list(x)) return(lapply(x, normalize_style_colors))
  if (is.character(x) && length(x) == 1) {
    if (grepl("^[0-9A-Fa-f]{8}$", x)) return(paste0("#", substr(x, 3, 8)))
    if (grepl("^[0-9A-Fa-f]{6}$", x)) return(paste0("#", x))
  }
  x
}

#' Reads a style JSON from an explicit path -- what every analysis script
#' actually uses (via its optional --style_json arg): each "Replotar" run
#' gets its own fresh --out_dir, same as any other run, so there is no fixed
#' run_dir convention to look a previous style.json up by; the Flutter side is the
#' source of truth for "the current style" across replots within one
#' workspace session and hands it over explicitly each time. NULL (not an
#' error) when no path was given, so callers can write
#' `style <- read_style_from_path(args$style_json)` unconditionally.
read_style_from_path <- function(path) {
  if (is.null(path) || path == "" || !file.exists(path)) return(NULL)
  normalize_style_colors(fromJSON(path, simplifyVector = FALSE))
}
