# Real core microbiome heatmap, direct translation of microbiome.R's
# section 10. See plots/manifest.yaml for parameter descriptions.
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
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(rank = "Family", prevalence = "0.90", min_abundance = "0.001"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
rank <- args$rank
prevalence <- as.numeric(args$prevalence)
min_abundance <- as.numeric(args$min_abundance)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[core_microbiome] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[core_microbiome] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

ps_rel <- transform_sample_counts(ps, function(x) x / sum(x))
core_taxa <- filter_taxa(ps_rel, function(x) sum(x > min_abundance) > (prevalence * nsamples(ps_rel)), TRUE)
log_line("[core_microbiome] %d taxa in the core (present > %.3g in > %.0f%% of samples)",
          ntaxa(core_taxa), min_abundance, prevalence * 100)

if (ntaxa(core_taxa) == 0) {
  stop("No taxa meet the core prevalence/abundance thresholds -- try lowering --prevalence or --min_abundance.")
}

ps_core_glom <- if (rank == "ASV") core_taxa else tax_glom(core_taxa, taxrank = rank, NArm = FALSE)

df_core <- psmelt(ps_core_glom)
df_core <- df_core %>% arrange(.data[[group_var]])
df_core$Sample <- factor(df_core$Sample, levels = unique(df_core$Sample))

if (rank == "ASV") {
  df_core$Taxon_Label <- paste0(df_core$OTU, " (", df_core$Genus, ")")
} else {
  df_core$Taxon_Label <- as.character(df_core[[rank]])
  df_core$Taxon_Label[is.na(df_core$Taxon_Label)] <- "Unclassified"
}

title <- paste0("Core Microbiome (", rank, " > ", prevalence * 100, "%)")

p <- ggplot(df_core, aes(x = Sample, y = Taxon_Label, fill = log10(Abundance * 100 + 0.01))) +
  geom_tile(color = "white", linewidth = 0.1) +
  scale_fill_distiller(palette = "Spectral", direction = -1, name = "Log10(%)") +
  facet_grid(~.data[[group_var]], scales = "free_x", space = "free_x") +
  labs(x = NULL, y = paste(rank, "(Core)")) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 8),
    axis.text.y = element_text(size = 10, face = "italic"),
    strip.background = element_rect(fill = "white", color = "black"),
    strip.text = element_text(size = 10, face = "bold"),
    panel.grid = element_blank()
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

table_out <- df_core %>%
  group_by(Taxon_Label, Phylum) %>%
  summarise(mean_abundance_pct = mean(Abundance * 100),.groups = "drop") %>%
  arrange(desc(mean_abundance_pct))

records <- lapply(seq_len(nrow(df_core)), function(i) {
  list(sample = as.character(df_core$Sample[i]), group = as.character(df_core[[group_var]][i]),
       taxon = df_core$Taxon_Label[i], abundance_pct = df_core$Abundance[i] * 100)
})

write_json(
  list(
    analysis_id = "core_microbiome",
    group_var = group_var,
    rank = rank,
    n_core_taxa = length(unique(df_core$Taxon_Label)),
    records = records
  ),
  file.path(args$out_dir, "data.json"),
  auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# No discrete named palette here (fill is a continuous log10-abundance
# Spectral gradient, not per-group/per-taxon colors) -- only bg/font are
# user-customizable for this analysis this pass.
effective_style <- list(palette = "Spectral", legend_position = "right", show_labels = FALSE,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(ps_core = ps_core_glom, table = table_out), file.path(args$out_dir, "core_microbiome.rds"))

final_plot <- with_title_bar(p, title, size = 8, title_height = 0.08, font_family = font_family)
height <- max(6, length(unique(df_core$Taxon_Label)) * 0.3)
# Each sample gets its own tile column -- width grows with the sample count
# so tiles (and their per-sample x-axis labels) stay legible past ~25 samples.
width <- max(12, nsamples(ps_core_glom) * 0.2)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 130, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

log_line("[core_microbiome] wrote data.json, default_style.json, core_microbiome.rds, preview.png")
