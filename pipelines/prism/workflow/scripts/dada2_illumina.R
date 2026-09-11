#!/usr/bin/env Rscript
# Cohort-level ASV inference + taxonomy + phylogenetic tree for paired-end
# short-read (Illumina) amplicon data. Runs once per PRISM run (not per
# sample), same cross-sample error-learning practice as dada2_pacbio.R.
#
# This is the ORIGINAL DADA2 workflow (Callahan et al. 2016, Nat Methods,
# 10.1038/nmeth.3869) -- the algorithm every other PRISM denoiser here is a
# reparameterization OF. Unlike dada2_pacbio.R (chimera removal already done
# upstream by vsearch uchime_denovo, since long-read chimera detectors are
# the ones with the real false-positive problem -- Hakimzadeh et al. 2025)
# this script DOES call DADA2's own removeBimeraDenovo(): short Illumina
# reads exact-dereplicate reliably, which is exactly the abundance signal its
# parent/child logic needs, and it's the standard/textbook choice for this
# read type -- no long-read-specific workaround applies here.
#
# Added 2026-09-11 for short-amplicon markers (COI/12S, fish eDNA
# metabarcoding -- see notes/PRISM.md) but not restricted to them: any
# --gene/--reference_db combination _resolve_ref_path (04_denoise_classify.smk)
# resolves works here, including a short-read 16S/ITS run.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
source(file.path(this_script_dir(), "lib", "build_tree.R"))

suppressPackageStartupMessages({
  library(optparse)
  library(dada2)
})

opt_list <- list(
  make_option("--input_r1", type = "character"),   # comma-separated R1 fastq.gz paths
  make_option("--input_r2", type = "character"),   # comma-separated R2 fastq.gz paths, same order
  make_option("--samples", type = "character"),     # comma-separated sample names, same order
  make_option("--gene", type = "character", default = "12S"),
  make_option("--reference_db", type = "character", default = "mitofish"),
  make_option("--ref_path", type = "character", default = ""),
  make_option("--max_ee", type = "double", default = 2.0),
  make_option("--min_asv_totalfreq", type = "integer", default = 5),
  make_option("--build_tree", type = "logical", default = TRUE, action = "store_true"),
  make_option("--out", type = "character")
)
opt <- parse_args(OptionParser(option_list = opt_list))

r1_files <- strsplit(opt$input_r1, ",")[[1]]
r2_files <- strsplit(opt$input_r2, ",")[[1]]
sample_names <- strsplit(opt$samples, ",")[[1]]
stopifnot(length(r1_files) == length(sample_names), length(r2_files) == length(sample_names))

# Real validation, not a silent wrong answer -- same spirit as
# dada2_pacbio.R's own checks, kept generic here since this script's
# --reference_db choices (gtdb/silva/midori2/mitofish) span every gene
# _resolve_ref_path resolves, not just one family.
ref_fasta <- opt$ref_path
if (!nzchar(ref_fasta) || !file.exists(ref_fasta)) {
  stop(sprintf("Reference database for gene '%s' (reference_db=%s) not found at '%s' -- configure it on the Databases tab first.",
               opt$gene, opt$reference_db, ref_fasta))
}

out_dir <- dirname(opt$out)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
filt_dir <- file.path(out_dir, "filtered")
dir.create(filt_dir, showWarnings = FALSE, recursive = TRUE)
filt_r1 <- file.path(filt_dir, paste0(sample_names, "_R1_filt.fastq.gz"))
filt_r2 <- file.path(filt_dir, paste0(sample_names, "_R2_filt.fastq.gz"))
names(filt_r1) <- sample_names
names(filt_r2) <- sample_names

# Standard DADA2 paired-end tutorial parameters (Callahan et al. 2016's own
# workflow): truncQ=2 truncates each read at the first base with quality <=2
# (a real Illumina quality-drop convention, not the maxEE-only gate the
# long-read path uses -- PacBio/ONT reads don't have this same per-base
# quality-cliff shape). No truncLen: primers are already removed upstream
# (cutadapt_trim_short) and every marker gene here has a different real
# amplicon length (COI ~313bp, 12S ~170bp, 16S/ITS/etc longer), so a fixed
# truncLen would need per-gene tuning DADA2's own docs don't provide a single
# safe default for -- maxEE is the length-agnostic quality gate used instead,
# same choice dada2_pacbio.R already makes for its own reasons.
filterAndTrim(r1_files, filt_r1, r2_files, filt_r2,
              maxEE = c(opt$max_ee, opt$max_ee), truncQ = 2, minLen = 50,
              rm.phix = TRUE, compress = TRUE, multithread = TRUE)

