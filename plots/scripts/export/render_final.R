# Publication-quality re-render of an analysis that has already been computed.
# Reads the ggplot object every analyses/*.R saves alongside its preview
# (plot_final.rds) and writes it again at the caller's chosen format, DPI and
# size -- no statistics are recomputed, so this is fast regardless of how
# expensive the original analysis was.
#
# preview.png is deliberately low-DPI and fixed-size (it only has to look
# right inside the app's preview pane); this is the path that produces the
# figure a manuscript actually needs.
#
# Invoked by the backend's POST /api/plots/{run_id}/export (see main.py).

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "plot_theme.R"))

suppressMessages(library(ggplot2))

args <- parse_cli_args(defaults = list(format = "tiff", dpi = "600"))

if (is.null(args$run_dir) || args$run_dir == "") {
  stop("--run_dir is required")
}
if (!dir.exists(args$run_dir)) {
  stop(sprintf("--run_dir does not exist: %s", args$run_dir))
}

plot_rds <- file.path(args$run_dir, "plot_final.rds")

# An analysis that draws straight to a device rather than building a ggplot
# object -- sigma_genome_ring, via circlize -- has no plot object to
# re-render, so it writes its own publication-resolution figure at analysis
# time instead. Finding that file is a success, not the failure the message
# below describes: reporting it as missing would tell the user to re-run an
# analysis that already produced exactly what they asked for.
if (!file.exists(plot_rds)) {
  existing <- list.files(args$run_dir, pattern = "^figure_final\\.(tiff|png|pdf|svg)$", full.names = TRUE)
  if (length(existing) > 0) {
    log_line(paste0("[render_final] %s draws directly to a device and has no re-renderable plot object; ",
                    "its publication figure was written at analysis time -- using %s (%.2f MB)."),
             basename(args$run_dir), basename(existing[1]), file.size(existing[1]) / 1024^2)
    quit(save = "no", status = 0)
  }
  stop(sprintf(paste0("No plot_final.rds in %s -- this run predates the export ",
                      "feature, or the analysis failed before writing its figure. ",
                      "Re-run the analysis and export again."), args$run_dir))
}

saved <- readRDS(plot_rds)
if (!is.list(saved) || is.null(saved$plot)) {
  stop("plot_final.rds is not in the expected list(plot=, width=, height=) shape.")
}
p <- saved$plot

# The analysis's own computed size is the default: heatmaps, faceted panels and
# UpSet plots each pick a width/height their layout actually needs, and
# overriding that with a single fixed size would squash them. --width/--height
# still win when the caller asks for a specific canvas.
width  <- suppressWarnings(as.numeric(args$width  %||% ""))
height <- suppressWarnings(as.numeric(args$height %||% ""))
if (is.na(width)  || width  <= 0) width  <- as.numeric(saved$width  %||% 10)
if (is.na(height) || height <= 0) height <- as.numeric(saved$height %||% 8)

dpi <- suppressWarnings(as.numeric(args$dpi))
if (is.na(dpi) || dpi <= 0) dpi <- 600

fmt <- tolower(args$format %||% "tiff")
VALID <- c("tiff", "png", "pdf", "svg", "jpeg", "eps")
if (!fmt %in% VALID) {
  stop(sprintf("Unsupported --format '%s'. Use one of: %s", fmt, paste(VALID, collapse = ", ")))
}

# Styling is not applied here: palettes, fonts and axis visibility are resolved
# while the analysis computes (see style_io.R's header and plot_theme.R's
# resolve_palette/base_theme), so they are already baked into the saved plot.
# Changing a style means re-running the analysis, which is the documented
# trade-off -- this script only changes the output device.

out_file <- file.path(args$run_dir, paste0("figure_final.", fmt))

# Vector devices reject a dpi argument, and TIFF needs an explicit compression
# to avoid writing a several-hundred-MB uncompressed file at 600 dpi. LZW is
# lossless and is what journals that ask for TIFF expect.
ggsave_args <- list(filename = out_file, plot = p, width = width, height = height,
                    units = "in", bg = "white", limitsize = FALSE)
if (!fmt %in% c("pdf", "svg", "eps")) ggsave_args$dpi <- dpi
if (fmt == "tiff") ggsave_args$compression <- "lzw"

do.call(ggsave, ggsave_args)

size_mb <- round(file.info(out_file)$size / (1024^2), 2)
log_line("[render_final] wrote %s (%.1f x %.1f in, %s, %s MB)",
         basename(out_file), width, height,
         if (fmt %in% c("pdf", "svg", "eps")) "vector" else sprintf("%d dpi", as.integer(dpi)),
         size_mb)
