# Compares MAGMA's two independent community classifiers for the same reads:
# Kraken2/Bracken (k-mer-based) vs. Kaiju (translated-protein-based). They
# are not interchangeable line-by-line -- Kaiju classifies by protein
# translation and tends to assign more reads in samples with a lot of
# taxonomic novelty, since amino acid similarity survives more sequence
# divergence than nucleotide k-mer matching does. Agreement between two
# independently-built classifications is itself real evidence, not just a
# choice between the two -- so this shows both: total abundance per taxon by
# each classifier side by side, and which taxa each one calls that the other
# entirely misses.
#
# Reads BOTH cached phyloseq objects: the Kraken one it's handed via
# --phyloseq_rds (this analysis's own input_shape is the default "phyloseq"),
# and its Kaiju sibling by fixed filename convention in the same directory
# (see main.py's INPUT_SHAPE_INFO -- every loaded-data instance for a MAGMA
# run gets both files written into the same out_dir by the same /load call).

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
  library(phyloseq)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(top_n = "15"))
top_n_taxa <- as.integer(args$top_n)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0

log_line("[magma_classifier_concordance] reading Kraken2/Bracken phyloseq from %s", args$phyloseq_rds)
ps_kraken <- readRDS(args$phyloseq_rds)

kaiju_rds <- file.path(dirname(args$phyloseq_rds), "phyloseq_kaiju.rds")
if (!file.exists(kaiju_rds)) {
  stop(sprintf(paste0("No Kaiju-classified phyloseq object at %s -- this run was loaded before Kaiju ",
                      "support existed, or its results folder is missing abundance_table_final_kaiju_RAW.tsv. ",
                      "Reload this run's metadata (Trocar metadados) to rebuild both classifiers."), kaiju_rds))
}
log_line("[magma_classifier_concordance] reading Kaiju phyloseq from %s", kaiju_rds)
ps_kaiju <- readRDS(kaiju_rds)

log_line("[magma_classifier_concordance] Kraken2/Bracken: %d taxa x %d samples | Kaiju: %d taxa x %d samples",
         ntaxa(ps_kraken), nsamples(ps_kraken), ntaxa(ps_kaiju), nsamples(ps_kaiju))

# Both objects are built by the same build_phyloseq() from tables that share
# the same "d__...;p__...;...;s__..." lineage-string convention -- summing at
# Species (the finest shared rank, since neither classifier's leaf taxon IDs
# match the other's) is what makes the two comparable at all.
summarize_classifier <- function(ps, label) {
  rank <- if ("Species" %in% rank_names(ps)) "Species" else rank_names(ps)[length(rank_names(ps))]
  glom <- tax_glom(ps, taxrank = rank, NArm = FALSE)
  df <- psmelt(glom)
  df[[rank]] <- as.character(df[[rank]])
  df[[rank]][is.na(df[[rank]])] <- "Unclassified"
  df %>%
    group_by(taxon = .data[[rank]]) %>%
    summarise(total_reads = sum(Abundance), .groups = "drop") %>%
    mutate(classifier = label)
}

combined <- bind_rows(
  summarize_classifier(ps_kraken, "Kraken2/Bracken"),
  summarize_classifier(ps_kaiju, "Kaiju")
)

wide <- combined %>%
  pivot_wider(names_from = classifier, values_from = total_reads, values_fill = 0)
kraken_col <- "Kraken2/Bracken"; kaiju_col <- "Kaiju"
wide$total <- wide[[kraken_col]] + wide[[kaiju_col]]
wide <- wide %>% arrange(desc(total))

n_shared <- sum(wide[[kraken_col]] > 0 & wide[[kaiju_col]] > 0)
n_kraken_only <- sum(wide[[kraken_col]] > 0 & wide[[kaiju_col]] == 0)
n_kaiju_only <- sum(wide[[kraken_col]] == 0 & wide[[kaiju_col]] > 0)
log_line("[magma_classifier_concordance] %d taxa found by both, %d Kraken2-only, %d Kaiju-only",
         n_shared, n_kraken_only, n_kaiju_only)

top_taxa <- wide %>% slice_head(n = top_n_taxa) %>% pull(taxon)
plot_df <- combined %>%
  mutate(Taxon_Plot = ifelse(taxon %in% top_taxa, taxon, "Others")) %>%
  group_by(classifier, Taxon_Plot) %>%
  summarise(total_reads = sum(total_reads), .groups = "drop")
order <- if ("Others" %in% plot_df$Taxon_Plot) c(top_taxa, "Others") else top_taxa
plot_df$Taxon_Plot <- factor(plot_df$Taxon_Plot, levels = order)
plot_df$classifier <- factor(plot_df$classifier, levels = c("Kraken2/Bracken", "Kaiju"))

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

palette <- resolve_palette(as.character(plot_df$Taxon_Plot), style)

p <- ggplot(plot_df, aes(x = classifier, y = total_reads, fill = Taxon_Plot)) +
  geom_col(position = "fill", width = 0.65) +
  scale_y_continuous(labels = scales::percent) +
  scale_fill_manual(values = palette, name = "Taxon") +
  labs(x = NULL, y = "Relative abundance (combined across samples)") +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(legend.position = "right")

title <- sprintf("Classifier Concordance  |  %d shared, %d Kraken2-only, %d Kaiju-only",
                 n_shared, n_kraken_only, n_kaiju_only)
final_plot <- with_title_bar(p, title, size = 10, font_family = font_family)

write_json(
  list(analysis_id = "magma_classifier_concordance",
       n_taxa_kraken = sum(wide[[kraken_col]] > 0), n_taxa_kaiju = sum(wide[[kaiju_col]] > 0),
       n_shared = n_shared, n_kraken_only = n_kraken_only, n_kaiju_only = n_kaiju_only,
       taxa = lapply(seq_len(nrow(wide)), function(i) list(
         taxon = wide$taxon[i],
         kraken_reads = wide[[kraken_col]][i], kaiju_reads = wide[[kaiju_col]][i],
         found_by = if (wide[[kraken_col]][i] > 0 && wide[[kaiju_col]][i] > 0) "both"
                    else if (wide[[kraken_col]][i] > 0) "kraken_only" else "kaiju_only"
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

width <- 9; height <- 7
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

effective_style <- default_style_for_groups(as.character(plot_df$Taxon_Plot), legend_position = "right",
                                            show_labels = TRUE, background = bg, font_family = font_family,
                                            palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))
saveRDS(wide, file.path(args$out_dir, "magma_classifier_concordance.rds"))

log_line("[magma_classifier_concordance] wrote data.json, default_style.json, magma_classifier_concordance.rds, preview.png, plot_final.rds")
