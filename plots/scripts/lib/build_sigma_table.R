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
# given, `{sample}.fa`).
.discover_sigma_samples <- function(results_dir) {
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
#' ("# contigs (>= 1000 bp)",...), so exact-name lookup is unambiguous.
.read_quast <- function(results_dir, sample) {
  path <- file.path(results_dir, "05_QUALITY", sample, "quast", "transposed_report.tsv")
  if (!file.exists(path)) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]  # always exactly one assembly; row's own "Assembly" value is NOT the sample name, ignore it
  data.frame(
    sample = sample,
    quast_num_contigs = suppressWarnings(as.integer(row[["# contigs"]])),
    quast_total_length = suppressWarnings(as.numeric(row[["Total length"]])),
    quast_largest_contig = suppressWarnings(as.numeric(row[["Largest contig"]])),
    quast_gc_pct = suppressWarnings(as.numeric(row[["GC (%)"]])),
    quast_n50 = suppressWarnings(as.numeric(row[["N50"]])),
    quast_l50 = suppressWarnings(as.integer(row[["L50"]])),
    stringsAsFactors = FALSE
  )
}

#' CheckM2's quality_report.tsv -- real 14-column v1.1.0 schema (`auto`
#' mode, no --debug_cos). `Name` is a reliable join key here (unlike QUAST/
#' CoverM) but the sample-derived id is used regardless, for consistency.
.read_checkm2 <- function(results_dir, sample) {
  path <- file.path(results_dir, "05_QUALITY", sample, "checkm2", "quality_report.tsv")
  if (!file.exists(path)) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]
  data.frame(
    sample = sample,
    checkm2_completeness = suppressWarnings(as.numeric(row[["Completeness"]])),
    checkm2_contamination = suppressWarnings(as.numeric(row[["Contamination"]])),
    checkm2_genome_size = suppressWarnings(as.numeric(row[["Genome_Size"]])),
    checkm2_gc_content = suppressWarnings(as.numeric(row[["GC_Content"]])),
    checkm2_coding_sequences = suppressWarnings(as.integer(row[["Total_Coding_Sequences"]])),
    stringsAsFactors = FALSE
  )
}

# Real 7-rank GTDB naming, same convention build_phyloseq.R already
# established for MAGMA/PRISM's own GTDB-style lineage strings.
.GTDB_RANK_COLS <- c("Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species")