present <- file.exists(filt_r1) & file.size(filt_r1) > 0 &
           file.exists(filt_r2) & file.size(filt_r2) > 0
filt_r1 <- filt_r1[present]
filt_r2 <- filt_r2[present]
sample_names <- sample_names[present]
if (length(filt_r1) == 0) stop("No sample survived DADA2's filterAndTrim -- check --max_ee / upstream QC.")

# Forward/reverse error models learned separately (standard paired-end
# practice -- R1/R2 have genuinely different real error profiles on
# Illumina, R2 typically noisier).
errF <- learnErrors(filt_r1, multithread = TRUE, verbose = 1)
errR <- learnErrors(filt_r2, multithread = TRUE, verbose = 1)

dadaF <- dada(filt_r1, err = errF, multithread = TRUE, verbose = 1)
dadaR <- dada(filt_r2, err = errR, multithread = TRUE, verbose = 1)
if (length(filt_r1) == 1) { dadaF <- list(dadaF); dadaR <- list(dadaR) }
names(dadaF) <- sample_names
names(dadaR) <- sample_names

mergers <- mergePairs(dadaF, filt_r1, dadaR, filt_r2, verbose = TRUE)
if (length(filt_r1) == 1) mergers <- list(mergers)
names(mergers) <- sample_names

seqtab <- makeSequenceTable(mergers)

# The one real algorithmic difference from dada2_pacbio.R: short Illumina
# reads exact-dereplicate reliably (unlike raw long reads, see this script's
# header), so DADA2's own removeBimeraDenovo() has real abundance signal to
# work with here -- no external VSEARCH chimera step needed for this
# read type (see 03_chimera.smk's header comment).
seqtab <- removeBimeraDenovo(seqtab, method = "consensus", multithread = TRUE, verbose = TRUE)

keep <- colSums(seqtab) >= opt$min_asv_totalfreq
seqtab <- seqtab[, keep, drop = FALSE]

tax <- assignTaxonomy(seqtab, ref_fasta, multithread = TRUE, verbose = TRUE)

# Same GTDB-style rank-prefix convention every other PRISM engine's output
# already uses (see dada2_pacbio.R's own identical block) -- keeps the final
# abundance table's lineage strings consistent across all three engines
# regardless of which reference database actually produced them.
rank_prefixes <- c("d__", "p__", "c__", "o__", "f__", "g__", "s__")
n_ranks <- min(ncol(tax), length(rank_prefixes))
lineage <- apply(tax[, seq_len(n_ranks), drop = FALSE], 1, function(row) {
  paste(paste0(rank_prefixes[seq_len(n_ranks)], ifelse(is.na(row), "", row)), collapse = ";")
})

asv_seqs <- colnames(seqtab)
asv_ids <- paste0("ASV", seq_along(asv_seqs))
asv_counts <- t(seqtab)
rownames(asv_counts) <- asv_ids

asv_fasta_path <- file.path(out_dir, "prism_asv_sequences.fasta")
writeLines(unlist(lapply(seq_along(asv_seqs), function(i) c(paste0(">", asv_ids[i]), asv_seqs[i]))),
           asv_fasta_path)

asv_tax_df <- data.frame(asv_id = asv_ids, lineage = lineage,
                          tax[, seq_len(n_ranks), drop = FALSE], row.names = NULL, check.names = FALSE)
write.table(asv_tax_df, file.path(out_dir, "prism_asv_taxonomy.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

asv_counts_df <- data.frame(asv_id = rownames(asv_counts), asv_counts, check.names = FALSE, row.names = NULL)
write.table(asv_counts_df, file.path(out_dir, "prism_asv_counts.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

# Same shared DECIPHER/phangorn method as dada2_pacbio.R (see lib/build_tree.R)
# -- ASV-level tree, not wired into picrust2 (PICRUSt2's own reference tree
# is 16S/bacteria-archaea-specific, out of scope for COI/12S by design, see
# 05_functional_inference.smk).
if (isTRUE(opt$build_tree)) {
  names(asv_seqs) <- asv_ids
  tree <- build_tree_from_sequences(asv_seqs, label = "ASVs")
  if (!is.null(tree)) {
    write.tree(tree, file.path(out_dir, "prism_tree.nwk"))
    cat(sprintf("dada2_illumina: wrote prism_tree.nwk (%d tips)\n", length(tree$tip.label)))
  }
}

agg <- rowsum(asv_counts, group = lineage)
out_df <- data.frame(tax = rownames(agg), agg, check.names = FALSE, row.names = NULL)

write.table(out_df, opt$out, sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("dada2_illumina: wrote %d lineage rows x %d samples to %s\n",
            nrow(out_df), length(sample_names), opt$out))
