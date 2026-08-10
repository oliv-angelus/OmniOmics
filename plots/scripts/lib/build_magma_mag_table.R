# Builds MAGMA's per-MAG tables for the Plots tab.
#
# MAGMA pools every sample's bins before dereplicating, so a MAG's identity is
# global to the run while its provenance is per-sample. That shape is baked
# into the file names `pool_hq_mags` writes: `{sample}_{bin}.fa`. Everything
# here keys off the MAG id and derives the source sample from that prefix,
# rather than trusting any tool's own identity column.
#
# Three tables, mirroring build_sigma_table.R's dense/long split:
#   build_magma_mag_table      one row per MAG (quality, taxonomy, provenance)
#   build_magma_mag_abundance  long: MAG x sample relative abundance
#   build_magma_mag_gene_hits  long: MAG x source x gene (AMR/virulence)

suppressMessages({
  library(dplyr)
})

# MIMAG genome-quality tiers (Bowers et al. 2017, Nat Biotechnol 35:725-731,
# doi:10.1038/nbt.3893). High quality additionally requires the 23S, 16S and 5S
# rRNA genes plus at least 18 tRNA types -- when that evidence is unavailable
# the tier is reported as "High (C/C only)" so a completeness/contamination-only
# call is never silently presented as a full MIMAG high-quality claim.
.MIMAG_HIGH_COMPLETENESS <- 90
.MIMAG_HIGH_CONTAMINATION <- 5
.MIMAG_MED_COMPLETENESS <- 50
.MIMAG_MED_CONTAMINATION <- 10
.MIMAG_MIN_TRNA_TYPES <- 18

#' Every MAG this run produced, from the pooled high-quality set that
#' dereplication reads. Falls back to the per-sample binette output when the
#' pool is absent (a run stopped before 07_DEREP).
.discover_mags <- function(results_dir) {
  pool <- file.path(results_dir, "07_DEREP", "all_hq_mags")
  if (dir.exists(pool)) {
    fas <- list.files(pool, pattern = "\\.(fa|fna|fasta)$", full.names = FALSE)
    if (length(fas) > 0) return(sort(sub("\\.(fa|fna|fasta)$", "", fas)))
  }
  refine <- file.path(results_dir, "06_MAG_REFINEMENT")
  if (!dir.exists(refine)) return(character(0))
  fas <- list.files(refine, pattern = "\\.(fa|fna|fasta)$", recursive = TRUE, full.names = FALSE)
  sort(unique(sub("\\.(fa|fna|fasta)$", "", basename(fas))))
}

#' Source sample of a MAG, from the `{sample}_{bin}.fa` naming pool_hq_mags
#' uses. Matched against the run's real sample directories rather than split
#' on the first underscore, since sample names themselves contain underscores
#' (e.g. "soil_site1_bin.1" -> "soil_site1", not "soil").
.mag_sample <- function(mag_ids, results_dir) {
  refine <- file.path(results_dir, "06_MAG_REFINEMENT")
  samples <- if (dir.exists(refine)) list.dirs(refine, full.names = FALSE, recursive = FALSE) else character(0)
  samples <- samples[nzchar(samples)]
  vapply(mag_ids, function(m) {
    hit <- samples[startsWith(m, paste0(samples, "_"))]
    if (length(hit) == 0) return(NA_character_)
    hit[which.max(nchar(hit))]
  }, character(1), USE.NAMES = FALSE)
}

