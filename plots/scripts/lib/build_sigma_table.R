# Merges SIGMA's real per-genome, per-tool output files (QUAST, CheckM2,
# GTDB-Tk, CoverM, MLST, AMRFinderPlus, ABRicate) into ONE dense per-genome
# summary table (unlike DOGMA's sparse per-ORF long table -- these tools
# each report exactly one summary row per genome, no LEFT JOIN needed for
# the dense part) plus a separate sparse long "gene hits" table (AMR/
# virulence gene presence, naturally 0+ hits per genome).
#
# Real column shapes (exact file formats) confirmed # against SIGMA's own pinned tool versions' real source code -- see the
# dated Plots-tab entry in notes/Known Issues and Next Steps.md for the
# full verification trail. One load-bearing gotcha found this way, driving
# this whole file's design: QUAST's own "Assembly" column and CoverM's own
# "Genome" column are BOTH always the literal string "final_polished"
# (SIGMA never passes --labels/-L, and every sample's fasta is named
# identically before being handed to these tools) -- so neither can be used
# as a join key. Every table here is instead keyed by the real {sample}
# path segment discovered from the results/ directory structure itself,
# never by a tool's own internal "which genome is this" column.
suppressMessages({
  library(dplyr)
})

#' Discovers every real sample this SIGMA run has, from CheckM2's own real
# per-sample output directory (guaranteed to exist for every sample that
# reached the quality stage -- earlier than QUAST alphabetically doesn't
# matter here, CheckM2's `Name` column is also the one tool of the three
# "dense" ones whose own internal identity column IS reliable, since
# `checkm2 predict` names the row after the input filename it was actually
# given, `{sample}.fa`)..discover_sigma_samples <- function(results_dir) {
  checkm2_reports <- list.files(file.path(results_dir, "05_QUALITY"), pattern = "^quality_report\\.tsv$", recursive = TRUE, full.names = TRUE)
  if (length(checkm2_reports) == 0) {
    stop(sprintf("No results/05_QUALITY/*/checkm2/quality_report.tsv files found under %s -- has this SIGMA run reached the genome-quality stage at all?", results_dir))
  }
  # Path shape: results/05_QUALITY/{sample}/checkm2/quality_report.tsv
  rel <- sub(paste0("^", file.path(results_dir, "05_QUALITY"),.Platform$file.sep), "", checkm2_reports)
  vapply(strsplit(rel,.Platform$file.sep, fixed = TRUE), `[`, character(1), 1)
}

#' QUAST's transposed_report.tsv -- metrics as columns, one row (this
#' sample's only assembly). Real column names confirmed from QUAST 5.3.0's
#' own reporting.py Fields class -- "# contigs"/"Total length" (bare, no
#' size threshold) are real, distinct strings from the thresholded variants
#' ("# contigs (>= 1000 bp)",...), so exact-name lookup is unambiguous..read_quast <- function(results_dir, sample) {
  path <- file.path(results_dir, "05_QUALITY", sample, "quast", "transposed_report.tsv")
  if (!file.exists(path)) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]  # always exactly one assembly; row's own "Assembly" value is NOT the sample name, ignore it
  data.frame(
    sample = sample,
    quast_num_contigs = suppressWarnings(as.integer(row"# contigs")),
    quast_total_length = suppressWarnings(as.numeric(row"Total length")),
    quast_largest_contig = suppressWarnings(as.numeric(row"Largest contig")),
    quast_gc_pct = suppressWarnings(as.numeric(row"GC (%)")),
    quast_n50 = suppressWarnings(as.numeric(row"N50")),
    quast_l50 = suppressWarnings(as.integer(row"L50")),
    stringsAsFactors = FALSE
  )
}

#' CheckM2's quality_report.tsv -- real 14-column v1.1.0 schema (`auto`
#' mode, no --debug_cos). `Name` is a reliable join key here (unlike QUAST/
#' CoverM) but the sample-derived id is used regardless, for consistency..read_checkm2 <- function(results_dir, sample) {
  path <- file.path(results_dir, "05_QUALITY", sample, "checkm2", "quality_report.tsv")
  if (!file.exists(path)) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]
  data.frame(
    sample = sample,
    checkm2_completeness = suppressWarnings(as.numeric(row"Completeness")),
    checkm2_contamination = suppressWarnings(as.numeric(row"Contamination")),
    checkm2_genome_size = suppressWarnings(as.numeric(row"Genome_Size")),
    checkm2_gc_content = suppressWarnings(as.numeric(row"GC_Content")),
    checkm2_coding_sequences = suppressWarnings(as.integer(row"Total_Coding_Sequences")),
    stringsAsFactors = FALSE
  )
}

