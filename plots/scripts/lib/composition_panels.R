# Shared stacked-relative-abundance panel builder, factored out of
# taxonomic_composition.R so more than one analysis can produce the same
# figure from the same phyloseq shape without a second copy of the logic
# (MAGMA's magma_community_taxonomy runs it against either of that run's two
# independently-built community tables -- Kraken2/Bracken or Kaiju).
#
# Everything the original inlined from its enclosing script (the phyloseq
# object, top-N, and the style knobs) is an explicit argument here, so the
# function has no hidden dependency on caller-scope variables.

suppressMessages({
  library(phyloseq)
  library(dplyr)
  library(ggplot2)
  library(RColorBrewer)
})

#' Which ranks to plot for a request. "all" means every rank this data
#' actually has among the standard Phylum..Genus set (falling back to
#' whatever ranks exist, for a reference database with unusual naming).
resolve_ranks_to_plot <- function(ps, rank_arg) {
  all_ranks <- rank_names(ps)
  out <- if (rank_arg == "all") {
    all_ranks[all_ranks %in% c("Phylum", "Class", "Order", "Family", "Genus")]
  } else {
    rank_arg
  }
  if (length(out) == 0) all_ranks else out
}

#' One stacked-bar panel for a single taxonomic rank: top-N taxa by mean
#' relative abundance, everything else summed into "Others".
#'
#' Returns the same list shape the original built -- plot, rank, top_taxa,
#' table, palette -- so callers can keep assembling data.json and the
#' editable palette exactly as before.
build_taxonomic_panel <- function(ps, rank, top_n_taxa, style, bg, font_family, font_scale,
                                  hide_x_axis = FALSE, hide_y_axis = FALSE) {
  glom <- tax_glom(ps, taxrank = rank, NArm = FALSE)
  ps_rel <- transform_sample_counts(glom, function(x) x / sum(x) * 100)
  df <- psmelt(ps_rel)
  df[[rank]] <- as.character(df[[rank]])
  df[[rank]][is.na(df[[rank]])] <- "Unclassified"

  summary_tab <- df %>% group_by(.data[[rank]]) %>% summarise(Mean = mean(Abundance), .groups = "drop") %>%
    arrange(desc(Mean))
  top_taxa <- summary_tab %>% slice_head(n = top_n_taxa) %>% pull(.data[[rank]])

  df_renamed <- df %>% mutate(Taxon_Plot = ifelse(.data[[rank]] %in% top_taxa, .data[[rank]], "Others"))
  df_agg <- df_renamed %>% group_by(Sample, Taxon_Plot) %>%
    summarise(Abundance = sum(Abundance), .groups = "drop")

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
    plot = with_title_bar(p, paste("Relative Abundance:", rank), size = 7, title_height = 0.08,
                          font_family = font_family),
    rank = rank,
    top_taxa = top_taxa,
    table = df_agg,
    palette = colors_final
  )
}

#' data.json's `ranks` array for a set of built panels.
taxonomic_panels_json <- function(panels) {
  lapply(panels, function(pn) {
    records <- lapply(seq_len(nrow(pn$table)), function(i) {
      list(sample = as.character(pn$table$Sample[i]),
           taxon = as.character(pn$table$Taxon_Plot[i]),
           abundance_pct = pn$table$Abundance[i])
    })
    list(rank = pn$rank, top_taxa = pn$top_taxa, records = records)
  })
}

#' Stacks panels into one figure. wrap_elements around each panel is
#' required, not cosmetic: each panel is itself already a patchwork object
#' (title_bar/plot stacked via with_title_bar's own `/` + plot_layout).
#' Combining several such nested patchwork objects with a bare `/` makes
#' patchwork flatten them into one shared patch list, discarding each
#' panel's own heights ratio and crashing wrap_dims with a "need N panels"
#' error as soon as there is more than one panel.
combine_taxonomic_panels <- function(panels) {
  Reduce(`/`, lapply(panels, function(pn) patchwork::wrap_elements(pn$plot)))
}
