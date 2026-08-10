# Shared DESeq2 setup for every DEFINE analysis (plots/scripts/analyses/
# sample_pca.R, sample_distance_heatmap.R, ma_plot.R, volcano_plot.R,
# de_heatmap.R, functional_enrichment.R) -- DEFINE-only, mirrors but never
# shares code with MAGMA's differential_abundance_deseq2.R. Real standard
# recommended here, not invented: Love, Huber & Anders (2014), Genome
# Biology, DOI 10.1186/s13059-014-0550-8 (the DESeq2 paper), whose own
# actively-maintained Bioconductor vignette recommends every plot type this
# analysis set builds (PCA, sample-distance heatmap, MA plot) on
# VST/rlog-transformed data from a DESeqDataSet built exactly this way.
suppressMessages(library(DESeq2))

#' Builds + runs a DESeqDataSet from the cached count_matrix bundle
#' (build_count_matrix's return value) for a chosen group_var/
#' reference_group. The cached object holds the raw ingredients; each
#' analysis picks its own design here -- same per-analysis-chosen-group_var
#' flexibility MAGMA's phyloseq-based analyses already have (see
#' resolve_palette/tax_glom being called fresh per analysis there).
#' `reference_group` is optional (NULL is fine for analyses that only need
#' the fitted model, e.g. sample_pca/sample_distance_heatmap/dispersion --
#' not for ones that report a specific comparison's direction, e.g.
#' ma_plot/volcano_plot/de_heatmap, which require it).
run_deseq <- function(count_data, group_var, reference_group = NULL) {
  coldata <- count_data$coldata
  if (!(group_var %in% colnames(coldata))) {
    stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
                 group_var, paste(colnames(coldata), collapse = ", ")))
  }

  counts <- count_data$counts
  # Samples with NA in group_var can't be assigned to a design level --
  # dropped rather than erroring, same reasoning as build_phyloseq-based
  # analyses already use for their own group_var.
  keep_samples <- !is.na(coldata[[group_var]])
  if (!all(keep_samples)) {
    log_line("[deseq_helpers] dropping %d sample(s) with NA in %s", sum(!keep_samples), group_var)
  }
  coldata <- coldata[keep_samples,, drop = FALSE]
  counts <- counts[, rownames(coldata), drop = FALSE]

  coldata[[group_var]] <- factor(coldata[[group_var]])
  if (!is.null(reference_group) && reference_group != "") {
    if (!(reference_group %in% levels(coldata[[group_var]]))) {
      stop(sprintf("reference_group '%s' is not a level of '%s'. Available levels: %s",
                   reference_group, group_var, paste(levels(coldata[[group_var]]), collapse = ", ")))
    }
    coldata[[group_var]] <- relevel(coldata[[group_var]], ref = reference_group)
  }

  # DESeq2 needs real replicates to estimate dispersion at all -- same guard
  # (and same real crash it prevents) as differential_abundance_deseq2.R's
  # own level_counts check.
  level_counts <- table(coldata[[group_var]])
  if (any(level_counts < 2)) {
    under_replicated <- names(level_counts)[level_counts < 2]
    stop(sprintf(
      "DESeq2 needs at least 2 samples per level of '%s' to estimate dispersion -- %s only %s: %s.",
      group_var, if (length(under_replicated) > 1) "have" else "has",
      if (length(under_replicated) > 1) "1 sample each" else "1 sample",
      paste(under_replicated, collapse = ", ")
    ))
  }

  formula_deseq <- as.formula(paste("~", group_var))
  dds <- DESeqDataSetFromMatrix(countData = counts, colData = coldata, design = formula_deseq)
  dds <- dds[rowSums(counts(dds)) > 0, ]  # drop genes with zero reads in every remaining sample

  # Real, edge case: with
  # too little dispersion spread across features, DESeq2's default
  # fitType="parametric" curve fit can fail outright ("all gene-wise
  # dispersion estimates are within 2 orders of magnitude from the minimum
  # value"). The real fix DESeq2's own error message names is to skip
  # curve-fitting entirely and use each feature's own gene-wise dispersion
  # estimate directly as its final estimate -- not just trying a different
  # curve shape (a first-attempt fitType="mean" was confirmed, elsewhere in
  # this app's history, NOT sufficient: "mean" still calls
  # estimateDispersionsFit internally with the same failure mode).
  tryCatch(
    DESeq(dds, quiet = TRUE),
    error = function(e) {
      log_line("[deseq_helpers] parametric dispersion fit failed (%s) -- falling back to gene-wise dispersion estimates (DESeq2's own documented workaround: skip the curve fit entirely rather than try a different curve shape).",
               conditionMessage(e))
      dds <- estimateSizeFactors(dds)
      dds <- estimateDispersionsGeneEst(dds)
      dispersions(dds) <- mcols(dds)$dispGeneEst
      nbinomWaldTest(dds, quiet = TRUE)
    }
  )
}

