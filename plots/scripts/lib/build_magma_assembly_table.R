# Builds MAGMA's per-sample assembly-quality table for the Plots tab.
#
# Same real transposed_report.tsv shape and column names already verified
# for SIGMA's own .read_quast (build_sigma_table.R) -- QUAST/MetaQuast always
# writes both report.tsv (metrics as rows) and transposed_report.tsv
# (assemblies as rows, one per file since each sample's MetaQuast run only
# ever assembles that one sample); the transposed form is the one that reads
# directly into a data.frame without pivoting.

suppressMessages({
  library(dplyr)
})

#' `variant`: "metaquast" (the full assembly, every domain) or
#' "metaquast_prokaryotic" (after Tiara's eukaryote/organelle filter --
#' see 02_assembly.smk's filter_prokaryotes) -- both real, both worth
#' showing, since the gap between them is itself informative (how much of
#' the assembly Tiara flagged as non-prokaryotic).
.read_metaquast <- function(results_dir, sample, variant) {
  path <- file.path(results_dir, "02_ASSEMBLY", sample, variant, "transposed_report.tsv")
  if (!file.exists(path)) return(NULL)
  df <- try(read.delim(path, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  row <- df[1, , drop = FALSE]
  data.frame(
    sample = sample, variant = variant,
    num_contigs = suppressWarnings(as.integer(row[["# contigs"]])),
    total_length = suppressWarnings(as.numeric(row[["Total length"]])),
    largest_contig = suppressWarnings(as.numeric(row[["Largest contig"]] %||% NA)),
    gc_pct = suppressWarnings(as.numeric(row[["GC (%)"]])),
    n50 = suppressWarnings(as.numeric(row[["N50"]])),
    l50 = suppressWarnings(as.integer(row[["L50"]] %||% NA)),
    stringsAsFactors = FALSE
  )
}

#' One row per sample x variant (full assembly, prokaryotic-filtered).
build_magma_assembly_table <- function(results_dir, samples) {
  parts <- list()
  for (s in samples) {
    for (v in c("metaquast", "metaquast_prokaryotic")) {
      row <- .read_metaquast(results_dir, s, v)
      if (!is.null(row)) parts[[length(parts) + 1]] <- row
    }
  }
  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}
