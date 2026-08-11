# Functional composition per sample: share of predicted genes assigned to
# each COG (Cluster of Orthologous Groups) functional category, from
# eggNOG-mapper's own annotation of MAGMA's assembled metagenome. Same
# stacked-bar shape as taxonomic_composition.R and DOGMA's own
# dogma_functional_composition.R, but the metric is genuinely different --
# gene COUNT share, not read-abundance share (MAGMA's per-sample eggNOG has
# no Salmon quantification behind it the way DOGMA's does -- see
# build_magma_functional_table.R).

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))

suppressMessages({
  library(dplyr)
  library(ggplot2)
  library(RColorBrewer)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(top_n = "15"))
top_n_categories <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[magma_functional_composition] reading cached functional table from %s", args$magma_functional_table_rds)
loaded <- readRDS(args$magma_functional_table_rds)
df <- loaded$functional_table
log_line("[magma_functional_composition] %d row(s) across %d sample(s)", nrow(df), length(unique(df$sample)))

summary_tab <- df %>% group_by(cog_category) %>% summarise(Mean = mean(pct), .groups = "drop") %>% arrange(desc(Mean))
top_categories <- summary_tab %>% filter(cog_category != "Unclassified") %>%
  slice_head(n = top_n_categories) %>% pull(cog_category)

df <- df %>% mutate(Category_Plot = ifelse(cog_category %in% top_categories, cog_category,
                                           ifelse(cog_category == "Unclassified", "Unclassified", "Others")))
df_agg <- df %>% group_by(sample, Category_Plot) %>% summarise(pct = sum(pct), .groups = "drop")

order <- c(top_categories, intersect(c("Others", "Unclassified"), unique(df_agg$Category_Plot)))
df_agg$Category_Plot <- factor(df_agg$Category_Plot, levels = order)

n_colors <- length(levels(df_agg$Category_Plot))
base_palette <- c(brewer.pal(12, "Paired"), brewer.pal(8, "Dark2"), brewer.pal(8, "Set2"))
colors_final <- grDevices::colorRampPalette(base_palette)(n_colors)
names(colors_final) <- levels(df_agg$Category_Plot)
if ("Others" %in% names(colors_final)) colors_final["Others"] <- "black"
if ("Unclassified" %in% names(colors_final)) colors_final["Unclassified"] <- "gray60"
colors_final <- apply_palette_overrides(colors_final, style)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(df_agg, aes(x = sample, y = pct, fill = Category_Plot)) +
  geom_bar(stat = "identity", width = 0.9, color = "black", linewidth = 0.05) +
  scale_fill_manual(values = colors_final) +
  labs(x = NULL, y = "Share of predicted genes (%)", fill = "COG category") +
  scale_y_continuous(expand = c(0, 0), limits = c(0, 100.1)) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 9),
    legend.text = element_text(size = 9),
    legend.title = element_text(size = 12, face = "bold"),
    panel.grid.major.x = element_blank()
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

final_plot <- with_title_bar(p, "Functional Composition (COG categories, eggNOG)", size = 8, title_height = 0.08,
                             font_family = font_family)
plot_width <- max(11, length(unique(df_agg$sample)) * 0.4)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = plot_width, height = 8, units = "in", dpi = 120, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = plot_width, height = 8),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "magma_functional_composition", top_categories = top_categories,
       records = lapply(seq_len(nrow(df_agg)), function(i) list(
         sample = as.character(df_agg$sample[i]), category = as.character(df_agg$Category_Plot[i]),
         gene_pct = df_agg$pct[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(palette = as.list(colors_final), legend_position = "right", show_labels = FALSE,
                        background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))
saveRDS(df_agg, file.path(args$out_dir, "magma_functional_composition.rds"))

log_line("[magma_functional_composition] wrote data.json, default_style.json, magma_functional_composition.rds, preview.png, plot_final.rds")