#' CheckM2 runs per sample, so its quality_report.tsv lists only that sample's
#' bins. Read every one and stack them. Only the four columns used downstream
#' are selected by name, so a real CheckM2 report's extra columns
#' (Completeness_Model_Used, Additional_Notes, ...) are ignored rather than
#' breaking the read.
.read_checkm2_all <- function(results_dir) {
  refine <- file.path(results_dir, "06_MAG_REFINEMENT")
  if (!dir.exists(refine)) return(NULL)
  reports <- list.files(refine, pattern = "^quality_report\\.tsv$", recursive = TRUE, full.names = TRUE)
  if (length(reports) == 0) return(NULL)
  parts <- lapply(reports, function(f) {
    df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
    if (inherits(df, "try-error") || nrow(df) == 0 || !"Name" %in% colnames(df)) return(NULL)
    out <- data.frame(mag = as.character(df$Name), stringsAsFactors = FALSE)
    out$checkm2_completeness <- suppressWarnings(as.numeric(df[["Completeness"]] %||% NA))
    out$checkm2_contamination <- suppressWarnings(as.numeric(df[["Contamination"]] %||% NA))
    out$checkm2_genome_size <- suppressWarnings(as.numeric(df[["Genome_Size"]] %||% NA))
    out
  })
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) return(NULL)
  distinct(bind_rows(parts), mag, .keep_all = TRUE)
}

#' GTDB-Tk writes bac120 and/or ar53 summaries for the dereplicated set; read
#' whichever exist and stack them, so a run with both bacteria and archaea
#' keeps both. The full `classification` lineage is split into the same
#' Domain..Species rank columns the rest of the app uses.
.read_gtdbtk_mags <- function(results_dir) {
  dir_tk <- file.path(results_dir, "08_MAG_TAXONOMY", "gtdbtk")
  if (!dir.exists(dir_tk)) return(NULL)
  files <- list.files(dir_tk, pattern = "^gtdbtk\\.(bac120|ar53)\\.summary\\.tsv$",
                      recursive = TRUE, full.names = TRUE)
  if (length(files) == 0) return(NULL)
  parts <- lapply(files, function(f) {
    df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
    if (inherits(df, "try-error") || nrow(df) == 0 || !"user_genome" %in% colnames(df)) return(NULL)
    data.frame(
      mag = as.character(df$user_genome),
      gtdbtk_classification = as.character(df[["classification"]] %||% NA),
      gtdbtk_fastani_ani = suppressWarnings(as.numeric(df[["fastani_ani"]] %||% NA)),
      gtdbtk_red_value = suppressWarnings(as.numeric(df[["red_value"]] %||% NA)),
      stringsAsFactors = FALSE
    )
  })
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) return(NULL)
  tk <- distinct(bind_rows(parts), mag, .keep_all = TRUE)

  ranks <- c("domain", "phylum", "class", "order", "family", "genus", "species")
  split_lineage <- strsplit(tk$gtdbtk_classification %||% character(0), ";", fixed = TRUE)
  for (i in seq_along(ranks)) {
    tk[[paste0("gtdbtk_", ranks[i])]] <- vapply(split_lineage, function(x) {
      if (length(x) < i) return(NA_character_)
      v <- sub("^[a-z]__", "", trimws(x[i]))
      if (!nzchar(v)) NA_character_ else v
    }, character(1))
  }
  tk
}

#' Every 09_ANNOTATION/mags/* rule computes its own per-MAG file/directory
#' prefix as `magname=$(basename "$f".fa)` (confirmed by reading the real
#' shell in every one of vfdb_mags/barrnap_mags/trnascan_mags/amrfinder_mags/
#' prodigal_mags, and by literally running that line: with $f ending in
#' ".../{mag}.fa", `"$f".fa` concatenates a second, unintended ".fa" before
#' basename strips the path -- so on disk it is genuinely `{mag}.fa.fa`, not
#' `{mag}` or `{mag}.fa`. A real, pre-existing MAGMA bug (self-consistent
#' across rules, so the pipeline still runs; only the file naming is
#' affected) -- reproduced here rather than assumed away, since these readers
#' have to find what the pipeline actually writes.
.mag_shell_name <- function(mag) paste0(mag, ".fa.fa")

