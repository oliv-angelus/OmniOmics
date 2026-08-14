# Completeness vs. contamination across every MAG the run recovered -- the
# figure a metagenome-assembled-genome paper leads with, and the one MAGMA
# could not draw despite computing every number in it.
#
# Axes, thresholds and tier names are the MIMAG standard (Bowers et al. 2017,
# Nat Biotechnol, doi:10.1038/nbt.3893), which defines a high-quality draft as
# >90% complete and <5% contaminated *with* 23S/16S/5S rRNA and >=18 tRNA types
# present, and a medium-quality draft as >=50% complete and <10% contaminated.
# The tier is not recomputed here: build_magma_mag_table.R already assigns
# `mimag_quality` from exactly those rules, and two implementations of one
# standard is how they end up disagreeing.
#
# GUNC is shown as a separate mark rather than folded into the tier, following
# the same reasoning build_magma_mag_table.R records: chimerism is GUNC's own
# complementary check (Orakov et al. 2021, doi:10.1186/s13059-021-02393-0), not
# part of MIMAG. A MAG can be MIMAG-high and still be chimeric, and that is
# precisely the case a reader needs to see rather than have averaged away.
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
  library(ggrepel)
  library(jsonlite)
})

# The same constants build_magma_mag_table.R applies, repeated here only to
# draw the guide lines -- never to re-derive a tier.
MIMAG_HIGH_COMPLETENESS <- 90
MIMAG_HIGH_CONTAMINATION <- 5
MIMAG_MED_COMPLETENESS <- 50
MIMAG_MED_CONTAMINATION <- 10

# Colour-blind safe, and ordered so quality reads as a ramp rather than as
# unrelated categories. "High (C/C only)" is the honest middle case the table
# already distinguishes: completeness and contamination qualify, but the
# rRNA/tRNA evidence MIMAG also requires was not available for that MAG.
TIER_LEVELS <- c("High", "High (C/C only)", "Medium", "Low")
TIER_COLOURS <- c(
  "High"            = "#0F766E",
  "High (C/C only)" = "#0891B2",
  "Medium"          = "#CA8A04",
  "Low"             = "#B91C1C"
)

args <- parse_cli_args(defaults = list(
  show_labels = "auto",
  only_dereplicated = "false",
  label_threshold = "30"
))
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[magma_mag_quality_overview] reading cached MAG table from %s", args$magma_mag_table_rds)
loaded <- readRDS(args$magma_mag_table_rds)
df <- loaded$mag_table

if (is.null(df) || nrow(df) == 0) {
  stop("This run has no MAGs. Binning, refinement (binette) and CheckM2 all have to have run.")
}

only_derep <- tolower(args$only_dereplicated) %in% c("true", "yes", "1")
if (only_derep) {
  if (!"dereplicated" %in% colnames(df)) {
    stop("This run has no dereplication information -- dRep did not run, so 'only dereplicated' cannot be applied.")
  }
  df <- df[!is.na(df$dereplicated) & df$dereplicated, , drop = FALSE]
  if (nrow(df) == 0) stop("No MAG survived dereplication in this run.")
}

# A MAG CheckM2 could not score has no position on either axis; dropping it
# silently would misreport the recovery count, so it is reported instead.
scored <- !is.na(df$checkm2_completeness) & !is.na(df$checkm2_contamination)
if (any(!scored)) {
  log_line("[magma_mag_quality_overview] %d MAG(s) without CheckM2 scores are not plotted", sum(!scored))
}
df <- df[scored, , drop = FALSE]
if (nrow(df) == 0) stop("No MAG in this run has CheckM2 completeness/contamination scores.")

df$tier <- factor(ifelse(is.na(df$mimag_quality), "Low", df$mimag_quality), levels = TIER_LEVELS)
has_gunc <- "gunc_pass" %in% colnames(df) && any(!is.na(df$gunc_pass))
df$chimeric <- if (has_gunc) !is.na(df$gunc_pass) & !df$gunc_pass else FALSE

log_line("[magma_mag_quality_overview] %d MAG(s): %s", nrow(df),
         paste(sprintf("%s=%d", levels(df$tier), tabulate(df$tier, nbins = length(TIER_LEVELS))),
               collapse = ", "))

# Labelling every MAG is unreadable past a couple of dozen; labelling none
# makes the outliers unusable. "auto" labels only when the set is small enough
# for the labels to be placed without overlap.
label_threshold <- suppressWarnings(as.numeric(args$label_threshold))
if (is.na(label_threshold)) label_threshold <- 30
show_labels <- switch(tolower(args$show_labels),
                      "always" = TRUE,
                      "never"  = FALSE,
                      nrow(df) <= label_threshold)

size_var <- if ("checkm2_genome_size" %in% colnames(df) && any(!is.na(df$checkm2_genome_size))) {
  "checkm2_genome_size"
} else {
  NULL
}

p <- ggplot(df, aes(x = checkm2_completeness, y = checkm2_contamination))