#' GTDB-Tk writes exactly ONE of gtdbtk.bac120.summary.tsv /
#' gtdbtk.ar53.summary.tsv per single-genome classify_wf run (confirmed
#' real behavior) -- check both, use whichever exists.
#' `classification` is the real full 'd__...;p__...;...;s__...' lineage
#' string; `user_genome` is NOT used as the join key (same
#' don't-trust-the-tool's-own-identity-column caution as QUAST/CoverM,
#' even though it likely IS reliable here since SIGMA copies the genome in
#' as `{sample}.fa` -- consistency over assuming).
.read_gtdbtk <- function(results_dir, sample) {
  gtdbtk_dir <- file.path(results_dir, "06_TAXONOMY", sample, "gtdbtk")
  candidates <- c(file.path(gtdbtk_dir, "gtdbtk.bac120.summary.tsv"), file.path(gtdbtk_dir, "gtdbtk.ar53.summary.tsv"))
  path <- candidates[file.exists(candidates)]
  if (length(path) == 0) return(NULL)
  df <- read.delim(path[1], header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]
  lineage <- as.character(row[["classification"]])
  ranks <- strsplit(lineage, ";", fixed = TRUE)[[1]]
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
#' "final_polished" collision QUAST has).
.read_coverm <- function(results_dir, sample) {
  path <- file.path(results_dir, "07_COVERAGE", sample, "coverm_coverage.tsv")
  if (!file.exists(path)) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  row <- df[1,, drop = FALSE]
  find_col <- function(suffix) {
    hit <- grep(paste0(suffix, "$"), colnames(row), value = TRUE)
    if (length(hit) == 0) return(NA_real_)
    suppressWarnings(as.numeric(row[[hit[1]]]))
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
#' meaningful result ("no scheme matched"), not an absence of data.
.read_mlst <- function(results_dir, sample) {
  path <- file.path(results_dir, "09_TYPING", sample, "mlst.tsv")
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  line <- readLines(path, n = 1)
  fields <- strsplit(line, "\t", fixed = TRUE)[[1]]
  data.frame(
    sample = sample,
    mlst_scheme = if (length(fields) >= 2) fields[2] else NA_character_,
    mlst_st = if (length(fields) >= 3) fields[3] else NA_character_,
    stringsAsFactors = FALSE
  )
}

#' GUNC's own maxCSS_level.tsv, the same 13-column shape build_magma_mag_table.R
#' already reads and whose format was verified there -- SIGMA writes it per
#' genome under 05_QUALITY/{sample}/gunc/ instead of MAGMA's per-MAG location,
#' so only the path differs.
#'
#' GUNC answers a question CheckM2 structurally cannot: CheckM2 measures
#' completeness and contamination from single-copy marker genes, which a
#' CHIMERIC assembly can satisfy perfectly while still being two organisms
#' spliced together. GUNC instead asks whether the genome's genes agree on one
#' lineage (Orakov et al. 2021, Genome Biol 22:178, doi:10.1186/s13059-021-02393-0).
#' Reported alongside CheckM2, never folded into it -- they are independent
#' checks, and a genome can pass one and fail the other.
.read_gunc <- function(results_dir, sample) {
  gunc_dir <- file.path(results_dir, "05_QUALITY", sample, "gunc")
  if (!dir.exists(gunc_dir)) return(NULL)
  reports <- list.files(gunc_dir, pattern = "maxCSS_level\\.tsv$", recursive = TRUE, full.names = TRUE)
  if (length(reports) == 0) return(NULL)
  df <- try(read.delim(reports[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample,
    gunc_pass = as.logical(df[["pass.GUNC"]] %||% NA),
    gunc_css = suppressWarnings(as.numeric(df[["clade_separation_score"]] %||% NA)),
    gunc_contamination_portion = suppressWarnings(as.numeric(df[["contamination_portion"]] %||% NA)),
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

  readers <- list(.read_quast,.read_checkm2,.read_gunc,.read_gtdbtk,.read_coverm,.read_mlst)
  summary_df <- data.frame(sample = samples, stringsAsFactors = FALSE)
  for (reader in readers) {
    parts <- Filter(Negate(is.null), lapply(samples, function(s) reader(results_dir, s)))
    if (length(parts) > 0) {
      summary_df <- left_join(summary_df, bind_rows(parts), by = "sample")
    }
  }
  summary_df
}

# --- Sparse gene-hit long table (AMR/virulence) -----------------------------
#' AMRFinderPlus's real 22-column schema, confirmed against the actual
#' installed 4.2.7 binary's own strings (real column names differ from
#' older AMRFinderPlus releases -- e.g. "Element symbol"/"Element name",
#' not "Gene symbol"/"Sequence name" -- a real version-drift correction,
#' not a stylistic choice). `--plus` (always passed) does NOT add columns,
#' only broadens which genes are searched.
.read_amrfinder <- function(results_dir, sample) {
  path <- file.path(results_dir, "08_ANNOTATION", sample, "amrfinder", "amrfinder_results.tsv")
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample, source = "amrfinder",
    # Real contig this hit sits on -- the join key for asking whether a
    # resistance gene is on a plasmid. See .read_mobsuite_contigs below for
    # why it must be cut at the first space before joining.
    contig = as.character(df[["Contig id"]]),
    # Coordinates, for placing the hit on the genome ring. AMRFinder's columns
    # are "Start"/"Stop"; ABRicate's are "START"/"END" (both 1-based, and both
    # report START < END regardless of strand).
    start = suppressWarnings(as.numeric(df[["Start"]])),
    end = suppressWarnings(as.numeric(df[["Stop"]])),
    gene = df[["Element symbol"]], product = df[["Element name"]],
    class = df[["Class"]], subclass = df[["Subclass"]],
    pct_identity = suppressWarnings(as.numeric(df[["% Identity to reference"]])),
    pct_coverage = suppressWarnings(as.numeric(df[["% Coverage of reference"]])),
    stringsAsFactors = FALSE
  )
}

#' ABRicate's real 15-column schema (header literally starts "#FILE") --
#' shared by all 3 real invocations SIGMA makes (ncbi/card/vfdb databases).
#' A header-only (zero-hit) file is real, valid ABRicate behavior (the
#' header prints unconditionally before any per-hit rows) -- not an error.
.read_abricate <- function(results_dir, sample, db_label, rel_path) {
  path <- file.path(results_dir, "08_ANNOTATION", sample, rel_path)
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  df <- read.delim(path, header = TRUE, check.names = FALSE)
  if (nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample, source = paste0("abricate_", db_label),
    contig = as.character(df[["SEQUENCE"]]),
    start = suppressWarnings(as.numeric(df[["START"]])),
    end = suppressWarnings(as.numeric(df[["END"]])),
    gene = df[["GENE"]], product = df[["PRODUCT"]],
    class = df[["RESISTANCE"]], subclass = NA_character_,
    pct_identity = suppressWarnings(as.numeric(df[["%IDENTITY"]])),
    pct_coverage = suppressWarnings(as.numeric(df[["%COVERAGE"]])),
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
  parts <- list()
  for (s in samples) {
    parts[[length(parts) + 1]] <-.read_amrfinder(results_dir, s)
    parts[[length(parts) + 1]] <-.read_abricate(results_dir, s, "ncbi", file.path("abricate", "ncbi_results.tab"))
    parts[[length(parts) + 1]] <-.read_abricate(results_dir, s, "card", file.path("abricate", "card_results.tab"))
    parts[[length(parts) + 1]] <-.read_abricate(results_dir, s, "vfdb", file.path("vfdb", "vfdb_results.tab"))
  }
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) {
    return(data.frame(sample = character(0), source = character(0), contig = character(0),
                       start = numeric(0), end = numeric(0), gene = character(0),
                       product = character(0), class = character(0), subclass = character(0),
                       pct_identity = numeric(0), pct_coverage = numeric(0), stringsAsFactors = FALSE))
  }
  bind_rows(parts)
}

# --- Mobilome: plasmids (MOB-suite), prophages (CheckV/geNomad), IS (ISEScan) --
#
# Every column name and literal value below was read from the tool's own source
# code, not its documentation -- see docs/tool_output_samples/VERIFIED_FORMATS.md
# for the exact file and line of each, so this can be rechecked when a tool
# version changes.

#' First whitespace-delimited token of a sequence identifier.
#'
#' Load-bearing, not cosmetic. MOB-suite rewrites the assembly's FASTA headers
#' internally and maps them back using `record.description` (mob-suite's
#' utils.py:837) -- the WHOLE header line, description included. AMRFinderPlus
#' ("Contig id") and ABRicate ("SEQUENCE") report the first token instead.
#'
#' On an assembly whose headers carry a description (several assemblers emit
#' those), joining the two tables on the raw strings matches NOTHING, and the
#' "is this resistance gene on a plasmid" figure would come out empty with no
#' error at all -- silent and plausible, the worst failure mode available.
#' Both sides are cut to the first token so the join is on the same thing.
.first_token <- function(x) sub("[[:space:]].*$", "", as.character(x))

#' MOB-suite's per-contig report: which contigs are plasmid and which are
#' chromosome. `molecule_type` is literally "chromosome" or "plasmid"
#' (mob_recon.py:669-700); `predicted_mobility` is "conjugative",
#' "mobilizable" or "non-mobilizable" (mob_typer.py:530-534).
#'
#' mob_recon writes contig_report.txt, or {prefix}.contig_report.txt when a
#' --prefix was passed (mob_recon.py:1007-1009) -- matched by suffix so both
#' work.
.read_mobsuite_contigs <- function(results_dir, sample) {
  dir_mob <- file.path(results_dir, "08_ANNOTATION", sample, "mobsuite")
  if (!dir.exists(dir_mob)) return(NULL)
  hits <- list.files(dir_mob, pattern = "contig_report\\.txt$", full.names = TRUE)
  if (length(hits) == 0) return(NULL)
  df <- try(read.delim(hits[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0 || !("molecule_type" %in% colnames(df))) return(NULL)
  data.frame(
    sample = sample,
    contig = .first_token(df$contig_id),
    molecule_type = as.character(df$molecule_type),
    plasmid_cluster = as.character(df[["primary_cluster_id"]] %||% NA),
    circularity = as.character(df[["circularity_status"]] %||% NA),
    rep_types = as.character(df[["rep_type(s)"]] %||% NA),
    predicted_mobility = as.character(df[["predicted_mobility"]] %||% NA),
    stringsAsFactors = FALSE
  )
}

#' MOB-suite's per-plasmid report (one row per reconstructed plasmid).
#' Same directory, same --prefix rule (mob_recon.py:1397-1399).
.read_mobtyper <- function(results_dir, sample) {
  dir_mob <- file.path(results_dir, "08_ANNOTATION", sample, "mobsuite")
  if (!dir.exists(dir_mob)) return(NULL)
  hits <- list.files(dir_mob, pattern = "mobtyper_results\\.txt$", full.names = TRUE)
  if (length(hits) == 0) return(NULL)
  df <- try(read.delim(hits[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample,
    plasmid_cluster = as.character(df[["primary_cluster_id"]] %||% NA),
    size = suppressWarnings(as.numeric(df[["size"]] %||% NA)),
    gc = suppressWarnings(as.numeric(df[["gc"]] %||% NA)),
    rep_types = as.character(df[["rep_type(s)"]] %||% NA),
    relaxase_types = as.character(df[["relaxase_type(s)"]] %||% NA),
    predicted_mobility = as.character(df[["predicted_mobility"]] %||% NA),
    host_range = as.character(df[["predicted_host_range_overall_name"]] %||% NA),
    stringsAsFactors = FALSE
  )
}

#' CheckV's quality_summary.tsv (quality_summary.py:146-161). checkv_quality is
#' one of five ORDERED categories -- Complete, High-quality, Medium-quality,
#' Low-quality, Not-determined (quality_summary.py:129-142) -- so it must be a
#' factor with those levels, not sorted alphabetically.
CHECKV_QUALITY_LEVELS <- c("Complete", "High-quality", "Medium-quality", "Low-quality", "Not-determined")

.read_checkv <- function(results_dir, sample) {
  f <- file.path(results_dir, "10_VIRAL", sample, "checkv", "quality_summary.tsv")
  if (!file.exists(f) || file.size(f) == 0) return(NULL)
  df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample,
    contig = .first_token(df$contig_id),
    contig_length = suppressWarnings(as.numeric(df$contig_length)),
    provirus = as.character(df[["provirus"]] %||% NA),
    checkv_quality = as.character(df[["checkv_quality"]] %||% NA),
    completeness = suppressWarnings(as.numeric(df[["completeness"]] %||% NA)),
    viral_genes = suppressWarnings(as.integer(df[["viral_genes"]] %||% NA)),
    host_genes = suppressWarnings(as.integer(df[["host_genes"]] %||% NA)),
    stringsAsFactors = FALSE
  )
}

#' geNomad's virus summary (summary.py:670). Its `taxonomy` column is a
#' ';'-separated viral lineage, kept whole -- unlike a prokaryotic lineage it
#' has no fixed rank depth to split on.
.read_genomad_virus <- function(results_dir, sample) {
  dir_g <- file.path(results_dir, "10_VIRAL", sample, "genomad")
  if (!dir.exists(dir_g)) return(NULL)
  hits <- list.files(dir_g, pattern = "_virus_summary\\.tsv$", recursive = TRUE, full.names = TRUE)
  if (length(hits) == 0) return(NULL)
  df <- try(read.delim(hits[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  data.frame(
    sample = sample,
    contig = .first_token(df$seq_name),
    length = suppressWarnings(as.numeric(df[["length"]] %||% NA)),
    topology = as.character(df[["topology"]] %||% NA),
    virus_score = suppressWarnings(as.numeric(df[["virus_score"]] %||% NA)),
    n_hallmarks = suppressWarnings(as.integer(df[["n_hallmarks"]] %||% NA)),
    taxonomy = as.character(df[["taxonomy"]] %||% NA),
    stringsAsFactors = FALSE
  )
}

#' ISEScan writes .csv and .tsv with identical content (pred.py:1129,1131) --
#' the .tsv is read because a comma inside a field cannot break it. Column
#' order from pred.py:728-751; `family` is the IS family (IS3, IS5,
#' IS200/IS605, ...), which is the column worth plotting.
.read_isescan <- function(results_dir, sample) {
  dir_is <- file.path(results_dir, "08_ANNOTATION", sample, "isescan")
  if (!dir.exists(dir_is)) return(NULL)
  hits <- list.files(dir_is, pattern = "\\.tsv$", recursive = TRUE, full.names = TRUE)
  hits <- hits[file.size(hits) > 0]
  if (length(hits) == 0) return(NULL)
  df <- try(read.delim(hits[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0 || !("family" %in% colnames(df))) return(NULL)
  data.frame(
    sample = sample,
    contig = .first_token(df$seqID),
    is_family = as.character(df$family),
    is_cluster = as.character(df[["cluster"]] %||% NA),
    # Coordinates as well as length: the genome ring places each insertion
    # sequence at its real position, which a length alone cannot give.
    is_begin = suppressWarnings(as.numeric(df[["isBegin"]] %||% NA)),
    is_end = suppressWarnings(as.numeric(df[["isEnd"]] %||% NA)),
    is_length = suppressWarnings(as.numeric(df[["isLen"]] %||% NA)),
    stringsAsFactors = FALSE
  )
}

#' Every mobilome table this run has, as one list -- each element NULL when the
#' tool did not run, which is the normal case (all four are optional steps).
build_sigma_mobilome <- function(results_dir) {
  samples <- .discover_sigma_samples(results_dir)
  gather <- function(reader) {
    parts <- Filter(Negate(is.null), lapply(samples, function(s) reader(results_dir, s)))
    if (length(parts) == 0) NULL else bind_rows(parts)
  }
  list(
    contigs  = gather(.read_mobsuite_contigs),
    plasmids = gather(.read_mobtyper),
    checkv   = gather(.read_checkv),
    genomad  = gather(.read_genomad_virus),
    isescan  = gather(.read_isescan)
  )
}

#' BiG-SCAPE's record_annotations.tsv -- one row per BGC region, carrying the
#' antiSMASH product Class and Category (legacy_output.py:382-394, BiG-SCAPE
#' 2.x). Columns: Record, GBK, Record_Type, Record_Number, Class, Category,
#' Organism, Taxonomy, Description.
#'
#' Read from BiG-SCAPE rather than from antiSMASH directly for a concrete
#' reason: antiSMASH writes NO tabular output at all (its outputs/ module is
#' html-only), so the same information would otherwise have to come out of its
#' JSON. BiG-SCAPE already carries Class and Category in a plain TSV.
#'
#' The genome is the directory, not a column: SIGMA runs BiG-SCAPE once per
#' sample over that sample's own gbk_pool (11_secondary_metabolites.smk:19-38).
#'
#' Path shape: 11_BGC/{sample}/bigscape/output_files/{label}_c{cutoff}/record_annotations.tsv
#' -- label and cutoff vary with the run's parameters, so the file is found by
#' name under the sample's own bigscape directory instead of by fixed path.
#' Note BiG-SCAPE's own --db_only_output suppresses these TSVs entirely
#' (legacy_output.py:344-346), leaving only its SQLite; that run has no BGC
#' table here and the analysis says so.
.read_bigscape <- function(results_dir, sample) {
  dir_bs <- file.path(results_dir, "11_BGC", sample, "bigscape")
  if (!dir.exists(dir_bs)) return(NULL)
  hits <- list.files(dir_bs, pattern = "^record_annotations\\.tsv$", recursive = TRUE, full.names = TRUE)
  hits <- hits[file.size(hits) > 0]
  if (length(hits) == 0) return(NULL)
  df <- try(read.delim(hits[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0 || !("Class" %in% colnames(df))) return(NULL)
  data.frame(
    sample = sample,
    record = as.character(df[["Record"]] %||% NA),
    bgc_class = as.character(df$Class),
    bgc_category = as.character(df[["Category"]] %||% NA),
    stringsAsFactors = FALSE
  )
}

#' BiG-SCAPE's clustering file: which gene cluster family each BGC belongs to.
#' Family is written as "FAM_00001" (legacy_output.py:511) and Record is the
#' same key record_annotations.tsv uses, so the two join directly.
.read_bigscape_families <- function(results_dir, sample) {
  dir_bs <- file.path(results_dir, "11_BGC", sample, "bigscape")
  if (!dir.exists(dir_bs)) return(NULL)
  hits <- list.files(dir_bs, pattern = "_clustering_c.*\\.tsv$", recursive = TRUE, full.names = TRUE)
  hits <- hits[file.size(hits) > 0]
  if (length(hits) == 0) return(NULL)
  parts <- lapply(hits, function(f) {
    df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
    if (inherits(df, "try-error") || nrow(df) == 0 || !("Family" %in% colnames(df))) return(NULL)
    data.frame(sample = sample, record = as.character(df$Record),
               family = as.character(df$Family), stringsAsFactors = FALSE)
  })
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) return(NULL)
  distinct(bind_rows(parts), sample, record, .keep_all = TRUE)
}

#' The BGC tables this run has, or NULLs when antiSMASH/BiG-SCAPE did not run.
build_sigma_bgc <- function(results_dir) {
  samples <- .discover_sigma_samples(results_dir)
  gather <- function(reader) {
    parts <- Filter(Negate(is.null), lapply(samples, function(s) reader(results_dir, s)))
    if (length(parts) == 0) NULL else bind_rows(parts)
  }
  list(regions = gather(.read_bigscape), families = gather(.read_bigscape_families))
}