#' Barrnap writes standard GFF3; the rRNA gene name is in the attributes
#' column as `Name=16S_rRNA`. Counting distinct 5S/16S/23S names gives the
#' rRNA half of MIMAG's high-quality criterion.
#'
#' NOT yet checked against a real Barrnap run -- GFF3 itself is a fixed
#' specification, but if the attribute naming differs the count comes back
#' zero and the MIMAG tier degrades to the completeness/contamination-only
#' label rather than reporting a wrong result.
.read_barrnap_rrna <- function(results_dir, mag_ids) {
  d <- file.path(results_dir, "09_ANNOTATION", "mags", "barrnap")
  out <- data.frame(mag = mag_ids, rrna_5s = NA_integer_, rrna_16s = NA_integer_,
                    rrna_23s = NA_integer_, stringsAsFactors = FALSE)
  if (!dir.exists(d)) return(out)
  for (i in seq_along(mag_ids)) {
    f <- file.path(d, paste0(.mag_shell_name(mag_ids[i]), "_rrna.gff"))
    if (!file.exists(f)) next
    lines <- try(readLines(f, warn = FALSE), silent = TRUE)
    if (inherits(lines, "try-error")) next
    lines <- lines[!startsWith(lines, "#")]
    if (length(lines) == 0) next
    out$rrna_5s[i]  <- sum(grepl("Name=5S_rRNA", lines, fixed = TRUE))
    out$rrna_16s[i] <- sum(grepl("Name=16S_rRNA", lines, fixed = TRUE))
    out$rrna_23s[i] <- sum(grepl("Name=23S_rRNA", lines, fixed = TRUE))
  }
  out
}

#' tRNAscan-SE's default tabular output: three header lines, then one row per
#' tRNA with the amino acid in the `Type` column (5th field). MIMAG counts
#' distinct amino acid types, not total tRNAs.
#'
#' Same caveat as .read_barrnap_rrna: not yet checked against a real
#' tRNAscan-SE run, and returns NA rather than a guess when the file can't be
#' read in this shape.
.read_trnascan_types <- function(results_dir, mag_ids) {
  d <- file.path(results_dir, "09_ANNOTATION", "mags", "trnascan")
  out <- data.frame(mag = mag_ids, trna_types = NA_integer_, stringsAsFactors = FALSE)
  if (!dir.exists(d)) return(out)
  for (i in seq_along(mag_ids)) {
    f <- file.path(d, paste0(.mag_shell_name(mag_ids[i]), "_trna.out"))
    if (!file.exists(f)) next
    lines <- try(readLines(f, warn = FALSE), silent = TRUE)
    if (inherits(lines, "try-error") || length(lines) < 4) next
    body <- lines[-seq_len(3)]
    body <- body[nzchar(trimws(body)) & !startsWith(body, "#")]
    if (length(body) == 0) next
    types <- vapply(strsplit(body, "\t"), function(x) if (length(x) >= 5) trimws(x[5]) else NA_character_, character(1))
    types <- types[!is.na(types) & nzchar(types) & !types %in% c("Undet", "Pseudo")]
    if (length(types) == 0) next
    out$trna_types[i] <- length(unique(types))
  }
  out
}

#' MIMAG tier per MAG. `rrna_ok`/`trna_ok` are NA when that evidence could not
#' be read at all, which is reported as "High (C/C only)" rather than "High" --
#' see the constants block for why.
.mimag_tier <- function(comp, cont, rrna_ok, trna_ok) {
  vapply(seq_along(comp), function(i) {
    cp <- comp[i]; ct <- cont[i]
    if (is.na(cp) || is.na(ct)) return(NA_character_)
    if (cp > .MIMAG_HIGH_COMPLETENESS && ct < .MIMAG_HIGH_CONTAMINATION) {
      evidence <- c(rrna_ok[i], trna_ok[i])
      if (all(!is.na(evidence))) {
        return(if (all(evidence)) "High" else "Medium")
      }
      return("High (C/C only)")
    }
    if (cp >= .MIMAG_MED_COMPLETENESS && ct < .MIMAG_MED_CONTAMINATION) return("Medium")
    "Low"
  }, character(1))
}

