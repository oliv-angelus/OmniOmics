# Functional over-representation analysis (ORA) of the DE gene set against
# DEFINE's own eggNOG-derived annotation columns (COG category / GO terms /
# KEGG pathway) -- NOT against a curated Bioconductor OrgDb, since DEFINE
# genomes are arbitrary user-uploaded bacteria with no such package. Real,
# documented, current approach for exactly this scenario, confirmed against
# clusterProfiler's own documentation: Yu, G., Wang, L.-G.,
# Han, Y. & He, Q.-Y. (2012), "clusterProfiler: an R package for comparing
# biological themes among gene clusters", OMICS, 16(5), 284-287, DOI
# 10.1089/omi.2011.0118; Wu, T. et al. (2021), "clusterProfiler 4.0: A
# universal enrichment tool for interpreting omics data", The Innovation,
# 2(3), 100141, DOI 10.1016/j.xinn.2021.100141 -- `enricher`'s generic
# TERM2GENE interface is documented by the authors themselves as exactly for
# "unsupported organisms... customized annotations". DEFINE-only; see
# plots/manifest.yaml for parameter descriptions.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "deseq_helpers.R"))

suppressMessages({
  library(DESeq2)
  library(dplyr)
  library(ggplot2)
  library(clusterProfiler)
  library(jsonlite)
})

# The real, standard NCBI/COG functional category letters -> descriptions
# (https://www.ncbi.nlm.nih.gov/research/cog/, stable since COG's original
# design) -- eggNOG-mapper's COG_category column is one or more of these
# single letters concatenated with NO delimiter (e.g. "EGP" = 3 categories),
# unlike GOs/KEGG_Pathway which comma-separate multiple values. Used only to
# turn bare letters into readable plot labels; the enrichment math itself
# doesn't need the descriptions.
COG_CATEGORY_NAMES <- c(
  J = "Translation, ribosomal structure and biogenesis", A = "RNA processing and modification",
  K = "Transcription", L = "Replication, recombination and repair", B = "Chromatin structure and dynamics",
  D = "Cell cycle control, cell division, chromosome partitioning", Y = "Nuclear structure",
  V = "Defense mechanisms", T = "Signal transduction mechanisms", M = "Cell wall/membrane/envelope biogenesis",
  N = "Cell motility", Z = "Cytoskeleton", W = "Extracellular structures",
  U = "Intracellular trafficking, secretion, and vesicular transport", O = "Posttranslational modification, protein turnover, chaperones",
  C = "Energy production and conversion", G = "Carbohydrate transport and metabolism", E = "Amino acid transport and metabolism",
  F = "Nucleotide transport and metabolism", H = "Coenzyme transport and metabolism", I = "Lipid transport and metabolism",
  P = "Inorganic ion transport and metabolism", Q = "Secondary metabolites biosynthesis, transport and catabolism",
  R = "General function prediction only", S = "Function unknown"
)