# Real 7-rank GTDB naming, same convention build_phyloseq.R already
# established for MAGMA/PRISM's own GTDB-style lineage strings..GTDB_RANK_COLS <- c("Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species")

#' GTDB-Tk writes exactly ONE of gtdbtk.bac120.summary.tsv /
#' gtdbtk.ar53.summary.tsv per single-genome classify_wf run (confirmed
#' real behavior) -- check both, use whichever exists.
#' `classification` is the real full 'd__...;p__...;...;s__...' lineage
#' string; `user_genome` is NOT used as the join key (same
#' don't-trust-the-tool's-own-identity-column caution as QUAST/CoverM,
#' even though it likely IS reliable here since SIGMA copies the genome in
#' as `{sample}.fa` -- consistency over assuming)..read_gtdbtk <- function(results_dir, sample) {
  gtdbtk_dir <- file.path(results_dir, "06_TAXONOMY", sample, "gtdbtk")
  candidates <- c(file.path(gtdbtk_dir, "gtdbtk.bac120.summary.tsv"), file.path(gtdbtk_dir, "gtdbtk.ar53.summary.tsv"))
  path <- candidates[file.exists(candidates)]
  if (length(path) == 0) return(NULL)
  df <- read.delim(path[1], header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]
  lineage <- as.character(row"classification")
  ranks <- strsplit(lineage, ";", fixed = TRUE)1
  ranks <- c(ranks, rep(NA_character_, length(.GTDB_RANK_COLS) - length(ranks)))[seq_along(.GTDB_RANK_COLS)]
  # Strip the d__/p__/.../s__ rank prefixes for readable columns (kept in
  # the raw `gtdbtk_lineage` field below for anyone who wants the original).
  ranks_clean <- sub("^[a-z]__", "", ranks)
  out <- as.data.frame(as.list(setNames(ranks_clean, paste0("gtdbtk_", tolower(.GTDB_RANK_COLS)))), stringsAsFactors = FALSE)
  out$sample <- sample
  out$gtdbtk_lineage <- lineage
  out$gtdbtk_domain_file <- basename(path[1])  # which of bac120/ar53 actually matched -- real, useful provenance
  out[, c("sample", "gtdbtk_lineage", "gtdbtk_domain_file", paste0("gtdbtk_", tolower(.GTDB_RANK_COLS))), drop = FALSE]
}

#' CoverM's own real header bakes the sample name into every non-"Genome"
#' column ("{sample} Trimmed Mean" etc, space-separated, Title Case) -- read
#' generically by column-name SUFFIX match rather than assuming a fixed
#' position, and never trust the "Genome" column's own value (same
#' "final_polished" collision QUAST has)..read_coverm <- function(results_dir, sample) {
  path <- file.path(results_dir, "07_COVERAGE", sample, "coverm_coverage.tsv")
  if (!file.exists(path)) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]
  find_col <- function(suffix) {
    hit <- grep(paste0(suffix, "$"), colnames(row), value = TRUE)
    if (length(hit) == 0) return(NA_real_)
    suppressWarnings(as.numeric(rowhit[1]))
  }
  data.frame(
    sample = sample,
    coverm_mean = find_col("Mean"),
    coverm_trimmed_mean = find_col("Trimmed Mean"),
    coverm_covered_fraction = find_col("Covered Fraction"),
    stringsAsFactors = FALSE
  )
}

#' MLST's real output has NO header and a RAGGED number of trailing allele
#' columns (varies by which PubMLST scheme matched, confirmed real) -- only
#' the first 3 fixed fields (FILE, SCHEME, ST) are read here; the allele
#' calls themselves aren't needed for a summary table. An unmatched genome
#' reports literal "-" for both SCHEME and ST (confirmed real, not merely
#' "missing"), kept as-is rather than recoded to NA -- it's a real,
#' meaningful result ("no scheme matched"), not an absence of data..read_mlst <- function(results_dir, sample) {
  path <- file.path(results_dir, "09_TYPING", sample, "mlst.tsv")
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  line <- readLines(path, n = 1)
  fields <- strsplit(line, "\t", fixed = TRUE)1
  data.frame(
    sample = sample,
    mlst_scheme = if (length(fields) >= 2) fields[2] else NA_character_,
    mlst_st = if (length(fields) >= 3) fields[3] else NA_character_,
    stringsAsFactors = FALSE
  )
}

