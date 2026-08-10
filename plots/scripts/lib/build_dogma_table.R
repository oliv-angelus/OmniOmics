# Merges DOGMA's ~10 separate per-tool output files (Salmon, TransDecoder,
# eggNOG-mapper, CAZy, NCycDB/SCycDB/MCycDB, CANT-HYD, FeGenie, EUKulele,
# CAT/BAT, MAGMA Cross-Reference) into one long per-ORF table, per sample x
# domain, across a whole run. This is DOGMA's own explicit, deliberate
# design: see notes/DOGMA.md's "DOGMA's final output shape -- deliberately
# NOT one merged table" section -- the pipeline stops at ~10 separate TSVs
# on purpose ("a bigger, more careful, purpose-built script written at
# analysis time carries less risk than a generic merge baked into the
# pipeline now"), and the user's own explicit call was to do this merge
# here, in R, at the Plots-tab load step -- not inside DOGMA itself.
#
# Real join design (also from DOGMA.md, reused verbatim rather than
# re-derived -- the mechanics were already fully worked out there):
# TransDecoder's own ORF list is the SPINE (every ORF that exists, whether
# annotated or not); every functional-annotation table is a LEFT JOIN onto
# that spine (an ORF with no CAZy hit must still keep its row, or its
# expression silently disappears); Salmon/CAT-BAT are keyed one level up,
# by parent TRANSCRIPT id (strip the trailing ".p{N}" TransDecoder appends),
# and get broadcast across every ORF that transcript contains.
#
# Real column shapes (exact file formats) were confirmed
# by installing DOGMA's own pinned tool versions and
# reading their actual source/output -- see the dated Plots-tab entry in
# notes/Known Issues and Next Steps.md for the full verification trail.
suppressMessages({
  library(dplyr)
  library(tidyr)
  library(phyloseq)
})

# ORF ID -> parent transcript ID: TransDecoder always names ORFs
# "{transcript_id}.p{N}" (confirmed via a real TransDecoder 5.7.1 run,
# DOGMA's own pinned version) -- strip the last ".pN" segment..orf_to_transcript <- function(orf_ids) sub("\\.p[0-9]+$", "", orf_ids)

