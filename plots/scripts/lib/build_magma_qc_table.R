# Builds MAGMA's before/after read-cleaning QC table for the Plots tab.
#
# MAGMA can run short-read (fastp), long-read (filtlong + NanoPlot), or
# hybrid samples in the same run (see 01_qc_tax.smk's read_type-branched
# fastp/filtlong rules) -- a sample gets whichever of the two QC tools
# actually apply to it, never both. Long rows (one metric per sample per
# stage) rather than wide, since short- and long-read samples report
# different metric sets and forcing them into the same columns would leave
# most cells empty either way.

suppressMessages({
  library(dplyr)
})

#' fastp's real JSON shape (confirmed against the tool's own documented
#' output): top-level "summary" object with "before_filtering"/
#' "after_filtering" sub-objects, each carrying total_reads, total_bases,
#' q30_rate, gc_content. A sample whose fastp ran via the touch-only fallback
#' (pure long-read, see 01_qc_tax.smk) writes a zero-byte JSON that
#' jsonlite::fromJSON can't parse -- skipped rather than erroring the whole
#' table, since that's a real, expected shape for that sample's read type.
.read_fastp <- function(results_dir, samples) {
  parts <- list()
  for (s in samples) {
    f <- file.path(results_dir, "01_QC", s, paste0(s, "_fastp.json"))
    if (!file.exists(f) || file.size(f) == 0) next
    j <- try(jsonlite::fromJSON(f), silent = TRUE)
    if (inherits(j, "try-error") || is.null(j$summary)) next
    for (stage in c("before_filtering", "after_filtering")) {
      st <- j$summary[[stage]]
      if (is.null(st)) next
      parts[[length(parts) + 1]] <- data.frame(
        sample = s, tool = "fastp", stage = sub("_filtering$", "", stage),
        total_reads = suppressWarnings(as.numeric(st$total_reads %||% NA)),
        total_bases = suppressWarnings(as.numeric(st$total_bases %||% NA)),
        q30_rate = suppressWarnings(as.numeric(st$q30_rate %||% NA)),
        gc_content = suppressWarnings(as.numeric(st$gc_content %||% NA)),
        mean_length = NA_real_, n50 = NA_real_,
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}

#' NanoPlot's NanoStats.txt: a plain "General summary" text report, not a
#' delimited table -- fields appear as "Metric:<tab/spaces>value" lines.
#' Real field names as documented by NanoPlot: "Mean read length",
#' "Mean read quality", "Number of reads", "Total bases", "Read length N50".
#' Values often carry thousands separators (","), stripped before parsing.
#'
#' NOT yet checked against a real NanoPlot run -- the field-name spelling is
#' from NanoPlot's own documented summary format, not a captured real file.
#' A field that isn't found is left NA rather than guessed.
.read_nanostats <- function(results_dir, samples) {
  parts <- list()
  for (s in samples) {
    for (stage in c("raw", "clean")) {
      f <- file.path(results_dir, "01_QC", s, paste0("nanoplot_", stage), "NanoStats.txt")
      if (!file.exists(f)) next
      lines <- try(readLines(f, warn = FALSE), silent = TRUE)
      if (inherits(lines, "try-error") || length(lines) == 0) next
      get_field <- function(name) {
        hit <- grep(paste0("^", name, ":"), lines, value = TRUE)
        if (length(hit) == 0) return(NA_real_)
        raw <- trimws(sub("^[^:]+:", "", hit[1]))
        suppressWarnings(as.numeric(gsub(",", "", raw)))
      }
      parts[[length(parts) + 1]] <- data.frame(
        sample = s, tool = "nanoplot", stage = if (stage == "raw") "before" else "after",
        total_reads = get_field("Number of reads"), total_bases = get_field("Total bases"),
        q30_rate = NA_real_, gc_content = NA_real_,
        mean_length = get_field("Mean read length"), n50 = get_field("Read length N50"),
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}

#' Long QC table: one row per sample x tool x stage(before/after). A sample
#' contributes fastp rows, NanoPlot rows, or both, depending on which QC tool
#' actually ran for its read type.
build_magma_qc_table <- function(results_dir, samples) {
  parts <- list(.read_fastp(results_dir, samples), .read_nanostats(results_dir, samples))
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) return(NULL)
  df <- bind_rows(parts)
  df$stage <- factor(df$stage, levels = c("before", "after"))
  df[order(df$sample, df$tool, df$stage), , drop = FALSE]
}