#' Builds the dense, one-row-per-genome summary table across every sample
#' this SIGMA run has -- LEFT JOINs (not inner) so a genome missing one
#' optional tool's output (e.g. GTDB-Tk still running, or intentionally
#' disabled) still keeps its row from every other tool.
#' @param results_dir Path to a SIGMA run's `results/` directory.
build_sigma_table <- function(results_dir) {
  samples <-.discover_sigma_samples(results_dir)
  log_line("build_sigma_table: %d genome(s) discovered", length(samples))

  readers <- list(.read_quast,.read_checkm2,.read_gtdbtk,.read_coverm,.read_mlst)
  summary_df <- data.frame(sample = samples, stringsAsFactors = FALSE)
  for (reader in readers) {
    parts <- Filter(Negate(is.null), lapply(samples, function(s) reader(results_dir, s)))
    if (length(parts) > 0) {
      summary_df <- left_join(summary_df, bind_rows(parts), by = "sample")
    }
  }
  summary_df
}

# --- Sparse gene-hit long table (AMR/virulence) ----------------------------- #' AMRFinderPlus's real 22-column schema, confirmed against the actual
#' installed 4.2.7 binary's own strings (real column names differ from
#' older AMRFinderPlus releases -- e.g. "Element symbol"/"Element name",
#' not "Gene symbol"/"Sequence name" -- a real version-drift correction,
#' not a stylistic choice). `--plus` (always passed) does NOT add columns,
#' only broadens which genes are searched..read_amrfinder <- function(results_dir, sample) {
  path <- file.path(results_dir, "08_ANNOTATION", sample, "amrfinder", "amrfinder_results.tsv")
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample, source = "amrfinder",
    gene = df"Element symbol", product = df"Element name",
    class = df"Class", subclass = df"Subclass",
    pct_identity = suppressWarnings(as.numeric(df"% Identity to reference")),
    pct_coverage = suppressWarnings(as.numeric(df"% Coverage of reference")),
    stringsAsFactors = FALSE
  )
}

#' ABRicate's real 15-column schema (header literally starts "#FILE") --
#' shared by all 3 real invocations SIGMA makes (ncbi/card/vfdb databases).
#' A header-only (zero-hit) file is real, valid ABRicate behavior (the
#' header prints unconditionally before any per-hit rows) -- not an error..read_abricate <- function(results_dir, sample, db_label, rel_path) {
  path <- file.path(results_dir, "08_ANNOTATION", sample, rel_path)
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample, source = paste0("abricate_", db_label),
    gene = df"GENE", product = df"PRODUCT",
    class = df"RESISTANCE", subclass = NA_character_,
    pct_identity = suppressWarnings(as.numeric(df"%IDENTITY")),
    pct_coverage = suppressWarnings(as.numeric(df"%COVERAGE")),
    stringsAsFactors = FALSE
  )
}

#' Long, sparse table: one row per AMR/virulence gene HIT (0+ per genome,
#' across AMRFinderPlus + ABRicate's 3 real databases), for presence/
#' absence-style analyses (e.g. an AMR gene heatmap across genomes) --
#' deliberately kept separate from the dense genome-summary table above
#' (different granularity: one row per genome vs. one row per hit).
build_sigma_gene_hits <- function(results_dir) {
  samples <-.discover_sigma_samples(results_dir)
  parts <- list
  for (s in samples) {
    partslength(parts) + 1 <-.read_amrfinder(results_dir, s)
    partslength(parts) + 1 <-.read_abricate(results_dir, s, "ncbi", file.path("abricate", "ncbi_results.tab"))
    partslength(parts) + 1 <-.read_abricate(results_dir, s, "card", file.path("abricate", "card_results.tab"))
    partslength(parts) + 1 <-.read_abricate(results_dir, s, "vfdb", file.path("vfdb", "vfdb_results.tab"))
  }
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) {
    return(data.frame(sample = character(0), source = character(0), gene = character(0),
                       product = character(0), class = character(0), subclass = character(0),
                       pct_identity = numeric(0), pct_coverage = numeric(0), stringsAsFactors = FALSE))
  }
  bind_rows(parts)
}