#' One row per MAG: provenance, CheckM2 quality, GTDB-Tk taxonomy, whether it
#' survived dereplication, and the MIMAG tier.
build_magma_mag_table <- function(results_dir) {
  mags <- .discover_mags(results_dir)
  if (length(mags) == 0) {
    stop("No MAGs found under 07_DEREP/all_hq_mags or 06_MAG_REFINEMENT -- ",
         "this run has no binning/refinement output to analyse.")
  }
  df <- data.frame(mag = mags, sample = .mag_sample(mags, results_dir), stringsAsFactors = FALSE)

  derep_dir <- file.path(results_dir, "07_DEREP", "drep_out", "dereplicated_genomes")
  derep <- if (dir.exists(derep_dir)) {
    sub("\\.(fa|fna|fasta)$", "", list.files(derep_dir, pattern = "\\.(fa|fna|fasta)$"))
  } else character(0)
  # Membership of the dereplicated folder is a file listing, not a parsed
  # format -- reliable regardless of dRep's own table schema.
  df$dereplicated <- df$mag %in% derep

  cm <- .read_checkm2_all(results_dir)
  df <- if (is.null(cm)) {
    df$checkm2_completeness <- NA_real_; df$checkm2_contamination <- NA_real_
    df$checkm2_genome_size <- NA_real_; df
  } else left_join(df, cm, by = "mag")

  tk <- .read_gtdbtk_mags(results_dir)
  if (!is.null(tk)) df <- left_join(df, tk, by = "mag")

  rr <- .read_barrnap_rrna(results_dir, df$mag)
  tr <- .read_trnascan_types(results_dir, df$mag)
  df <- left_join(left_join(df, rr, by = "mag"), tr, by = "mag")

  rrna_ok <- ifelse(is.na(df$rrna_5s) | is.na(df$rrna_16s) | is.na(df$rrna_23s), NA,
                    df$rrna_5s > 0 & df$rrna_16s > 0 & df$rrna_23s > 0)
  trna_ok <- ifelse(is.na(df$trna_types), NA, df$trna_types >= .MIMAG_MIN_TRNA_TYPES)
  df$mimag_quality <- .mimag_tier(df$checkm2_completeness, df$checkm2_contamination, rrna_ok, trna_ok)

  df[order(df$mag), , drop = FALSE]
}

#' Long MAG x sample relative abundance, from CoverM's own header. CoverM
#' bakes the sample name into every non-"Genome" column as
#' "{sample} Relative Abundance (%)", so columns are matched by suffix and the
#' sample recovered from the prefix rather than assuming a column order.
build_magma_mag_abundance <- function(results_dir) {
  f <- file.path(results_dir, "10_MAG_COVERAGE", "coverm_coverage.tsv")
  if (!file.exists(f)) return(NULL)
  df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0 || !"Genome" %in% colnames(df)) return(NULL)
  metric_cols <- setdiff(colnames(df), "Genome")
  rel_cols <- metric_cols[grepl("Relative Abundance", metric_cols, fixed = TRUE)]
  if (length(rel_cols) == 0) return(NULL)
  out <- lapply(rel_cols, function(cn) {
    data.frame(
      mag = as.character(df$Genome),
      sample = trimws(sub("\\s*Relative Abundance.*$", "", cn)),
      rel_abundance = suppressWarnings(as.numeric(df[[cn]])),
      stringsAsFactors = FALSE
    )
  })
  bind_rows(out)
}

