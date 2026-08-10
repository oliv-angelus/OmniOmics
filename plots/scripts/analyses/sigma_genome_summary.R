# Real per-genome detail view -- the analysis directly answering the user's
# own request: SIGMA can assemble many genomes in one run, so before doing
# anything else, the Plots tab needs a way to pick ONE of them to work
# with. --genome is PlotParam's new "sample" type (a real dropdown of this
# run's actual genome names, see plot_param_form.dart/PlotLoadedData.samples)
# -- not a "column"/"level" pair, since genome identity isn't a metadata
# column the user chose, it's a fixed fact about the run itself.
# Shows that one genome's real assembly/quality/taxonomy/typing stats plus
# its own AMR/virulence gene hits -- the per-genome "report card" a
# cross-genome comparison (sigma_genome_quality_overview/sigma_amr_heatmap)
# can't give on its own.
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
  library(patchwork)
  library(jsonlite)
})

args <- parse_cli_args()
if (is.null(args$genome) || args$genome == "") stop("--genome is required")
genome <- args$genome
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0

log_line("[sigma_genome_summary] reading cached SIGMA table from %s", args$sigma_table_rds)
loaded <- readRDS(args$sigma_table_rds)
if (!(genome %in% loaded$genome_summary$sample)) {
  stop(sprintf("--genome '%s' is not one of this run's genomes. Available: %s",
               genome, paste(loaded$genome_summary$sample, collapse = ", ")))
}
row <- loaded$genome_summary %>% filter(sample == genome)
hits <- loaded$gene_hits %>% filter(sample == genome)
log_line("[sigma_genome_summary] genome '%s': %d AMR/virulence gene hit(s)", genome, nrow(hits))

# Real, curated stat groups for the info-card panel -- not every raw column
# (e.g. gtdbtk_domain_file's own provenance value isn't interesting to a
# user, just to the merge logic), grouped the way a real genome report
# would present them.
stat_groups <- list(
  "Assembly" = c("Contigs" = "quast_num_contigs", "Total length (bp)" = "quast_total_length",
                 "Largest contig (bp)" = "quast_largest_contig", "N50" = "quast_n50",
                 "L50" = "quast_l50", "GC (%)" = "quast_gc_pct"),
  "Quality" = c("Completeness (%)" = "checkm2_completeness", "Contamination (%)" = "checkm2_contamination",
                "Coding sequences" = "checkm2_coding_sequences"),
  "Taxonomy" = c("Domain" = "gtdbtk_domain", "Phylum" = "gtdbtk_phylum", "Class" = "gtdbtk_class",
                 "Order" = "gtdbtk_order", "Family" = "gtdbtk_family", "Genus" = "gtdbtk_genus", "Species" = "gtdbtk_species"),
  "Coverage" = c("Mean" = "coverm_mean", "Trimmed mean" = "coverm_trimmed_mean", "Covered fraction" = "coverm_covered_fraction"),
  "Typing" = c("MLST scheme" = "mlst_scheme", "Sequence type (ST)" = "mlst_st")
)

fmt_value <- function(v) {
  if (is.null(v) || length(v) == 0 || is.na(v)) return("—")  # em dash for missing
  if (is.numeric(v)) return(format(round(v, 3), big.mark = ",", scientific = FALSE))
  as.character(v)
}

stats_json <- lapply(names(stat_groups), function(group) {
  entries <- lapply(names(stat_groups[[group]]), function(label) {
    col <- stat_groups[[group]][[label]]
    val <- if (col %in% colnames(row)) row[[col]][1] else NA
    list(label = label, value = fmt_value(val))
  })
  list(group = group, entries = entries)
})

hits_json <- lapply(seq_len(nrow(hits)), function(i) list(
  source = hits$source[i], gene = hits$gene[i], product = hits$product[i],
  class = hits$class[i], pct_identity = hits$pct_identity[i], pct_coverage = hits$pct_coverage[i]
))

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "sigma_genome_summary", genome = genome, stats = stats_json,
       n_gene_hits = nrow(hits), gene_hits = hits_json),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# Info-card panel: a plain text grid (group headers + label/value rows) --
# no numeric axes to plot, this is a report, not a chart; ggplot text
# geoms are used purely as a layout engine for consistent theming/export.
card_rows <- do.call(rbind, lapply(names(stat_groups), function(group) {
  labels <- names(stat_groups[[group]])
  values <- vapply(stat_groups[[group]], function(col) fmt_value(if (col %in% colnames(row)) row[[col]][1] else NA), character(1))
  data.frame(group = group, label = labels, value = values, stringsAsFactors = FALSE)
}))
card_rows$y <- rev(seq_len(nrow(card_rows)))

p_card <- ggplot(card_rows) +
  geom_text(aes(x = 0, y = y, label = label), hjust = 0, size = 4, family = font_family, fontface = "bold") +
  geom_text(aes(x = 1, y = y, label = value), hjust = 0, size = 4, family = font_family) +
  scale_x_continuous(limits = c(-0.05, 2.2), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0, nrow(card_rows) + 1), expand = c(0, 0)) +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(axis.text = element_blank(), axis.ticks = element_blank(), panel.grid = element_blank())

# AMR/virulence gene hits, grouped by real database/class -- only drawn
# when this genome actually has hits (a clean genome with zero AMR/
# virulence hits is a real, valid, good result -- not an error).
if (nrow(hits) > 0) {
  hits_summary <- hits %>% count(source, name = "n")
  p_hits <- ggplot(hits_summary, aes(x = reorder(source, n), y = n, fill = source)) +
    geom_bar(stat = "identity", color = "black", linewidth = 0.2) +
    coord_flip() +
    scale_fill_brewer(palette = "Set2") +
    labs(x = NULL, y = "Gene hits") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
    theme(legend.position = "none")
  final_plot <- p_card | p_hits
} else {
  final_plot <- p_card
}

title <- paste0("Genome Summary: ", genome)
final_plot <- with_title_bar(final_plot, title, size = 10, title_height = 0.08, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = max(6, nrow(card_rows) * 0.35), units = "in", dpi = 150, bg = "white")
saveRDS(list(plot = final_plot, width = 12, height = max(6, nrow(card_rows) * 0.35)),
        file.path(args$out_dir, "plot_final.rds"))

effective_style <- default_style_for_groups(if (nrow(hits) > 0) hits$source else character(0),
                                             legend_position = "none", show_labels = FALSE,
                                             background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(row = row, hits = hits), file.path(args$out_dir, "sigma_genome_summary.rds"))

log_line("[sigma_genome_summary] wrote data.json, default_style.json, sigma_genome_summary.rds, preview.png")
