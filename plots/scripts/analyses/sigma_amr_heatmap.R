# Real AMR/virulence gene presence/absence heatmap across every genome in
# the run -- standard comparative genomics/epidemiology output (which
# resistance genes does each isolate carry), built from the sparse
# gene-hit table lib/build_sigma_table.R's build_sigma_gene_hits produces
# (AMRFinderPlus + ABRicate's ncbi/card/vfdb databases combined). No
# --genome picker needed -- the whole point is comparing genomes side by
# side; sigma_genome_summary already covers "what does THIS ONE genome
# have" in more detail.
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
  library(tidyr)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(source_filter = "all", top_n = "40"))
source_filter <- args$source_filter  # "all" | "amrfinder" | "abricate_ncbi" | "abricate_card" | "abricate_vfdb"
top_n_genes <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[sigma_amr_heatmap] reading cached SIGMA table from %s", args$sigma_table_rds)
loaded <- readRDS(args$sigma_table_rds)
all_genomes <- loaded$genome_summary$sample
hits <- loaded$gene_hits
if (source_filter != "all") {
  hits <- hits %>% filter(source == source_filter)
}
log_line("[sigma_amr_heatmap] %d gene hit(s) across %d genome(s) (source filter: %s)", nrow(hits), length(all_genomes), source_filter)

if (nrow(hits) == 0) {
  log_line("[sigma_amr_heatmap] no gene hits at all (source filter: %s) -- writing an empty result, no plot", source_filter)
  dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
  write_json(
    list(analysis_id = "sigma_amr_heatmap", source_filter = source_filter, n_genes = 0, genomes = all_genomes, records = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  log_line("[sigma_amr_heatmap] wrote data.json (empty) -- no preview.png")
  quit(save = "no", status = 0)
}

# One gene can legitimately hit more than once in the same genome (e.g. a
# duplicated resistance cassette, or the same gene called by both
# AMRFinderPlus and an ABRicate database) -- presence/absence collapses
# that to a real yes/no per (gene, genome) cell, the actual question this
# heatmap answers.
presence <- hits %>%
  distinct(sample, gene) %>%
  mutate(present = TRUE)

gene_prevalence <- presence %>% count(gene, name = "n_genomes") %>% arrange(desc(n_genomes))
top_genes <- gene_prevalence %>% slice_head(n = top_n_genes) %>% pull(gene)
if (nrow(gene_prevalence) > top_n_genes) {
  log_line("[sigma_amr_heatmap] %d distinct genes found, showing the top %d by prevalence", nrow(gene_prevalence), top_n_genes)
}

# Every genome x every shown gene, including real, honest FALSE cells for
# genes that gene simply doesn't carry -- a dense grid is the whole point
# of a presence/absence heatmap, not a sparse list.
grid <- expand.grid(sample = all_genomes, gene = top_genes, stringsAsFactors = FALSE) %>%
  left_join(presence, by = c("sample", "gene")) %>%
  mutate(present = ifelse(is.na(present), FALSE, present))

# Hierarchical clustering on both axes (genomes with similar resistance
# profiles group together, co-occurring genes group together) -- same real
# recipe dogma_de_heatmap.R/de_heatmap.R already use for their own z-score
# heatmaps, applied here to a binary presence matrix instead.
mat <- grid %>% select(sample, gene, present) %>% pivot_wider(names_from = gene, values_from = present) %>% as.data.frame
rownames(mat) <- mat$sample
mat$sample <- NULL
mat_num <- as.matrix(mat) * 1
sample_order <- if (nrow(mat_num) >= 2) rownames(mat_num)[hclust(dist(mat_num))$order] else rownames(mat_num)
gene_order <- if (ncol(mat_num) >= 2) colnames(mat_num)[hclust(dist(t(mat_num)))$order] else colnames(mat_num)

grid$sample <- factor(grid$sample, levels = sample_order)
grid$gene <- factor(grid$gene, levels = gene_order)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

p <- ggplot(grid, aes(x = sample, y = gene, fill = present)) +
  geom_tile(color = "white", linewidth = 0.3) +
  scale_fill_manual(values = c(`TRUE` = "#D95F02", `FALSE` = "gray92"), labels = c(`TRUE` = "Present", `FALSE` = "Absent"), name = NULL) +
  labs(x = NULL, y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5),
    axis.text.y = element_text(size = 9),
    panel.grid = element_blank(),
    legend.position = "top"
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("AMR/Virulence Gene Presence (", source_filter, "): ", length(top_genes), " gene(s) x ", length(all_genomes), " genome(s)")
height <- max(6, length(top_genes) * 0.25)
width <- max(8, length(all_genomes) * 0.5)
final_plot <- with_title_bar(p, title, size = 8, title_height = 0.08, font_family = font_family, plot_width_in = width)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "sigma_amr_heatmap", source_filter = source_filter, n_genes = length(top_genes), genomes = all_genomes,
       records = lapply(seq_len(nrow(grid)), function(i) list(
         genome = as.character(grid$sample[i]), gene = as.character(grid$gene[i]), present = grid$present[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(palette = list(`TRUE` = "#D95F02", `FALSE` = "#EBEBEB"), legend_position = "top",
                         show_labels = FALSE, background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(grid = grid, gene_prevalence = gene_prevalence), file.path(args$out_dir, "sigma_amr_heatmap.rds"))

log_line("[sigma_amr_heatmap] wrote data.json, default_style.json, sigma_amr_heatmap.rds, preview.png")
