# Alpha diversity (Observed/Chao1/ACE/Shannon/Simpson/Pielou + per-metric
# Kruskal-Wallis test) on gene-family- (or taxon-, via --annotation_column)
# aggregated counts -- the DOGMA analogue of MAGMA/PRISM's
# alpha_diversity.R, reusing phyloseq's own diversity engine unchanged (see
# lib/build_dogma_table.R's build_dogma_phyloseq for why a minimal,
# tax_table-free phyloseq object is the right vehicle here: none of
# estimate_richness/rarefy_even_depth touch tax_table at all).
# Answers a genuinely different question than dogma_functional_composition/
# differential: not "which specific gene family changed" but "is the
# community's overall functional/taxonomic richness and evenness different
# between conditions" -- the real gap flagged directly by the user (DOGMA
# profiles a whole community, like MAGMA/PRISM, not one isolate like
# DEFINE, so it deserves the same community-ecology toolkit alongside the
# DESeq2-style gene-level one already built).
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
  library(phyloseq)
  library(ggplot2)
  library(patchwork)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(annotation_column = "eggnog_KEGG_ko", seed = "123"))

if (is.null(args$group_var) || args$group_var == "") {
  stop("--group_var is required")
}

annotation_col <- args$annotation_column
group_var <- args$group_var
seed <- as.integer(args$seed)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[dogma_functional_diversity] reading cached DOGMA table from %s", args$dogma_table_rds)
loaded <- readRDS(args$dogma_table_rds)
ps <- build_dogma_phyloseq(loaded$long_table, annotation_col, loaded$coldata)
log_line("[dogma_functional_diversity] aggregated phyloseq object: %d gene families/taxa x %d samples (by %s)", ntaxa(ps), nsamples(ps), annotation_col)

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

# Real, edge case:
# phyloseq's own rarefy_even_depth crashes on a single-taxon object
# ("attempt to set 'rownames' on an object with no dimensions", confirmed
# by reproducing it directly against a minimal 1-row phyloseq object) --
# a real internal phyloseq limitation (subsetting a 1-row matrix drops its
# dimensions, per R's own default matrix-subsetting behavior, and
# phyloseq's code doesn't guard against that), not something fixable from
# outside it. Diversity metrics need at least 2 real categories to be
# meaningful anyway (Shannon/Simpson of a single category is always
# maximally uneven/zero, not a real result), so this is also the
# scientifically correct place to stop, not just a crash workaround.
if (ntaxa(ps) < 2) {
  stop(sprintf(
    "Aggregating by '%s' leaves only %d gene famil%s/taxon across this whole run -- too few for a meaningful diversity calculation (and phyloseq's own rarefaction crashes outright on exactly one). Try a different --annotation_column with more real categories.",
    annotation_col, ntaxa(ps), if (ntaxa(ps) == 1) "y" else "ies"))
}

set.seed(seed)
min_reads <- min(sample_sums(ps))
ps_rar <- rarefy_even_depth(ps, sample.size = min_reads, replace = FALSE, rngseed = seed, verbose = FALSE)
log_line("[dogma_functional_diversity] rarefied to %d reads/sample (%d gene families/taxa survived)", min_reads, ntaxa(ps_rar))

alpha_tab <- estimate_richness(ps_rar, measures = c("Observed", "Chao1", "ACE", "Shannon", "Simpson"))
alpha_tab$Pielou <- alpha_tab$Shannon / log(alpha_tab$Observed)
alpha_tab <- alpha_tab[, !grepl("se$", colnames(alpha_tab))]

meta <- data.frame(sample_data(ps_rar))
alpha_final <- cbind(meta, alpha_tab)
alpha_final$SampleID <- rownames(alpha_final)

metrics <- list(
  Observed = "Observed Richness",
  Chao1 = "Chao1",
  ACE = "ACE",
  Shannon = "Shannon Index",
  Simpson = "Simpson Index (1-D)",
  Pielou = "Pielou's Evenness (J)"
)

run_kruskal <- function(metric) {
  tryCatch({
    formula_stats <- as.formula(paste(metric, "~", group_var))
    kruskal.test(formula_stats, data = alpha_final)$p.value
  }, error = function(e) NA_real_)
}

palette <- resolve_palette(alpha_final[[group_var]], style)

plot_metric <- function(metric, title_text) {
  p_value <- run_kruskal(metric)
  title <- paste0(title_text, " (", format_p_value(p_value), ")")
  p <- ggplot(alpha_final, aes(x =.data[[group_var]], y =.data[[metric]], fill =.data[[group_var]])) +
    geom_boxplot(color = "black", outlier.shape = NA, alpha = 0.8) +
    geom_jitter(width = 0.2, size = 2.5, shape = 21, fill = "red", color = "black", stroke = 0.3) +
    scale_fill_manual(values = palette) +
    labs(x = NULL, y = NULL) +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1, size = 11),
      legend.position = "none"
    )
  p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)
  list(plot = with_title_bar(p, title, size = 6, title_height = 0.15, font_family = font_family), p_value = p_value)
}

panels <- lapply(names(metrics), function(m) plot_metric(m, metrics[[m]]))
names(panels) <- names(metrics)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

metric_results <- lapply(names(metrics), function(m) {
  list(metric = m, label = metrics[[m]], kruskal_p_value = panels[[m]]$p_value)
})

samples <- lapply(seq_len(nrow(alpha_final)), function(i) {
  row <- as.list(alpha_final[i, c("SampleID", group_var, names(metrics))])
  names(row)[2] <- "group"
  row
})

write_json(
  list(
    analysis_id = "dogma_functional_diversity",
    annotation_column = annotation_col,
    group_var = group_var,
    metrics = metric_results,
    samples = samples
  ),
  file.path(args$out_dir, "data.json"),
  auto_unbox = TRUE, pretty = TRUE, na = "null"
)

effective_style <- default_style_for_groups(alpha_final[[group_var]], legend_position = "none", show_labels = FALSE,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(ps_rar = ps_rar, alpha_table = alpha_final), file.path(args$out_dir, "dogma_functional_diversity.rds"))

final_plot <- (panels$Observed$plot | panels$Chao1$plot | panels$ACE$plot) /
  (panels$Shannon$plot | panels$Simpson$plot | panels$Pielou$plot)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 16, height = 10, units = "in", dpi = 150, bg = "white")

log_line("[dogma_functional_diversity] wrote data.json, default_style.json, dogma_functional_diversity.rds, preview.png")
