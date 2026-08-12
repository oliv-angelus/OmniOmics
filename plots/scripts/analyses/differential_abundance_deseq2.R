# Real differential abundance analysis (DESeq2 Wald test, genus-level
# biomarkers), direct translation of microbiome.R's section 12. See
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

suppressMessages({
  library(phyloseq)
  library(DESeq2)
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(ggplot2)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(alpha = "0.01", min_lfc = "7"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
if (is.null(args$reference_group) || args$reference_group == "") stop("--reference_group is required")
if (is.null(args$test_group) || args$test_group == "") stop("--test_group is required")
group_var <- args$group_var
reference_group <- args$reference_group
test_group <- args$test_group
alpha <- as.numeric(args$alpha)
min_lfc <- as.numeric(args$min_lfc)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[differential_abundance_deseq2] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[differential_abundance_deseq2] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

meta_cols <- colnames(sample_data(ps))
if (!(group_var %in% meta_cols)) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(meta_cols, collapse = ", ")))
}
levels_available <- unique(as.character(data.frame(sample_data(ps))[[group_var]]))
if (!(reference_group %in% levels_available)) {
  stop(sprintf("reference_group '%s' is not a level of '%s'. Available levels: %s",
               reference_group, group_var, paste(levels_available, collapse = ", ")))
}

ps_deseq <- ps
d <- sample_data(ps_deseq)
if (any(is.na(d[[group_var]]))) {
  log_line("[differential_abundance_deseq2] dropping samples with NA in %s", group_var)
  ps_deseq <- subset_samples(ps_deseq, !is.na(get(group_var)))
}

sample_data(ps_deseq)[[group_var]] <- factor(sample_data(ps_deseq)[[group_var]])
sample_data(ps_deseq)[[group_var]] <- relevel(sample_data(ps_deseq)[[group_var]], ref = reference_group)

# DESeq2 needs real replicates to estimate dispersion at all -- confirmed for
# real against a 1-sample-per-group pilot-study-shaped fixture, where this
# would otherwise crash deep inside DESeq with a raw, unhelpful error
# ("design matrix has the same number of samples and coefficients... no
# longer supported since v1.22") instead of telling the user what's
# actually wrong up front.
level_counts <- table(sample_data(ps_deseq)[[group_var]])
if (any(level_counts < 2)) {
  under_replicated <- names(level_counts)[level_counts < 2]
  stop(sprintf(
    "DESeq2 needs at least 2 samples per level of '%s' to estimate dispersion -- %s only %s: %s.",
    group_var, if (length(under_replicated) > 1) "have" else "has",
    if (length(under_replicated) > 1) "1 sample each" else "1 sample",
    paste(under_replicated, collapse = ", ")
  ))
}

otu_table(ps_deseq) <- otu_table(ps_deseq) + 1  # DESeq2 needs no exact zeros
formula_deseq <- as.formula(paste("~", group_var))
diagdds <- phyloseq_to_deseq2(ps_deseq, formula_deseq)

log_line("[differential_abundance_deseq2] running DESeq2 for %s (reference: %s)...", group_var, reference_group)
# Real, edge case: DESeq2's default fitType="parametric" needs
# enough taxa/dispersion spread to fit a trend curve through -- with very
# few taxa (amplicon data at genus/family rank can genuinely have this few
# in a small/simple community, unlike RNA-seq's usual thousands of genes)
# it can fail outright ("all gene-wise dispersion estimates are within 2
# orders of magnitude from the minimum value"). First attempt at a fix
# tried fitType="mean" (DESeq2's suggested *fit-curve* alternative) -- this
# was NOT sufficient, confirmed by hitting the exact same error again:
# "mean" still calls estimateDispersionsFit internally, just with a
# different curve shape, and a genuinely too-homogeneous dispersion spread
# defeats any curve fit, not just the parametric one. The real fix DESeq2's
# own error message names is to skip curve-fitting entirely and use the
# per-taxon (gene-wise) dispersion estimates directly as final estimates --
# that means dropping down to the individual estimateSizeFactors /
# estimateDispersionsGeneEst / nbinomWaldTest steps DESeq's own
# convenience wrapper normally chains together, not just changing one of
# its arguments.
diagdds <- tryCatch(
  DESeq(diagdds, test = "Wald", fitType = "parametric", quiet = TRUE),
  error = function(e) {
    log_line("[differential_abundance_deseq2] parametric dispersion fit failed (%s) -- falling back to gene-wise dispersion estimates (DESeq2's own documented workaround: skip the curve fit entirely rather than try a different curve shape).",
             conditionMessage(e))
    dds <- estimateSizeFactors(diagdds)
    dds <- estimateDispersionsGeneEst(dds)
    dispersions(dds) <- mcols(dds)$dispGeneEst
    nbinomWaldTest(dds, quiet = TRUE)
  }
)