#' Reads one sample x domain's worth of DOGMA output into one long,
#' ORF-keyed data.frame. Every join below is tolerant of a missing file
#' (that tool/extra simply wasn't active for this run -- its columns are
#' just absent, not NA-filled) and of an empty-but-present file (the tool
#' ran and found zero hits -- same effective result, an empty join)..read_dogma_sample_domain <- function(results_dir, sample, domain) {
  pep_path <- file.path(results_dir, "04_ORF_CALLING", sample, domain, paste0(sample, "_transdecoder.pep"))
  if (!file.exists(pep_path)) return(NULL)

  headers <- grep("^>", readLines(pep_path), value = TRUE)
  if (length(headers) == 0) return(NULL)
  orf_id <- sub("^>(\\S+).*$", "\\1", headers)
  tab <- data.frame(orf_id = orf_id, transcript_id =.orf_to_transcript(orf_id),
                     sample = sample, domain = domain, stringsAsFactors = FALSE)

  ann_dir <- file.path(results_dir, "05_ANNOTATION", sample, domain)

  # --- Salmon (transcript-keyed, dense: every transcript gets a row) ----- quant_path <- file.path(results_dir, "06_QUANTIFICATION", sample, domain, paste0(sample, "_quant"), "quant.sf")
  if (file.exists(quant_path) && file.size(quant_path) > 0) {
    quant <- read.delim(quant_path, header = TRUE, check.names = FALSE)
    quant <- quant %>% transmute(transcript_id = Name, salmon_TPM = TPM, salmon_NumReads = NumReads)
    tab <- left_join(tab, quant, by = "transcript_id")
  }

  # --- eggNOG-mapper (ORF-keyed, sparse) -- '#'-prefixed comment/header
  # lines (1 leading call-info line + the header itself + 3 trailing
  # footer lines), '-' for empty fields kept as-is (not re-coded to NA;
  # harmless, and matches the file's own convention if inspected directly).
  egg_path <- file.path(ann_dir, "eggnog", paste0(sample, "_annotations.emapper.annotations"))
  if (file.exists(egg_path) && file.size(egg_path) > 0) {
    egg_lines <- readLines(egg_path)
    egg_lines <- egg_lines[!grepl("^##", egg_lines)]
    if (length(egg_lines) > 1) {
      egg <- read.delim(text = egg_lines, header = TRUE, check.names = FALSE, comment.char = "")
      colnames(egg)[1] <- "orf_id"  # real header col1 is literally "#query"
      colnames(egg)[-1] <- paste0("eggnog_", colnames(egg)[-1])
      tab <- left_join(tab, egg, by = "orf_id")
    }
  }

  # --- CAZy (dbCAN overview.tsv, ORF-keyed, sparse) ----------------------- cazy_path <- file.path(ann_dir, "cazy", "overview.tsv")
  if (file.exists(cazy_path) && file.size(cazy_path) > 0) {
    cazy <- read.delim(cazy_path, header = TRUE, check.names = FALSE)
    if (nrow(cazy) > 0) {
      colnames(cazy)[1] <- "orf_id"  # real header col1 is "Gene ID"
      colnames(cazy)[-1] <- paste0("cazy_", make.names(colnames(cazy)[-1]))
      tab <- left_join(tab, cazy, by = "orf_id")
    }
  }

  # --- NCycDB / SCycDB / MCycDB (DIAMOND blastp + awk gene-family join,
  # ORF-keyed, sparse, NO header row in the real file) --------------------- for (db in c("ncycdb", "scycdb", "mcycdb")) {
    db_path <- file.path(ann_dir, db, paste0(sample, "_", db, "_annotations.tsv"))
    if (file.exists(db_path) && file.size(db_path) > 0) {
      hits <- read.delim(db_path, header = FALSE, check.names = FALSE,
                          col.names = c("orf_id", "sseqid", "pident", "length", "evalue", "bitscore", "gene"))
      hits <- hits %>% transmute(orf_id, gene = ifelse(gene == "NA", NA_character_, gene))
      colnames(hits)[2] <- paste0(db, "_gene")
      tab <- left_join(tab, hits, by = "orf_id")
    }
  }

  # --- CANT-HYD (HMMER hmmsearch --tblout, ORF-keyed, sparse, whitespace-
  # delimited fixed layout, '#'-prefixed header/footer lines) ------------- canthyd_path <- file.path(ann_dir, "canthyd", paste0(sample, "_canthyd_hmmsearch.tblout"))
  if (file.exists(canthyd_path) && file.size(canthyd_path) > 0) {
    ch_lines <- readLines(canthyd_path)
    ch_lines <- ch_lines[!grepl("^#", ch_lines)]
    if (length(ch_lines) > 0) {
      # First 18 whitespace-delimited fields are fixed; field 19+ is a
      # ragged free-text description, joined back together rather than
      # split further (real HMMER tblout shape, confirmed via a real run).
      parts <- strsplit(trimws(ch_lines), "\\s+")
      canthyd <- data.frame(
        orf_id = vapply(parts, `[`, character(1), 1),
        canthyd_query_name = vapply(parts, `[`, character(1), 3),
        canthyd_evalue = as.numeric(vapply(parts, `[`, character(1), 5)),
        stringsAsFactors = FALSE
      )
      tab <- left_join(tab, canthyd, by = "orf_id")
    }
  }

  # --- FeGenie (ORF-keyed, sparse, real CSV; protein_sequence column
  # dropped -- large/redundant, the ORF's sequence is already in the.pep) -
  fegenie_path <- file.path(ann_dir, "fegenie", "FeGenie-geneSummary.csv")
  if (file.exists(fegenie_path) && file.size(fegenie_path) > 0) {
    fegenie <- read.csv(fegenie_path, check.names = FALSE, stringsAsFactors = FALSE)
    if (nrow(fegenie) > 0) {
      fegenie <- fegenie %>% transmute(orf_id = orf, fegenie_category = category, fegenie_HMM = HMM)
      tab <- left_join(tab, fegenie, by = "orf_id")
    }
  }

  # --- EUKulele (ORF-keyed despite the confusing "transcript_name" column
  # name -- confirmed from source: DOGMA feeds it TransDecoder's.pep, so
  # its per-row ID really is the ORF id). Real file has an extra leading
  # unnamed pandas-index column (to.csv(sep='\t') with no index=False) -- # read.delim already handles a short header row correctly (R recycles
  # the mismatch onto rownames), same idiom already used elsewhere for
  # not-quite-headerful TSVs.
  euk_path <- file.path(ann_dir, "eukulele", "taxonomy_estimation", paste0(sample, "-estimated-taxonomy.out"))
  if (file.exists(euk_path) && file.size(euk_path) > 0) {
    euk <- read.delim(euk_path, header = TRUE, check.names = FALSE, row.names = 1)
    if (nrow(euk) > 0) {
      euk <- euk %>% transmute(orf_id = transcript_name,
                                eukulele_classification = classification,
                                eukulele_full_classification = full_classification)
      tab <- left_join(tab, euk, by = "orf_id")
    }
  }

  # --- CAT/BAT (transcript-keyed, dense; taxid-based lineage, no human-
  # readable names -- DOGMA's rule never runs `CAT_pack add_names`, so
  # `catbat_lineage` here is a real ';'-separated taxid string, not a
  # d__/p__/... string like GTDB-Tk's) ------------------------------------- cat_path <- file.path(ann_dir, "cat", paste0(sample, ".contig2classification.txt"))
  if (file.exists(cat_path) && file.size(cat_path) > 0) {
    catbat <- read.delim(cat_path, header = TRUE, check.names = FALSE)
    colnames(catbat) <- c("transcript_id", "catbat_classification", "catbat_reason", "catbat_lineage", "catbat_lineage_scores")
    tab <- left_join(tab, catbat, by = "transcript_id")
  }

  # --- MAGMA Cross-Reference (optional, ORF-keyed, sparse, NO header) ----- xref_path <- file.path(results_dir, "08_MAGMA_XREF", sample, domain, paste0(sample, "_magma_mag_annotations.tsv"))
  if (file.exists(xref_path) && file.size(xref_path) > 0) {
    xref <- read.delim(xref_path, header = FALSE, check.names = FALSE,
                        col.names = c("orf_id", "sseqid", "pident", "length", "evalue", "bitscore", "mag", "taxonomy"))
    xref <- xref %>% transmute(orf_id, magma_xref_mag = mag, magma_xref_taxonomy = taxonomy)
    tab <- left_join(tab, xref, by = "orf_id")
  }

  tab
}