args <- parse_cli_args(defaults = list(alpha = "0.05", min_lfc = "1", term_source = "COG_category", p_cutoff = "0.05"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
if (is.null(args$test_group) || args$test_group == "") stop("--test_group is required")
group_var <- args$group_var
reference_group <- args$reference_group
test_group <- args$test_group
alpha <- as.numeric(args$alpha)
min_lfc <- as.numeric(args$min_lfc)
term_source <- args$term_source
p_cutoff <- as.numeric(args$p_cutoff)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0

log_line("[functional_enrichment] reading cached count matrix from %s", args$count_matrix_rds)
count_data <- readRDS(args$count_matrix_rds)
log_line("[functional_enrichment] count matrix: %d genes x %d samples", nrow(count_data$counts), ncol(count_data$counts))

dds <- run_deseq(count_data, group_var, reference_group)
coef_name <- deseq_coef_name(dds, group_var, test_group, reference_group)
log_line("[functional_enrichment] comparison: %s vs %s", test_group, reference_group)
res_df <- as.data.frame(results(dds, name = coef_name)) %>% tibble::rownames_to_column("locus_tag") %>% filter(!is.na(padj))

sig_genes <- res_df %>% filter(padj < alpha, abs(log2FoldChange) > min_lfc) %>% pull(locus_tag)
universe <- res_df$locus_tag
log_line("[functional_enrichment] %d significant gene(s) (of %d tested) at padj < %g & |log2FC| > %g",
          length(sig_genes), length(universe), alpha, min_lfc)

if (length(sig_genes) == 0) {
  log_line("[functional_enrichment] no significant genes -- nothing to test enrichment on, writing an empty result")
  dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
  write_json(
    list(analysis_id = "functional_enrichment", group_var = group_var, reference_group = reference_group,
         comparison_level = test_group, term_source = term_source, n_sig_genes = 0, terms = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  log_line("[functional_enrichment] wrote data.json (empty) -- no preview.png")
  quit(save = "no", status = 0)
}

# Builds clusterProfiler's TERM2GENE (a plain 2-column data.frame: term,
# gene) straight from the annotation column already in the count table --
# COG_category is letters concatenated with no delimiter, GOs/KEGG_Pathway
# comma-separate multiple values; "-" is eggNOG's own "no annotation" marker
# and is dropped before building the mapping.
build_term2gene <- function(gene_info, column) {
  raw <- gene_info[[column]]
  genes <- rownames(gene_info)
  split_fn <- if (column == "COG_category") function(x) strsplit(x, "") else function(x) strsplit(x, ",")
  pairs <- Map(function(g, v) {
    if (is.na(v) || v == "" || v == "-") return(NULL)
    terms <- trimws(split_fn(v)[[1]])
    terms <- terms[terms != "" & terms != "-"]
    if (length(terms) == 0) return(NULL)
    data.frame(term = terms, gene = g, stringsAsFactors = FALSE)
  }, genes, raw)
  do.call(rbind, pairs)
}

term2gene <- build_term2gene(count_data$gene_info, term_source)
if (is.null(term2gene) || nrow(term2gene) == 0) {
  stop(sprintf("No usable '%s' annotation found in the count table (every value was empty or '-') -- try a different --term_source.", term_source))
}

enrich_result <- enricher(
  gene = sig_genes, universe = universe, TERM2GENE = term2gene,
  pvalueCutoff = p_cutoff, qvalueCutoff = 1, minGSSize = 1
)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

if (is.null(enrich_result) || nrow(as.data.frame(enrich_result)) == 0) {
  log_line("[functional_enrichment] no term met p_cutoff < %g -- writing an empty result, no plot", p_cutoff)
  write_json(
    list(analysis_id = "functional_enrichment", group_var = group_var, reference_group = reference_group,
         comparison_level = test_group, term_source = term_source, n_sig_genes = length(sig_genes), terms = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  log_line("[functional_enrichment] wrote data.json (empty) -- no preview.png")
  quit(save = "no", status = 0)
}

enrich_df <- as.data.frame(enrich_result) %>%
  mutate(
    Label = if (term_source == "COG_category") paste0(ID, " -- ", COG_CATEGORY_NAMES[ID]) else ID,
    Label = ifelse(is.na(Label), ID, Label),
    GeneRatioNum = sapply(strsplit(GeneRatio, "/"), function(x) as.numeric(x[1]) / as.numeric(x[2]))
  ) %>%
  arrange(p.adjust) %>%
  head(20)
enrich_df$Label <- factor(enrich_df$Label, levels = rev(enrich_df$Label))

p <- ggplot(enrich_df, aes(x = GeneRatioNum, y = Label, size = Count, color = p.adjust)) +
  geom_point() +
  scale_color_distiller(palette = "Spectral", name = "padj") +
  scale_size_continuous(range = c(3, 10), name = "Gene count") +
  labs(x = "Gene ratio", y = NULL) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(legend.position = "right", axis.text.y = element_text(size = 10))

title <- paste0("Functional Enrichment (", term_source, "): ", test_group, " vs ", reference_group,
                 "\n", length(sig_genes), " DE genes tested against ", nrow(term2gene %>% distinct(gene)), " annotated genes")
final_plot <- with_title_bar(p, title, size = 6, title_height = 0.14, font_family = font_family)
height <- max(6, nrow(enrich_df) * 0.35)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = 12, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_json(
  list(analysis_id = "functional_enrichment", group_var = group_var, reference_group = reference_group,
       comparison_level = test_group, term_source = term_source, n_sig_genes = length(sig_genes),
       terms = lapply(seq_len(nrow(enrich_df)), function(i) list(
         term = enrich_df$ID[i], label = as.character(enrich_df$Label[i]), gene_ratio = enrich_df$GeneRatioNum[i],
         count = enrich_df$Count[i], padj = enrich_df$p.adjust[i], genes = enrich_df$geneID[i]
       ))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- list(palette = "Spectral", legend_position = "right", show_labels = FALSE,
                         background = bg, font_family = font_family)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(enrich_result = enrich_result, enrich_df = enrich_df), file.path(args$out_dir, "functional_enrichment.rds"))

log_line("[functional_enrichment] wrote data.json, default_style.json, functional_enrichment.rds, preview.png")