# Which non-reference level this comparison tests is an explicit parameter
# (--test_group) rather than resultsNames's last coefficient. With more than
# two groups, taking the last coefficient would silently fix the comparison
# to whichever level happens to sort last, with no way to choose and no
# indication that a choice was being made at all.
# Every non-reference level's own coefficient already exists on this SAME
# fitted model (DESeq2's own treatment-contrast parameterization gives one
# per level automatically), so this just resolves the specific one asked
# for instead of assuming the last.
if (test_group == reference_group) {
  stop(sprintf("test_group and reference_group can't both be '%s' -- pick a different level to test.", test_group))
}
coef_name <- paste0(group_var, "_", test_group, "_vs_", reference_group)
available_coefs <- resultsNames(diagdds)[-1]
if (!(coef_name %in% available_coefs)) {
  available_levels <- sub("_vs_.*$", "", sub(paste0("^", group_var, "_"), "", available_coefs))
  stop(sprintf("test_group '%s' is not a valid comparison against reference '%s'. Available: %s",
               test_group, reference_group, paste(available_levels, collapse = ", ")))
}
nivel_teste <- test_group
results_deseq <- results(diagdds, name = coef_name, cooksCutoff = FALSE)
log_line("[differential_abundance_deseq2] comparison: %s vs %s", nivel_teste, reference_group)

tax_table_df <- as.data.frame(tax_table(ps_deseq))
res_tab <- cbind(as.data.frame(results_deseq), tax_table_df[rownames(results_deseq), ])

sigtab <- res_tab %>%
  filter(padj < alpha) %>%
  filter(abs(log2FoldChange) > min_lfc) %>%
  drop_na(Genus)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

if (nrow(sigtab) == 0) {
  log_line("[differential_abundance_deseq2] no biomarkers passed padj < %g & |log2FC| > %g -- writing an empty result, no plot", alpha, min_lfc)
  write_json(
    list(analysis_id = "differential_abundance_deseq2", group_var = group_var, reference_group = reference_group,
         comparison_level = nivel_teste, n_biomarkers = 0, biomarkers = list()),
    file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
  )
  saveRDS(list(full_results = res_tab), file.path(args$out_dir, "differential_abundance_deseq2.rds"))
  log_line("[differential_abundance_deseq2] wrote data.json (empty), differential_abundance_deseq2.rds -- no preview.png")
  quit(save = "no", status = 0)
}

log_line("[differential_abundance_deseq2] %d biomarker(s) found", nrow(sigtab))

sigtab <- sigtab %>% mutate(Enriched_In = ifelse(log2FoldChange > 0, nivel_teste, reference_group))
sigtab$Genus <- factor(as.character(sigtab$Genus), levels = unique(as.character(sigtab$Genus[order(sigtab$log2FoldChange)])))

colors_groups <- resolve_palette(sigtab$Enriched_In, style)

p <- ggplot(sigtab, aes(x = Genus, y = log2FoldChange, color = Enriched_In)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_errorbar(aes(ymin = log2FoldChange - lfcSE, ymax = log2FoldChange + lfcSE), width = 0.2, color = "black", alpha = 0.6) +
  geom_point(size = 4) +
  scale_color_manual(values = colors_groups, name = "More abundant in:") +
  labs(y = "Log2 Fold Change", x = NULL) +
  coord_flip() +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale, style = style) +
  theme(
    axis.text.y = element_text(size = 11, face = "italic"),
    legend.position = "top",
    legend.background = element_rect(fill = bg, color = NA)
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Differential Abundance (Genus): ", group_var, "\n",
                 "Significant Biomarkers (p < ", alpha, " | LFC > ", min_lfc, ")")
final_plot <- with_title_bar(p, title, size = 6, title_height = 0.15, font_family = font_family)
height <- max(6, nrow(sigtab) * 0.25)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 14, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = 14, height = height),
        file.path(args$out_dir, "plot_final.rds"))

biomarkers <- lapply(seq_len(nrow(sigtab)), function(i) {
  list(
    asv_id = rownames(sigtab)[i], genus = as.character(sigtab$Genus[i]),
    log2fc = sigtab$log2FoldChange[i], padj = sigtab$padj[i], enriched_in = sigtab$Enriched_In[i]
  )
})

write_json(
  list(analysis_id = "differential_abundance_deseq2", group_var = group_var, reference_group = reference_group,
       comparison_level = nivel_teste, n_biomarkers = nrow(sigtab), biomarkers = biomarkers),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(sigtab$Enriched_In, legend_position = "top", show_labels = FALSE,
                                             background = bg, font_family = font_family, palette = colors_groups)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(full_results = res_tab, sigtab = sigtab), file.path(args$out_dir, "differential_abundance_deseq2.rds"))

log_line("[differential_abundance_deseq2] wrote data.json, default_style.json, differential_abundance_deseq2.rds, preview.png")
