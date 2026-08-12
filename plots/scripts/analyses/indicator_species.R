# Real indicator species analysis (indicspecies::multipatt, lollipop chart),
# direct translation of microbiome.R's section 14. See plots/manifest.yaml
# for parameter descriptions.
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
  library(tibble)
  library(indicspecies)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(rank = "Genus", p_cutoff = "0.05", seed = "123"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
rank <- args$rank
p_cutoff <- as.numeric(args$p_cutoff)
seed <- as.integer(args$seed)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[indicator_species] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[indicator_species] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

ps_indval <- tax_glom(ps, taxrank = rank, NArm = FALSE)
abund_matrix <- t(as(otu_table(ps_indval), "matrix"))
groups_indval <- as.character(data.frame(sample_data(ps_indval))[[group_var]])

log_line("[indicator_species] running multipatt (IndVal.g) for %d taxa x %d samples across %d group(s)...",
          ntaxa(ps_indval), nsamples(ps_indval), length(unique(groups_indval)))
set.seed(seed)
inv_model <- multipatt(abund_matrix, groups_indval, func = "IndVal.g", duleg = TRUE, control = how(nperm = 999))

df_inv <- inv_model$sign %>%
  rownames_to_column("ASV_ID") %>%
  filter(p.value <= p_cutoff) %>%
  arrange(desc(stat))

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

if (nrow(df_inv) == 0) {
  log_line("[indicator_species] no significant indicators at p <= %g -- writing an empty result, no plot", p_cutoff)
  write_json(list(analysis_id = "indicator_species", group_var = group_var, rank = rank, n_indicators = 0, indicators = list()),
             file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE)
  quit(save = "no", status = 0)
}

tax_info <- as.data.frame(tax_table(ps_indval))
df_inv$TaxonName <- tax_info[df_inv$ASV_ID, rank]
group_names <- colnames(inv_model$comb)
df_inv$Indicated_Group <- group_names[df_inv$index]
log_line("[indicator_species] %d significant indicator(s) found", nrow(df_inv))

table_out <- df_inv %>%
  select(TaxonName, ASV_ID, Indicated_Group, Indicator_Value = stat, p_value = p.value)

palette <- resolve_palette(df_inv$Indicated_Group, style)
df_plot <- head(df_inv, 30)
df_plot$TaxonName <- factor(df_plot$TaxonName, levels = rev(unique(df_plot$TaxonName)))

p <- ggplot(df_plot, aes(x = stat, y = TaxonName, color = Indicated_Group)) +
  geom_segment(aes(x = 0, xend = stat, y = TaxonName, yend = TaxonName), color = "gray60", linewidth = 1) +
  geom_point(size = 5) +
  scale_color_manual(values = palette, name = "Bioindicator of:") +
  labs(x = "Indicator Value (IndVal Stat)", y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(
    axis.text.y = element_text(size = 11, face = "italic"),
    panel.border = element_rect(color = "black", fill = NA, linewidth = 0.5),
    panel.grid.major.y = element_blank()
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Indicator Species Analysis (IndVal): ", rank, "\nTop Significant Bioindicators (p < ", p_cutoff, ")")
final_plot <- with_title_bar(p, title, size = 6, title_height = 0.12, font_family = font_family)
height <- max(6, nrow(df_plot) * 0.25)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = 12, height = height),
        file.path(args$out_dir, "plot_final.rds"))

indicators <- lapply(seq_len(nrow(table_out)), function(i) as.list(table_out[i, ]))
write_json(
  list(analysis_id = "indicator_species", group_var = group_var, rank = rank, n_indicators = nrow(table_out), indicators = indicators),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(df_inv$Indicated_Group, legend_position = "right", show_labels = FALSE,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(model = inv_model, table = table_out), file.path(args$out_dir, "indicator_species.rds"))

log_line("[indicator_species] wrote data.json, default_style.json, indicator_species.rds, preview.png")
