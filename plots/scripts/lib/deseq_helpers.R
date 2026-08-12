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
#' Size factors, with the sparse-data estimator as fallback.
#'
#' DESeq2's default median-of-ratios (Anders & Huber 2010) divides each
#' sample's counts by a reference built from the geometric mean ACROSS ALL
#' SAMPLES, so it needs at least one feature that is non-zero in every single
#' sample. Functional-annotation matrices routinely have none: aggregate
#' 2,000+ KEGG orthologs over a dozen samples and every family is missing from
#' somewhere. DESeq2 then stops outright with "every gene contains at least
#' one zero, cannot compute log geometric means" -- which is what this hit.
#'
#' type="poscounts" is DESeq2's own documented answer: the geometric mean is
#' taken over each feature's POSITIVE counts only (the n-th root of the
#' product of its non-zero values), originally the workaround phyloseq
#' recommended for 16S data and since folded into DESeq2 itself. It is the
#' standard normalisation for sparse microbiome/metagenomic count data.
#'
#' Applied only as a fallback rather than unconditionally: where the default
#' works it is the better-characterised estimator, and switching normalisation
#' silently would change results for every existing analysis.
.size_factors <- function(dds) {
  tryCatch(
    estimateSizeFactors(dds),
    error = function(e) {
      log_line(paste0("[deseq_helpers] default median-of-ratios size factors failed (%s) -- no feature is ",
                      "present in every sample, which is normal for functional-annotation matrices. Falling ",
                      "back to type='poscounts' (geometric mean over positive counts only), DESeq2's own ",
                      "documented estimator for sparse count data."),
               conditionMessage(e))
      estimateSizeFactors(dds, type = "poscounts")
    }
  )
}

#' Likelihood-ratio test against the intercept-only model.
#'
#' A genuinely different question from the Wald contrast run_deseq performs,
#' not a variant of it. The Wald test asks "does level B differ from level A",
#' and with three or more groups it answers about two of them while ignoring
#' the rest. The LRT compares the full model (~ group) against ~ 1 and asks
#' "does this feature respond to the grouping variable AT ALL", which is the
#' question a gradient design (control / moderate / polluted) is actually
#' built to answer -- see Love, Huber & Anders 2014 (Genome Biol 15:550) and
#' DESeq2's own vignette section on likelihood ratio tests.
#'
#' Deliberately a separate function rather than a flag on run_deseq: what
#' comes out is not comparable. results() after an LRT still carries a
#' log2FoldChange column, but it belongs to one arbitrary coefficient of the
#' full model, NOT to the effect the test measured. Anything that filters or
#' plots on that column is silently reporting something other than what it
#' claims, which is why the LRT gets its own analysis and its own figure
#' instead of a toggle on the Wald one.
#' Takes an already-built DESeqDataSet rather than raw counts: the caller is
#' better placed to build it (phyloseq analyses go through
#' phyloseq_to_deseq2, which handles the otu_table/sample_data conversion and
#' its orientation; count-matrix analyses build theirs directly), and
#' duplicating that here just reintroduces the conversion bugs those helpers
#' exist to avoid.
run_deseq_lrt <- function(dds, group_var, reduced = ~ 1) {
  n_levels <- nlevels(factor(colData(dds)[[group_var]]))
  if (n_levels < 2) {
    stop(sprintf("'%s' has only %d level -- there is nothing to test.", group_var, n_levels))
  }
  # The LRT earns its keep from THREE levels up; with exactly two it is
  # asymptotically the same test as the Wald contrast, and the pairwise
  # analysis additionally reports the effect size. Said plainly rather than
  # silently producing a redundant figure.
  if (n_levels == 2) {
    log_line(paste0("[deseq_helpers] '%s' has only 2 levels -- the LRT here answers the same question ",
                    "as the pairwise test, which also gives you the fold change. Consider that instead."),
             group_var)
  }

  dds <- dds[rowSums(counts(dds)) > 0, ]
  dds <- .size_factors(dds)
  tryCatch(
    DESeq(dds, test = "LRT", reduced = reduced, quiet = TRUE),
    error = function(e) {
      log_line("[deseq_helpers] parametric dispersion fit failed under LRT (%s) -- falling back to gene-wise estimates.",
               conditionMessage(e))
      dds <- .size_factors(dds)
      dds <- estimateDispersionsGeneEst(dds)
      dispersions(dds) <- mcols(dds)$dispGeneEst
      nbinomLRT(dds, reduced = reduced, quiet = TRUE)
    }
  )
}

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

  dds <- .size_factors(dds)

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
      dds <- .size_factors(dds)
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
