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

all_ranks <- rank_names(ps)
ranks_to_plot <- if (args$rank == "all") all_ranks[all_ranks %in% c("Phylum", "Class", "Order", "Family", "Genus")] else args$rank
if (length(ranks_to_plot) == 0) ranks_to_plot <- all_ranks

# One panel per requested rank -- same per-rank computation as
# gerar_graficos_abundancia_final in microbiome.R, just building a
# ggplot object per rank instead of ggsave-ing each one separately, so
# "all" can be combined into one scrollable preview image.
build_rank_panel <- function(rank) {
  glom <- tax_glom(ps, taxrank = rank, NArm = FALSE)
  ps_rel <- transform_sample_counts(glom, function(x) x / sum(x) * 100)
  df <- psmelt(ps_rel)
  df[[rank]] <- as.character(df[[rank]])
  df[[rank]][is.na(df[[rank]])] <- "Unclassified"

  summary_tab <- df %>% group_by(.data[[rank]]) %>% summarise(Mean = mean(Abundance),.groups = "drop") %>% arrange(desc(Mean))
  top_taxa <- summary_tab %>% slice_head(n = top_n_taxa) %>% pull(.data[[rank]])

  df_renamed <- df %>% mutate(Taxon_Plot = ifelse(.data[[rank]] %in% top_taxa,.data[[rank]], "Others"))
  df_agg <- df_renamed %>% group_by(Sample, Taxon_Plot) %>% summarise(Abundance = sum(Abundance),.groups = "drop")

  order <- if ("Others" %in% df_agg$Taxon_Plot) c(top_taxa, "Others") else top_taxa
  df_agg$Taxon_Plot <- factor(df_agg$Taxon_Plot, levels = order)

  n_colors <- length(levels(df_agg$Taxon_Plot))
  base_palette <- c(brewer.pal(12, "Paired"), brewer.pal(8, "Dark2"), brewer.pal(8, "Set2"))
  colors_final <- grDevices::colorRampPalette(base_palette)(n_colors)
  names(colors_final) <- levels(df_agg$Taxon_Plot)
  if ("Others" %in% names(colors_final)) colors_final["Others"] <- "black"
  colors_final <- apply_palette_overrides(colors_final, style)

  p <- ggplot(df_agg, aes(x = Sample, y = Abundance, fill = Taxon_Plot)) +
    geom_bar(stat = "identity", width = 0.9, color = "black", linewidth = 0.05) +
    scale_fill_manual(values = colors_final) +
    labs(x = NULL, y = "Relative Abundance (%)", fill = rank) +
    scale_y_continuous(expand = c(0, 0), limits = c(0, 100.1)) +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
    theme(
      axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 9),
      legend.text = element_text(size = 10, face = "italic"),
      legend.title = element_text(size = 12, face = "bold"),
      panel.grid.major.x = element_blank()
    )
  p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

  list(
    plot = with_title_bar(p, paste("Relative Abundance:", rank), size = 7, title_height = 0.08, font_family = font_family),
    rank = rank,
    top_taxa = top_taxa,
    table = df_agg,
    palette = colors_final
  )
}

panels <- lapply(ranks_to_plot, build_rank_panel)
names(panels) <- ranks_to_plot

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

ranks_json <- lapply(panels, function(pn) {
  records <- lapply(seq_len(nrow(pn$table)), function(i) {
    list(sample = as.character(pn$table$Sample[i]), taxon = as.character(pn$table$Taxon_Plot[i]), abundance_pct = pn$table$Abundance[i])
  })
  list(rank = pn$rank, top_taxa = pn$top_taxa, records = records)
})

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

# wrap_elements around each panel is required, not cosmetic: each panel
# is itself already a patchwork object (title_bar/plot stacked via
# with_title_bar's own `/` + plot_layout(heights=...)). Combining several
# such nested patchwork objects with a bare `/` makes patchwork flatten
# them into one shared patch list, discarding each panel's own heights
# ratio and crashing wrap_dims with a "need N panels" error the moment
# there's more than one rank panel (confirmed: reproduces even on
# a tiny 2-sample/3-panel case, so this was a latent default-path bug, not
# a many-samples scaling issue -- rank="all" is the manifest default).
# wrap_elements protects each panel as one opaque unit instead.
final_plot <- Reduce(`/`, lapply(panels, function(pn) patchwork::wrap_elements(pn$plot)))
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