#' Builds the full long per-ORF table across every sample x domain a DOGMA
#' run actually produced, by discovering them from TransDecoder's own real
#' output directories (the one file every Phase-2-active sample is
#' guaranteed to have) rather than assuming a fixed sample list.
#' @param results_dir Path to a DOGMA run's `results/` directory.
#' @return A single long data.frame, one row per ORF x sample x domain,
#'   columns = orf_id/transcript_id/sample/domain + whichever tool columns
#'   were actually present (prefixed by tool name).
build_dogma_table <- function(results_dir) {
  orf_dir <- file.path(results_dir, "04_ORF_CALLING")
  if (!dir.exists(orf_dir)) {
    stop(sprintf("No results/04_ORF_CALLING directory found under %s -- has this DOGMA run reached Phase 2 (assembly/ORF-calling) at all?", results_dir))
  }
  pep_files <- list.files(orf_dir, pattern = "_transdecoder\\.pep$", recursive = TRUE, full.names = TRUE)
  if (length(pep_files) == 0) {
    stop("No *_transdecoder.pep files found -- this run has no ORFs to build a table from (Phase 2 assembly/ORF-calling never produced real output, or every sample is long-read-only, which DOGMA doesn't assemble -- see notes/DOGMA.md).")
  }
  # Path shape is always results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep
  rel <- sub(paste0("^", orf_dir,.Platform$file.sep), "", pep_files)
  parts <- strsplit(rel,.Platform$file.sep, fixed = TRUE)
  combos <- unique(data.frame(sample = vapply(parts, `[`, character(1), 1),
                               domain = vapply(parts, `[`, character(1), 2),
                               stringsAsFactors = FALSE))

  tables <- Map(function(s, d).read_dogma_sample_domain(results_dir, s, d), combos$sample, combos$domain)
  tables <- Filter(Negate(is.null), tables)
  if (length(tables) == 0) {
    stop("Every discovered sample/domain produced an empty TransDecoder.pep file -- no real ORFs anywhere in this run.")
  }
  long_table <- bind_rows(tables)

  # domain_filter's mode=both keeps prokaryote/eukaryote genuinely separate
  # by design (see notes/DOGMA.md's domain-wiring section) -- when more than
  # one domain exists in this run, fold it into a composite sample identity
  # (sample__domain) so every downstream analysis treats each domain's
  # results as its own comparable unit instead of silently mixing two
  # different assemblies' expression together under one sample name. In the
  # single-domain case (domain_filter inactive, or mode=prokaryote/
  # eukaryote only) this is just `sample` unchanged.
  n_domains <- length(unique(long_table$domain))
  long_table$sample_domain <- if (n_domains > 1) {
    paste0(long_table$sample, "__", long_table$domain)
  } else {
    long_table$sample
  }

  log_line("build_dogma_table: %d ORF rows across %d sample x domain combination(s) (%d unique sample_domain unit(s))",
           nrow(long_table), nrow(combos), length(unique(long_table$sample_domain)))
  long_table
}