#' Resolves the exact DESeq2 coefficient name for an explicitly chosen
#' test_group vs. reference_group comparison, rather than defaulting to
#' resultsNames(dds)'s last coefficient. With group_var having more than 2
#' levels (any multi-condition experiment -- e.g. control/acid/base/heat/
#' cold), the last coefficient is just whichever level sorts last
#' alphabetically, which fixes the comparison silently and offers no way to
#' test a different condition. Every non-reference
#' level's own coefficient already exists simultaneously on ONE fitted
#' model (run_deseq relevels to reference_group once; DESeq2's own
#' treatment-contrast parameterization then gives every OTHER level its own
#' "<group_var>_<level>_vs_<reference_group>" coefficient for free -- the
#' same fact `de_upset.R` relies on to loop over all of them). This resolves
#' the one named by --test_group.
deseq_coef_name <- function(dds, group_var, test_group, reference_group) {
  if (test_group == reference_group) {
    stop(sprintf("test_group and reference_group can't both be '%s' -- pick a different condition to test.", test_group))
  }
  coef_name <- paste0(group_var, "_", test_group, "_vs_", reference_group)
  available <- resultsNames(dds)[-1]
  if (!(coef_name %in% available)) {
    available_levels <- sub("_vs_.*$", "", sub(paste0("^", group_var, "_"), "", available))
    stop(sprintf("test_group '%s' is not a valid comparison against reference '%s'. Available: %s",
                 test_group, reference_group, paste(available_levels, collapse = ", ")))
  }
  coef_name
}

#' Variance-stabilizing transform for visualization (PCA, sample-distance
#' heatmap, DE-gene heatmap) -- blind=TRUE (ignores the design, appropriate
#' for these exploratory/QC-style plots, per the DESeq2 vignette's own
#' guidance) so the same transform is reused across analyses regardless of
#' which group_var a given one was run with.
vst_blind <- function(dds) {
  # vst needs a reasonable number of genes to estimate its trend robustly;
  # DESeq2 itself recommends varianceStabilizingTransformation (no size
  # constraint, slower) as the fallback for small gene counts -- real
  # synthetic/demo data can be tiny (a handful of genes), where vst's own
  # dispersion-trend fit would otherwise error outright.
  # # Real, edge case: blind=TRUE makes this refit dispersions from scratch (design
  # ~1), independent of whatever run_deseq already resolved -- so its own
  # curve-fit failure isn't caught by that function's own fallback. Worse,
  # DESeq2 doesn't even raise a catchable error on a too-small dataset here:
  # it prints a *message* ("dispersion trend was not well captured... a
  # local regression fit was automatically substituted") and silently
  # retries with fitType="local" internally -- which then crashes with a
  # real locfit internal error ("newsplit: out of vertex space") that WAS
  # NOT designed to be caught cleanly. So the fix can't be "catch the error
  # and retry" here; it has to pre-empt the auto-escalation entirely by
  # going straight to fitType="mean" (skip curve-fitting altogether, same
  # "use a single value instead of a curve" real DESeq2-documented
  # workaround already applied in run_deseq, just via this function's own
  # fitType argument instead of the lower-level estimateDispersions* calls).
  vst_fun <- if (nrow(dds) < 1000) {
    function(...) varianceStabilizingTransformation(...)
  } else {
    function(...) vst(...)
  }
  tryCatch(
    vst_fun(dds, blind = TRUE),
    error = function(e) {
      log_line("[deseq_helpers] blind dispersion fit failed during VST (%s) -- retrying with fitType='mean' (skip curve-fitting entirely).",
               conditionMessage(e))
      vst_fun(dds, blind = TRUE, fitType = "mean")
    }
  )
}