# The MIMAG thresholds as guides, drawn under the points so they never obscure
# a MAG sitting exactly on one.
p <- p +
  annotate("rect", xmin = MIMAG_HIGH_COMPLETENESS, xmax = Inf,
           ymin = -Inf, ymax = MIMAG_HIGH_CONTAMINATION,
           fill = TIER_COLOURS[["High"]], alpha = 0.07) +
  geom_vline(xintercept = c(MIMAG_MED_COMPLETENESS, MIMAG_HIGH_COMPLETENESS),
             linetype = "dashed", linewidth = 0.4, colour = "grey45") +
  geom_hline(yintercept = c(MIMAG_HIGH_CONTAMINATION, MIMAG_MED_CONTAMINATION),
             linetype = "dashed", linewidth = 0.4, colour = "grey45")

if (is.null(size_var)) {
  p <- p + geom_point(aes(colour = tier), size = 3, alpha = 0.85)
} else {
  p <- p + geom_point(aes(colour = tier, size = .data[[size_var]] / 1e6), alpha = 0.85) +
    scale_size_continuous(name = "Size (Mb)", range = c(2, 7))
}

# Chimeric MAGs get a ring rather than a colour of their own -- the colour axis
# already carries MIMAG tier, and a second categorical hue on the same mark
# would make neither readable.
if (any(df$chimeric)) {
  p <- p + geom_point(data = df[df$chimeric, , drop = FALSE],
                      shape = 21, size = 5.5, stroke = 0.9,
                      colour = "grey15", fill = NA)
}

if (show_labels) {
  # box.padding/point.padding are not cosmetic here: high-quality MAGs cluster
  # tightly in the bottom-right corner by construction, and without them the
  # labels rendered on top of the points they name.
  p <- p + geom_text_repel(aes(label = mag), size = 2.6 * font_scale,
                           max.overlaps = Inf, min.segment.length = 0,
                           box.padding = 0.7, point.padding = 0.4,
                           segment.size = 0.3, segment.colour = "grey55",
                           family = font_family, colour = "grey25", seed = 1)
}

p <- p +
  scale_colour_manual(name = "MIMAG quality", values = TIER_COLOURS, drop = FALSE) +
  scale_x_continuous(limits = c(0, 102), breaks = seq(0, 100, 20), expand = expansion(mult = c(0.02, 0.02))) +
  labs(x = "Completeness (CheckM2, %)", y = "Contamination (CheckM2, %)",
       # Rendering this against the test fixture made a real misreading
       # obvious: two MAGs sit inside the shaded band and are still coloured
       # Medium. That is correct -- MIMAG's high tier also requires 23S/16S/5S
       # rRNA and >=18 tRNA types -- but without saying so the figure looks
       # wrong. The band is the completeness/contamination criterion only; the
       # colour is the full verdict, and the gap between them is the point.
       caption = paste0("Shaded band: MIMAG completeness/contamination criterion only. ",
                        "The High tier additionally requires 23S/16S/5S rRNA and >=18 tRNA types, ",
                        "so a MAG can sit in the band and still be Medium.",
                        if (any(df$chimeric))
                          paste0("\nRinged: fails GUNC chimerism (", sum(df$chimeric),
                                 "), a separate check MIMAG does not cover.")
                        else "")) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "right",
        plot.caption = element_text(hjust = 0, size = 7.5 * font_scale, colour = "grey35"))
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

n_high <- sum(df$tier %in% c("High", "High (C/C only)"))
# Deliberately short: appending the GUNC count too makes the title long enough
# to wrap mid-phrase at this figure width. The ringed points and their legend
# entry already say how many fail GUNC, and data.json carries the number for
# anyone quoting it.
title <- paste0("MAG Quality  |  ", n_high, "/", nrow(df), " MIMAG high-quality",
                if (only_derep) "  |  dereplicated" else "")
plot_width <- 11
# plot_width_in passed for the same reason sigma_genome_quality_overview.R
# does: this title grows with the counts, and with_title_bar only wraps when
# it knows the width.
final_plot <- with_title_bar(p, title, size = 9, title_height = 0.1,
                             font_family = font_family, plot_width_in = plot_width)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = 9, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = plot_width, height = 9),
        file.path(args$out_dir, "plot_final.rds"))

# The same numbers the figure shows, so a reader can quote a count without
# measuring it off the plot.
counts <- as.data.frame(table(df$tier), stringsAsFactors = FALSE)
colnames(counts) <- c("tier", "n")
write_json(list(
  analysis_id = "magma_mag_quality_overview",
  n_mags = nrow(df),
  n_high_quality = n_high,
  only_dereplicated = only_derep,
  tiers = counts,
  chimeric = sum(df$chimeric),
  standard = "MIMAG (Bowers et al. 2017, doi:10.1038/nbt.3893)",
  mags = lapply(seq_len(nrow(df)), function(i) list(
    mag = df$mag[i],
    completeness = df$checkm2_completeness[i],
    contamination = df$checkm2_contamination[i],
    tier = as.character(df$tier[i]),
    chimeric = df$chimeric[i]
  ))
), file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null")

log_line("[magma_mag_quality_overview] done")
