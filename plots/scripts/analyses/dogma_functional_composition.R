# Functional composition (stacked relative-abundance bars, top N gene
# families + "Others") for DOGMA -- the functional-annotation analogue of
# taxonomic_composition.R (same shape/intent, different biology): instead
# of "% of reads assigned to each taxon" it's "% of reads assigned to each
# gene family" (KEGG ortholog, COG category, CAZy family, a cycling-gene
# family,...), per sample x domain. See plots/manifest.yaml for parameter
# descriptions and lib/build_dogma_table.R for the real per-ORF merge +
# DOGMA_ANNOTATION_COLUMNS this reads from.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "build_dogma_table.R"))

suppressMessages({
  library(dplyr)
  library(ggplot2)
  library(RColorBrewer)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(annotation_column = "eggnog_KEGG_ko", top_n = "20"))
annotation_col <- args$annotation_column
top_n_families <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "white"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[dogma_functional_composition] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
long_table <- loaded$long_table
log_line("[dogma_functional_composition] %d ORF rows, %d sample x domain unit(s)", nrow(long_table), length(unique(long_table$sample_domain)))

if (!(annotation_col %in% colnames(long_table))) {
  stop(sprintf("--annotation_column '%s' is not present in this run's data -- the matching annotation tool wasn't active. Available: %s",
               annotation_col, paste(intersect(DOGMA_ANNOTATION_COLUMNS, colnames(long_table)), collapse = ", ")))
}
if (!("salmon_NumReads" %in% colnames(long_table))) {
  stop("No Salmon quantification (salmon_NumReads) in this run's data -- composition needs real read counts to compute relative abundance from.")
}

# Unlike aggregate_dogma_counts (used by the differential-abundance
# analysis), un-annotated ORFs are kept here as an explicit "Unclassified"
# bucket rather than dropped -- same convention taxonomic_composition.R
# already uses for un-ranked taxa, appropriate for a descriptive "where did
# the reads go" plot (as opposed to DESeq2 testing, where a giant
# catch-all pseudo-gene isn't a meaningful unit).
# Expanded first, so a family is a real pathway/category/ortholog instead of
# the combination string an ORF happens to carry -- see
# .expand_annotation_terms and DOGMA_COLUMN_TERM_RULES in build_dogma_table.R
# for the rules and the literature behind counting a gene into each of its
# terms. A no-op for single-valued and taxonomic columns.
df <- .expand_annotation_terms(long_table, annotation_col) %>%
  mutate(family = ifelse(.is_unannotated(.data[[annotation_col]]), "Unclassified",.data[[annotation_col]])) %>%
  filter(!is.na(salmon_NumReads)) %>%
  group_by(sample_domain, family) %>%
  summarise(reads = sum(salmon_NumReads),.groups = "drop") %>%
  group_by(sample_domain) %>%
  mutate(pct = reads / sum(reads) * 100) %>%
  ungroup()
summary_tab <- df %>% group_by(family) %>% summarise(Mean = mean(pct),.groups = "drop") %>% arrange(desc(Mean))
top_families <- summary_tab %>% filter(family != "Unclassified") %>% slice_head(n = top_n_families) %>% pull(family)

df <- df %>% mutate(Family_Plot = ifelse(family %in% top_families, family, ifelse(family == "Unclassified", "Unclassified", "Others")))
df_agg <- df %>% group_by(sample_domain, Family_Plot) %>% summarise(pct = sum(pct),.groups = "drop")

order <- c(top_families, intersect(c("Others", "Unclassified"), unique(df_agg$Family_Plot)))
df_agg$Family_Plot <- factor(df_agg$Family_Plot, levels = order)

n_colors <- length(levels(df_agg$Family_Plot))
base_palette <- c(brewer.pal(12, "Paired"), brewer.pal(8, "Dark2"), brewer.pal(8, "Set2"))
colors_final <- grDevices::colorRampPalette(base_palette)(n_colors)
names(colors_final) <- levels(df_agg$Family_Plot)
if ("Others" %in% names(colors_final)) colors_final["Others"] <- "black"
if ("Unclassified" %in% names(colors_final)) colors_final["Unclassified"] <- "gray60"
colors_final <- apply_palette_overrides(colors_final, style)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(df_agg, aes(x = sample_domain, y = pct, fill = Family_Plot)) +
  geom_bar(stat = "identity", width = 0.9, color = "black", linewidth = 0.05) +
  scale_fill_manual(values = colors_final) +
  labs(x = NULL, y = "Relative Abundance (% of assigned reads)", fill = annotation_col) +
  scale_y_continuous(expand = c(0, 0), limits = c(0, 100.1)) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 9),
    legend.text = element_text(size = 9),
    legend.title = element_text(size = 12, face = "bold"),
    panel.grid.major.x = element_blank()
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Functional Composition: ", annotation_col)
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.08, font_family = font_family)
plot_width <- max(14, length(unique(df_agg$sample_domain)) * 0.25)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = 8, units = "in", dpi = 120, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = plot_width, height = 8),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "dogma_functional_composition", annotation_column = annotation_col, top_families = top_families,
       records = lapply(seq_len(nrow(df_agg)), function(i) list(
         sample = as.character(df_agg$sample_domain[i]), family = as.character(df_agg$Family_Plot[i]),
         abundance_pct = df_agg$pct[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(palette = as.list(colors_final), legend_position = "right", show_labels = FALSE,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(df_agg, file.path(args$out_dir, "dogma_functional_composition.rds"))

log_line("[dogma_functional_composition] wrote data.json, default_style.json, dogma_functional_composition.rds, preview.png")
