# Real cross-genome quality overview -- standard comparative-genomics QC:
# CheckM2 completeness vs. contamination (the two numbers every genome
# quality report leads with), point size by assembly contiguity (N50),
# optionally colored by a real grouping variable (any of SIGMA's own
# taxonomy/typing columns, or the user's own metadata -- see
# load_sigma_table.R's SIGMA_BUILTIN_GROUP_COLS). Complements
# sigma_genome_summary's single-genome detail view with an "are all my
# genomes actually good enough to trust" view across the whole run at once
# -- no --genome picker needed here, every genome is shown together.
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

args <- parse_cli_args()
group_var <- args$group_var  # optional -- NULL/"" is fine, every genome just gets one color then
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[sigma_genome_quality_overview] reading cached SIGMA table from %s", args$sigma_table_rds)
loaded <- readRDS(args$sigma_table_rds)
df <- loaded$genome_summary
log_line("[sigma_genome_quality_overview] %d genome(s)", nrow(df))

has_group <- !is.null(group_var) && group_var != "" && group_var %in% colnames(loaded$coldata)
if (!is.null(group_var) && group_var != "" && !has_group) {
  stop(sprintf("group_var '%s' is not a column in this run's metadata/taxonomy/typing table. Available: %s",
               group_var, paste(colnames(loaded$coldata), collapse = ", ")))
}
if (has_group) {
  df$Group <- as.character(loaded$coldata[df$sample, group_var])
  df$Group[is.na(df$Group)] <- "Unknown"
} else {
  df$Group <- "All genomes"
}

missing_stats <- df %>% filter(is.na(checkm2_completeness) | is.na(checkm2_contamination))
if (nrow(missing_stats) > 0) {
  log_line("[sigma_genome_quality_overview] %d genome(s) missing CheckM2 completeness/contamination, excluded from the plot: %s",
           nrow(missing_stats), paste(missing_stats$sample, collapse = ", "))
}
df <- df %>% filter(!is.na(checkm2_completeness), !is.na(checkm2_contamination))
if (nrow(df) == 0) {
  stop("No genome in this run has real CheckM2 completeness/contamination data -- was CheckM2 active?")
}

palette <- resolve_palette(df$Group, style)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

# MIMAG-style real quality thresholds (Bowers et al. 2017, Nat Biotechnol,
# "Minimum information about a single amplified genome (MISAG) and a
# metagenome-assembled genome (MIMAG)", the same real standard MAGMA's own
# genome-quality guidance already cites elsewhere in this app) -- high
# quality: >=90% complete, <=5% contamination. Drawn as a reference
# rectangle, not just described in prose, so it's immediately visible which
# genomes clear the real bar.
# GUNC as the point's SHAPE rather than a second figure. This is the whole
# reason GUNC is worth running next to CheckM2: a chimera of two organisms
# with complementary marker sets scores well on BOTH axes of this plot, so it
# lands inside the green high-quality rectangle looking perfect. Marking the
# failures here puts the contradiction where it is visible instead of in a
# separate card nobody cross-references.
has_gunc <- "gunc_pass" %in% colnames(df) && any(!is.na(df$gunc_pass))
if (has_gunc) {
  df$GUNC <- ifelse(is.na(df$gunc_pass), "not run", ifelse(df$gunc_pass, "passes GUNC", "FAILS GUNC (chimeric)"))
  df$GUNC <- factor(df$GUNC, levels = c("passes GUNC", "FAILS GUNC (chimeric)", "not run"))
  log_line("[sigma_genome_quality_overview] GUNC: %d fail, %d pass",
           sum(df$GUNC == "FAILS GUNC (chimeric)"), sum(df$GUNC == "passes GUNC"))
}

p <- ggplot(df, aes(x = checkm2_completeness, y = checkm2_contamination)) +
  annotate("rect", xmin = 90, xmax = Inf, ymin = -Inf, ymax = 5, fill = "#2CA02C", alpha = 0.08) +
  (if (has_gunc)
     geom_point(aes(color = Group, size = quast_n50, shape = GUNC), alpha = 0.85, fill = NA, stroke = 1.3)
   else
     geom_point(aes(color = Group, size = quast_n50), alpha = 0.85, shape = 21, fill = NA, stroke = 1.3)) +
  geom_text_repel(aes(label = sample), size = 3.2, family = font_family, color = "black",
                   max.overlaps = 30, box.padding = 0.4, show.legend = FALSE) +
  scale_color_manual(values = palette, name = if (has_group) group_var else NULL) +
  scale_size_continuous(name = "N50 (bp)", range = c(2, 9), labels = function(x) format(x, big.mark = ",", scientific = FALSE)) +
  # 21 = hollow circle (the original look), 4 = a cross, which reads as
  # "rejected" without needing the legend; 1 for a genome GUNC never saw.
  (if (has_gunc) scale_shape_manual(values = c("passes GUNC" = 21, "FAILS GUNC (chimeric)" = 4, "not run" = 1),
                                    name = "GUNC", drop = FALSE) else NULL) +
  labs(x = "Completeness (%)", y = "Contamination (%)") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "right")
if (!has_group) p <- p + guides(color = "none")
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

n_high_quality <- sum(df$checkm2_completeness >= 90 & df$checkm2_contamination <= 5)
n_gunc_fail <- if (has_gunc) sum(df$GUNC == "FAILS GUNC (chimeric)") else 0
# Kept short on purpose: the MIMAG thresholds are already drawn as the green
# rectangle, so spelling them out in the title only made it wrap to five lines
# and eat a quarter of the figure.
title <- paste0("Genome Quality Overview  |  ", n_high_quality, "/", nrow(df), " MIMAG high-quality",
                if (n_gunc_fail > 0) paste0("  |  ", n_gunc_fail, " fail GUNC") else "")
plot_width <- 11
# Real bug caught by actually rendering it: this title is
# genuinely long (dynamic MIMAG-count text appended), and with_title_bar
# only auto-wraps when plot_width_in is passed -- without it, the title
# silently overflowed/clipped past the figure's right edge instead of
# wrapping to a second line. Every other analysis in this app either has a
# short enough title to never hit this, or already passes plot_width_in
# (e.g. dogma_de_heatmap.R) -- this one just needed the same treatment.
final_plot <- with_title_bar(p, title, size = 9, title_height = 0.1, font_family = font_family, plot_width_in = plot_width)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = 9, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = plot_width, height = 9),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "sigma_genome_quality_overview", group_var = if (has_group) group_var else NULL,
       n_high_quality = n_high_quality, n_genomes = nrow(df),
       genomes = lapply(seq_len(nrow(df)), function(i) list(
         genome = df$sample[i], group = df$Group[i],
         completeness = df$checkm2_completeness[i], contamination = df$checkm2_contamination[i],
         n50 = df$quast_n50[i], total_length = df$quast_total_length[i],
         high_quality = df$checkm2_completeness[i] >= 90 && df$checkm2_contamination[i] <= 5
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(df$Group, legend_position = "right", show_labels = TRUE,
                                             background = bg, font_family = font_family,
                                             palette = if (has_group) palette else NULL)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(df, file.path(args$out_dir, "sigma_genome_quality_overview.rds"))

log_line("[sigma_genome_quality_overview] wrote data.json, default_style.json, sigma_genome_quality_overview.rds, preview.png")