#' Real, curated whitelist of "meaningful gene-family/grouping" columns --
#' i.e. columns worth offering as an --annotation_column choice for
#' composition/differential-abundance-style aggregation, as opposed to raw
#' per-hit statistics (evalue/bitscore/pident/length) that don't make sense
#' as a group-by key. Checked against what's ACTUALLY present in a given
#' run (most runs will only have a handful of these -- eggNOG is the only
#' always-on default annotator, everything else is an optional extra).
DOGMA_ANNOTATION_COLUMNS <- c(
  "eggnog_COG_category", "eggnog_KEGG_ko", "eggnog_KEGG_Pathway", "eggnog_Preferred_name",
  "cazy_dbCAN_hmm", "cazy_Substrate",
  "ncycdb_gene", "scycdb_gene", "mcycdb_gene",
  "canthyd_query_name",
  "fegenie_category", "fegenie_HMM",
  "catbat_lineage", "eukulele_classification", "magma_xref_taxonomy"
)

#' Aggregates the long per-ORF table into a real gene-family x sample count
#' matrix -- the actual bridge that makes cross-sample comparison possible
#' at all. Raw ORF/transcript IDs are sample-specific (DOGMA has no
#' co-assembly, see notes/DOGMA.md's quant.sf scope note) so they can NEVER
#' be compared directly across samples; aggregating by a shared functional-
#' annotation vocabulary instead is the real, literature-established fix
#' (CoMW, cited in notes/DOGMA.md, aggregates counts by functional category
#' for exactly this reason -- 0.6% false-positive functional calls in
#' soil-like data vs. up to 15% for read-mapping-only approaches).
#' Returned shape is deliberately IDENTICAL to build_count_matrix's
#' return value (list(counts=, gene_info=, coldata=)) so every existing
#' DESeq2-based analysis helper (deseq_helpers.R's run_deseq, etc.)
#' works against it completely unchanged.
#' @param long_table build_dogma_table's output.
#' @param annotation_col One of DOGMA_ANNOTATION_COLUMNS, must be present.
#' @param coldata Sample metadata, already keyed by sample_domain (see
#'   load_dogma_table.R -- it's the one that knows how to replicate a
#'   metadata row across domains for the mode=both case).
#' @param value_col "salmon_NumReads" (default, real counts) or
#'   "salmon_TPM".
aggregate_dogma_counts <- function(long_table, annotation_col, coldata, value_col = "salmon_NumReads") {
  if (!(annotation_col %in% colnames(long_table))) {
    stop(sprintf("annotation_col '%s' is not present in this run's data -- it needs the matching optional annotation tool to have been active. Available: %s",
                 annotation_col, paste(intersect(DOGMA_ANNOTATION_COLUMNS, colnames(long_table)), collapse = ", ")))
  }
  if (!(value_col %in% colnames(long_table))) {
    stop(sprintf("'%s' is not present -- Salmon quantification wasn't active for this run.", value_col))
  }

  # Rows with no annotation_col value (an ORF the chosen tool didn't
  # annotate) genuinely can't be assigned to any gene family -- dropped
  # here (not bucketed as "Unclassified", unlike taxonomic_composition.R's
  # convention) because a giant catch-all pseudo-gene isn't a meaningful
  # unit for DESeq2 differential testing the way it is for a descriptive
  # composition bar chart.
  agg <- long_table %>%
    filter(!is.na(.dataannotation_col),.dataannotation_col != "", !is.na(.datavalue_col)) %>%
    group_by(sample_domain,.dataannotation_col) %>%
    summarise(value = sum(.datavalue_col),.groups = "drop")

  wide <- agg %>%
    pivot_wider(names_from = sample_domain, values_from = value, values_fill = 0) %>%
    as.data.frame
  rownames(wide) <- wideannotation_col
  gene_ids <- wideannotation_col
  counts <- as.matrix(wide[, setdiff(colnames(wide), annotation_col), drop = FALSE])
  storage.mode(counts) <- "integer"  # Salmon's NumReads/TPM are floats (multi-mapping-weighted) -- DESeq2 needs integer counts, same rounding convention used elsewhere in this app (e.g. Emu's EM-estimated counts)

  missing_samples <- setdiff(rownames(coldata), colnames(counts))
  if (length(missing_samples) > 0) {
    stop(sprintf("No expression data at all for %d sample(s) after aggregating by '%s': %s",
                 length(missing_samples), annotation_col, paste(missing_samples, collapse = ", ")))
  }
  counts <- counts[, rownames(coldata), drop = FALSE]

  gene_info <- data.frame(row.names = gene_ids, gene_family = gene_ids, check.names = FALSE)
  list(counts = counts, gene_info = gene_info, coldata = coldata)
}

