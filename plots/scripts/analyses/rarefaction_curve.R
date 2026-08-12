# Real rarefaction curve analysis (observed richness vs. sequencing depth
# per sample), direct translation of microbiome.R's section 6 -- using
# vegan::rarecurve's modern `tidy = TRUE` output instead of the original
# script's manual attr-based extraction (same computation, simpler and
# confirmed to run cleanly headless, no interactive plot side effect).
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

suppressMessages({
  library(phyloseq)
  library(vegan)
  library(dplyr)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(step = "100"))
step <- as.integer(args$step)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "white"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)
accent_color <- style$accent_color %||% "black"

log_line("[rarefaction_curve] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[rarefaction_curve] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

ps_clean <- prune_samples(sample_sums(ps) > 0, ps)
otu_mat <- as(otu_table(ps_clean), "matrix")
if (taxa_are_rows(ps_clean)) otu_mat <- t(otu_mat)
storage.mode(otu_mat) <- "double"

min_depth <- min(rowSums(otu_mat))
log_line("[rarefaction_curve] computing rarefaction curves (step=%d, min depth=%d)...", step, min_depth)
rare_df <- rarecurve(otu_mat, step = step, sample = min_depth, label = FALSE, tidy = TRUE) %>%
  rename(SampleID = Site, Reads = Sample, Richness = Species)

labels_df <- rare_df %>% group_by(SampleID) %>% summarise(Max_Reads = max(Reads), Max_Richness = max(Richness),.groups = "drop")

# Every curve ends up labeled at its endpoint -- fine for a handful of
# samples, but curves converge near a similar depth once there are dozens of
# them, so the labels stack into an illegible smear. Past this threshold,
# drop the per-curve labels and rely on the vertical min-depth line + curve
# density alone (confirmed cramped at 80 samples).
n_samples <- length(unique(rare_df$SampleID))
show_curve_labels <- n_samples <= 40

p <- ggplot(rare_df, aes(x = Reads, y = Richness, group = SampleID)) +
  geom_line(color = accent_color, linewidth = 0.6, alpha = 0.7) +
  geom_vline(xintercept = min_depth, linetype = "dashed", color = "darkred", linewidth = 0.5) +
  scale_x_continuous(expand = expansion(mult = c(0.02, 0.2))) +
  labs(x = "Sequencing Depth (Reads)", y = "Observed Richness (ASVs)") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(legend.position = "none", axis.title = element_text(size = 11, face = "bold"))

if (show_curve_labels) {
  p <- p + geom_text(data = labels_df, aes(x = Max_Reads, y = Max_Richness, label = SampleID),
                      color = "black", hjust = -0.1, size = 3, family = font_family, check_overlap = FALSE, inherit.aes = FALSE)
}
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

final_plot <- with_title_bar(p, "Rarefaction Curve", size = 7, title_height = 0.08, font_family = font_family)
# Denser curve bundles (many samples) benefit from a bit more width too.
plot_width <- max(14, n_samples * 0.1)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = 8, units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = plot_width, height = 8),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "rarefaction_curve", step = step, min_depth = min_depth,
       curves = lapply(seq_len(nrow(rare_df)), function(i) as.list(rare_df[i, ]))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(accent_color = accent_color, legend_position = "none", show_labels = show_curve_labels,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(rare_df = rare_df, labels = labels_df), file.path(args$out_dir, "rarefaction_curve.rds"))

log_line("[rarefaction_curve] wrote data.json, default_style.json, rarefaction_curve.rds, preview.png")
