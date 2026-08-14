# Renders the layouts with_title_bar has to survive, so scripts/check_title_bar.py
# can assert that none of them clips its title.
#
# with_title_bar is shared by 43 analyses across all five pipelines, but only
# MAGMA has a demo run to exercise it against. These cases stand in for the rest:
# each is a shape of chrome that changes how much width the title bar actually
# gets, which is the whole difficulty -- patchwork aligns the bar to the plot's
# panel, so a legend, long y-axis labels or a facet strip column all shrink it
# before the bar sees it.
#
#   Rscript plots/scripts/tests/render_title_bar_cases.R OUT_DIR
suppressMessages({
  library(ggplot2)
  library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(args)) args[1] else stop("usage: render_title_bar_cases.R OUT_DIR")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

script_dir <- dirname(normalizePath(sub("^--file=", "",
  grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))))
source(file.path(script_dir, "..", "lib", "plot_theme.R"))

set.seed(1)
n <- 60
d <- data.frame(
  x = rnorm(n), y = rnorm(n),
  g = rep(c("control", "treated", "recovered"), length.out = n),
  facet = rep(c("phase one", "phase two"), length.out = n),
  # Long labels on purpose: this is the case the old fudge factor was tuned on
  # (a heatmap whose gene names eat the left margin).
  long = rep(c("Pseudomonas_fluorescens_group_bin_014",
               "Candidatus_Nitrososphaera_gargensis_bin_002",
               "Streptomyces_coelicolor_A3_2_bin_031"), length.out = n)
)

SHORT <- "MAG Quality"
LONG <- paste("Beta Diversity (JACCARD) | PERMANOVA: p = 0.0010, R2 = 0.184,",
              "999 permutations, 18 samples")

base <- function(...) ggplot(d, ...) + base_theme()

cases <- list(
  bare = list(
    plot = base(aes(x, y)) + geom_point(),
    title = LONG, width = 12, height = 8),
  legend_right = list(
    plot = base(aes(x, y, colour = g)) + geom_point() + theme(legend.position = "right"),
    title = LONG, width = 12, height = 8),
  # The tightest case: a legend on one side and long categorical labels on the
  # other, leaving the bar a fraction of the figure.
  long_y_labels = list(
    plot = base(aes(x, long, colour = g)) + geom_point() + theme(legend.position = "right"),
    title = LONG, width = 9, height = 7),
  facet_strip = list(
    plot = base(aes(x, y, colour = g)) + geom_point() +
      facet_grid(rows = vars(facet), switch = "y") +
      theme(legend.position = "right", strip.placement = "outside"),
    title = LONG, width = 10, height = 8),
  # A narrow figure has the least room of all, and is where a title that is not
  # wrapped at all shows up worst.
  narrow = list(
    plot = base(aes(x, y, colour = g)) + geom_point() + theme(legend.position = "right"),
    title = LONG, width = 6, height = 5),
  short_title = list(
    plot = base(aes(x, y, colour = g)) + geom_point() + theme(legend.position = "right"),
    title = SHORT, width = 12, height = 8),
  sans_font = list(
    plot = base(aes(x, y, colour = g)) + geom_point() + theme(legend.position = "right"),
    title = LONG, width = 9, height = 7, font_family = "sans"),
  # Not a plain ggplot: measure_panel_width_in cannot read a panel off this, so
  # it exercises the fallback rather than erroring.
  patchwork_input = list(
    plot = (base(aes(x, y)) + geom_point()) | (base(aes(x, y)) + geom_point()),
    title = LONG, width = 12, height = 6)
)

for (name in names(cases)) {
  case <- cases[[name]]
  family <- if (is.null(case$font_family)) "serif" else case$font_family
  final <- with_title_bar(case$plot, case$title, size = 10, font_family = family,
                          plot_width_in = case$width, plot_height_in = case$height)
  path <- file.path(out_dir, paste0(name, ".png"))
  ggsave(path, plot = final, width = case$width, height = case$height,
         units = "in", dpi = 150, bg = "white", limitsize = FALSE)
  cat(sprintf("rendered %-16s %sx%sin -> %s\n", name, case$width, case$height, path))
}