#' Builds a minimal, real `phyloseq` object from the same aggregated
#' gene-family/taxon counts `aggregate_dogma_counts` produces -- so
#' DOGMA can reuse MAGMA/PRISM's own community-ecology engine
#' (`estimate_richness`, `rarefy_even_depth`, `ordinate`,
#' `phyloseq::distance`, `adonis2`) alpha/beta diversity,
#' unchanged, instead of a third reimplementation. Deliberately no
#' `tax_table`/`phy_tree` -- none of alpha_diversity.R's or
#' beta_diversity.R's own functions ever touch either component (confirmed
#' by reading both directly: every one of them operates purely on
#' `otu_table`/`sample_data`), and there IS no real phylogeny between
#' arbitrary functional categories (a KEGG ortholog isn't "related to"
#' another one the way two ASVs can be) -- fabricating one, or a fake
#' tax_table, to satisfy an unused parameter would be actively misleading,
#' not just unnecessary. `--annotation_column` doubles as either a
#' functional vocabulary (KEGG_ko, COG_category, a cycling-gene family) OR
#' a taxonomic one (`catbat_lineage`, `eukulele_classification`) here --
#' same generic mechanism, the caller decides which question it's asking.
build_dogma_phyloseq <- function(long_table, annotation_col, coldata, value_col = "salmon_NumReads") {
  count_data <- aggregate_dogma_counts(long_table, annotation_col, coldata, value_col)
  phyloseq(
    otu_table(count_data$counts, taxa_are_rows = TRUE),
    sample_data(count_data$coldata)
  )
}