#' Long per-MAG AMR/virulence gene hits, same sparse shape as SIGMA's
#' build_sigma_gene_hits. Files are per MAG under 09_ANNOTATION/mags/.
#'
#' Carries the join keys each source needs for .attach_gene_sequences() to
#' later fetch the real sequence: AMRFinderPlus's own "Protein identifier" is
#' the exact FASTA header Prodigal wrote (AMRFinder is run with `-p` directly
#' against Prodigal's .faa -- confirmed from the real rule, see
#' 07_annotation_mobilome.smk's amrfinder_mags), so it is a clean 1:1 lookup.
#' abricate (VFDB) is run against the whole MAG genome fasta, not a protein
#' prediction, so its hit is a nucleotide region (contig + start + end)
#' rather than a single record.
build_magma_mag_gene_hits <- function(results_dir, mag_ids) {
  base <- file.path(results_dir, "09_ANNOTATION", "mags")
  if (!dir.exists(base)) return(NULL)
  parts <- list()

  # amrfinder_mags writes one subdirectory per MAG (magname = .mag_shell_name)
  # containing a FIXED filename "amrfinder_results.tsv" -- unlike vfdb below,
  # the MAG id is not part of the filename itself, only the directory.
  amr_dir <- file.path(base, "amrfinder")
  if (dir.exists(amr_dir)) {
    for (mag in mag_ids) {
      f <- file.path(amr_dir, .mag_shell_name(mag), "amrfinder_results.tsv")
      if (!file.exists(f)) next
      df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
      if (inherits(df, "try-error") || nrow(df) == 0) next
      gene_col <- intersect(c("Element symbol", "Gene symbol"), colnames(df))
      name_col <- intersect(c("Element name", "Sequence name"), colnames(df))
      if (length(gene_col) == 0) next
      parts[[length(parts) + 1]] <- data.frame(
        mag = mag,
        source = "amrfinder",
        gene = as.character(df[[gene_col[1]]]),
        product = if (length(name_col)) as.character(df[[name_col[1]]]) else NA_character_,
        class = as.character(df[["Class"]] %||% NA),
        subclass = as.character(df[["Subclass"]] %||% NA),
        pct_identity = suppressWarnings(as.numeric(df[["% Identity to reference"]] %||% NA)),
        pct_coverage = suppressWarnings(as.numeric(df[["% Coverage of reference"]] %||% NA)),
        protein_id = as.character(df[["Protein identifier"]] %||% NA),
        contig = NA_character_, seq_start = NA_integer_, seq_end = NA_integer_,
        stringsAsFactors = FALSE
      )
    }
  }

  # vfdb_mags writes one flat file per MAG, "{magname}_vfdb_results.tab",
  # directly under the outdir (no per-MAG subdirectory, unlike amrfinder).
  vfdb_dir <- file.path(base, "vfdb")
  if (dir.exists(vfdb_dir)) {
    for (mag in mag_ids) {
      f <- file.path(vfdb_dir, paste0(.mag_shell_name(mag), "_vfdb_results.tab"))
      if (!file.exists(f)) next
      df <- try(read.delim(f, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
      if (inherits(df, "try-error") || nrow(df) == 0 || !"GENE" %in% colnames(df)) next
      parts[[length(parts) + 1]] <- data.frame(
        mag = mag,
        source = "vfdb",
        gene = as.character(df$GENE),
        product = as.character(df[["PRODUCT"]] %||% NA),
        class = NA_character_, subclass = NA_character_,
        pct_identity = suppressWarnings(as.numeric(df[["%IDENTITY"]] %||% NA)),
        pct_coverage = suppressWarnings(as.numeric(df[["%COVERAGE"]] %||% NA)),
        protein_id = NA_character_,
        contig = as.character(df[["SEQUENCE"]] %||% NA),
        seq_start = suppressWarnings(as.integer(df[["START"]] %||% NA)),
        seq_end = suppressWarnings(as.integer(df[["END"]] %||% NA)),
        stringsAsFactors = FALSE
      )
    }
  }

  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}

#' Parses a FASTA file into a named character vector (header token up to the
#' first whitespace -> sequence, newlines stripped). Shared by both sequence
#' extractors below; kept intentionally simple (no Biostrings dependency --
#' this app's r-plots env doesn't otherwise need one) since MAG genome/protein
#' FASTAs are small enough to read whole.
.read_fasta_map <- function(path) {
  if (!file.exists(path)) return(NULL)
  lines <- try(readLines(path, warn = FALSE), silent = TRUE)
  if (inherits(lines, "try-error") || length(lines) == 0) return(NULL)
  starts <- which(startsWith(lines, ">"))
  if (length(starts) == 0) return(NULL)
  ends <- c(starts[-1] - 1, length(lines))
  ids <- sub("^>(\\S+).*$", "\\1", lines[starts])
  seqs <- vapply(seq_along(starts), function(i) {
    body <- lines[(starts[i] + 1):ends[i]]
    paste(body[nzchar(trimws(body))], collapse = "")
  }, character(1))
  stats::setNames(as.list(seqs), ids)
}

#' Adds real sequences to a gene_hits data frame, scoped to `mags` -- called
#' with only the MAGs the user actually selected, not the whole run, since
#' reading every MAG's protein/genome FASTA at load time (before any MAG is
#' even picked) would be wasted I/O on runs with dozens of MAGs.
#'
#' AMR hits resolve by exact protein_id lookup in Prodigal's own .faa.
#' VFDB hits resolve by slicing [seq_start, seq_end] out of the MAG's own
#' assembly fasta (dereplicated_genomes, the same file abricate was run
#' against) -- a 1-based, inclusive range per abricate's own convention.
attach_gene_sequences <- function(gene_hits, results_dir, mags) {
  if (is.null(gene_hits) || nrow(gene_hits) == 0) {
    if (is.null(gene_hits)) return(NULL)
    gene_hits$sequence <- character(0); gene_hits$sequence_type <- character(0)
    return(gene_hits)
  }
  gene_hits <- gene_hits[gene_hits$mag %in% mags, , drop = FALSE]
  gene_hits$sequence <- NA_character_
  gene_hits$sequence_type <- NA_character_

  for (m in unique(gene_hits$mag)) {
    rows_amr <- which(gene_hits$mag == m & gene_hits$source == "amrfinder")
    if (length(rows_amr) > 0) {
      faa <- file.path(results_dir, "09_ANNOTATION", "mags", "prodigal", .mag_shell_name(m),
                       paste0(.mag_shell_name(m), "_proteins.faa"))
      prot <- .read_fasta_map(faa)
      if (!is.null(prot)) {
        gene_hits$sequence[rows_amr] <- vapply(rows_amr, function(i) {
          prot[[gene_hits$protein_id[i]]] %||% NA_character_
        }, character(1))
        gene_hits$sequence_type[rows_amr] <- "protein"
      }
    }
    rows_vf <- which(gene_hits$mag == m & gene_hits$source == "vfdb")
    if (length(rows_vf) > 0) {
      genome <- file.path(results_dir, "07_DEREP", "drep_out", "dereplicated_genomes", paste0(m, ".fa"))
      if (!file.exists(genome)) {
        # Falls back to whichever sample's binette output produced it, for a
        # MAG that didn't survive dereplication (build_magma_mag_table.R
        # still lists it, with dereplicated = FALSE). Uses the same
        # sample-directory matching as .mag_sample() -- not a split on the
        # last underscore, since a sample name can itself contain one.
        sample <- .mag_sample(m, results_dir)
        genome <- file.path(results_dir, "06_MAG_REFINEMENT", sample, "binette", "final_bins", paste0(m, ".fa"))
      }
      contigs <- .read_fasta_map(genome)
      if (!is.null(contigs)) {
        gene_hits$sequence[rows_vf] <- vapply(rows_vf, function(i) {
          seq <- contigs[[gene_hits$contig[i]]]
          s <- gene_hits$seq_start[i]; e <- gene_hits$seq_end[i]
          if (is.null(seq) || is.na(s) || is.na(e)) return(NA_character_)
          lo <- min(s, e); hi <- max(s, e)
          if (hi > nchar(seq)) return(NA_character_)
          substr(seq, lo, hi)
        }, character(1))
        gene_hits$sequence_type[rows_vf] <- "nucleotide"
      }
    }
  }
  gene_hits
}
