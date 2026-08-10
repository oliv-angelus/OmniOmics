#!/usr/bin/env Rscript
# Cohort-level ASV inference + taxonomy + phylogenetic tree for PacBio
# HiFi/CCS amplicon reads. Runs once per PRISM run (not per sample) --
# DADA2's own error model is learned across every sample together, same
# real-world practice as its tutorials, and it naturally yields one shared
# sequence table instead of needing a separate cross-sample merge step
# afterwards.
#
# Near-zero-error HiFi reads (Q93) let DADA2's exact-sequence-inference model
# work directly on long reads (Callahan et al. 2019, NAR, 10.1093/nar/gkz569)
# -- the same core algorithm short-read Illumina data uses, reparameterized
# for length/quality. Chimera removal already happened upstream (vsearch
# uchime_denovo, see 03_chimera.smk) rather than DADA2's own
# removeBimeraDenovo, which a 2025 benchmark found flags over half of real
# long-read data as false-positive chimeras (Hakimzadeh et al. 2025,
# 10.7717/peerj.20456) -- so this script does NOT call removeBimeraDenovo.
#
# --gene expanded beyond {16S, ITS} to {16S, 18S, 23S, 28S, ITS},
# and --gtdb_ref/--unite_ref replaced by a single --ref_path (the manifest-
# level --gene/--reference_db resolution now happens once in
# 04_denoise_classify.smk's _resolve_ref_path, not duplicated here).
#
# Also real phylogenetic tree construction added, at ASV
# resolution (not the lineage-collapsed shape below) -- DADA2/phyloseq's own
# real, documented method (Callahan's DADA2 tutorials; Wright 2016 DECIPHER,
# 10.32614/RJ-2016-025; Schliep 2011 phangorn, 10.1093/bioinformatics/btq706):
# DECIPHER::AlignSeqs multiple-aligns the ASV sequences directly (DADA2 is
# reference-free, so there is no existing alignment/tree to place onto),
# phangorn builds a neighbor-joining tree from that alignment, then refines
# it to a GTR+G+I maximum-likelihood tree using the NJ tree as the starting
# topology. Written as a *separate*, ASV-level output (prism_asv_*) rather
# than folded into the lineage-collapsed prism_abundance_table.tsv, because
# phyloseq's phy_tree slot needs tip labels that exactly match the
# OTU table's own row identifiers -- collapsing to lineage strings first
# would break that correspondence. Wiring this ASV-level output into the
# Plots tab's phyloseq construction (to actually unlock UniFrac distances)
# is a separate, not-yet-done task -- this script only produces the files.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
source(file.path(this_script_dir, "lib", "build_tree.R"))

suppressPackageStartupMessages({
  library(optparse)
  library(dada2)
})

opt_list <- list(
  make_option("--input", type = "character"),   # comma-separated fastq.gz paths
  make_option("--samples", type = "character"),  # comma-separated sample names, same order as --input
  make_option("--gene", type = "character", default = "16S"),
  make_option("--reference_db", type = "character", default = "gtdb"),
  make_option("--ref_path", type = "character", default = ""),
  make_option("--max_ee", type = "double", default = 2.0),
  make_option("--min_asv_totalfreq", type = "integer", default = 5),
  make_option("--build_tree", type = "logical", default = TRUE, action = "store_true"),
  make_option("--out", type = "character")
)
opt <- parse_args(OptionParser(option_list = opt_list))

input_files <- strsplit(opt$input, ",")[[1]]
sample_names <- strsplit(opt$samples, ",")[[1]]
stopifnot(length(input_files) == length(sample_names))

# Real validation, not a silent wrong answer: gtdb only ever covers 16S --
# 04_denoise_classify.smk's _resolve_ref_path already routes 18S/23S/28S
# to SILVA regardless of --reference_db, so hitting this specific
# mismatch here would mean the resolution upstream didn't run as expected.
gene_upper <- toupper(opt$gene)
if (gene_upper == "16S" && opt$reference_db == "gtdb" && !nzchar(opt$ref_path)) {
  stop("GTDB reference not configured for --gene 16S -- configure it on the Databases tab (or switch --reference_db to silva).")
}
if (gene_upper %in% c("18S", "23S", "28S") && opt$reference_db == "gtdb") {
  stop(sprintf("GTDB does not cover --gene %s (bacteria/archaea 16S only) -- use --reference_db silva instead.", opt$gene))
}
ref_fasta <- opt$ref_path
if (!nzchar(ref_fasta) || !file.exists(ref_fasta)) {
  stop(sprintf("Reference database for gene '%s' (reference_db=%s) not found at '%s' -- configure it on the Databases tab first.",
               opt$gene, opt$reference_db, ref_fasta))
}

filt_dir <- file.path(dirname(opt$out), "filtered")
dir.create(filt_dir, showWarnings = FALSE, recursive = TRUE)
filt_files <- file.path(filt_dir, paste0(sample_names, "_filt.fastq.gz"))
names(filt_files) <- sample_names

# Light additional expected-error filter -- length/quality already handled by
# Filtlong and primers already removed by cutadapt upstream, this is DADA2's
# own denoising-specific EE gate.
filterAndTrim(input_files, filt_files, maxEE = opt$max_ee, truncQ = 0,
              minLen = 20, rm.phix = FALSE, compress = TRUE, multithread = TRUE)

present <- file.exists(filt_files) & file.size(filt_files) > 0
filt_files <- filt_files[present]
sample_names <- sample_names[present]
if (length(filt_files) == 0) stop("No sample survived DADA2's filterAndTrim -- check --max_ee / upstream QC.")

# PacBio CCS-specific error model (Callahan et al. 2019): errors are
# estimated conditioned on the read's own reported quality, using the
# self-consistency loop dada2::learnErrors already implements generically --
# no separate PacBio-only function needed as of current DADA2 releases.
errors <- learnErrors(filt_files, multithread = TRUE, verbose = 1)

dada_out <- dada(filt_files, err = errors, multithread = TRUE, verbose = 1)
if (length(filt_files) == 1) dada_out <- list(dada_out)
names(dada_out) <- sample_names

seqtab <- makeSequenceTable(dada_out)

# Frequency floor (--min_asv_totalfreq): drop ASVs that are essentially
# singletons across the whole cohort, same intent as HiFi-16S-workflow's own
# --min_asv_totalfreq default.
keep <- colSums(seqtab) >= opt$min_asv_totalfreq
seqtab <- seqtab[, keep, drop = FALSE]

tax <- assignTaxonomy(seqtab, ref_fasta, multithread = TRUE, verbose = TRUE)

# DADA2's assignTaxonomy returns one column per rank, unprefixed values
# (e.g. "Bacteria", not "d__Bacteria") -- re-add the d__/p__/c__/o__/f__/g__/
# s__ prefixes here so the joined `tax` string matches the exact GTDB-style
# format build_phyloseq.R already expects from MAGMA/SIGMA/DOGMA.
rank_prefixes <- c("d__", "p__", "c__", "o__", "f__", "g__", "s__")
n_ranks <- min(ncol(tax), length(rank_prefixes))
lineage <- apply(tax[, seq_len(n_ranks), drop = FALSE], 1, function(row) {
  paste(paste0(rank_prefixes[seq_len(n_ranks)], ifelse(is.na(row), "", row)), collapse = ";")
})

# --- ASV-level outputs (representative sequences + taxonomy mapping), BEFORE
# collapsing to lineage -- needed for tree-building and, later, PICRUSt2,
# neither of which can work from the collapsed lineage-string shape below.
asv_seqs <- colnames(seqtab)
asv_ids <- paste0("ASV", seq_along(asv_seqs))
asv_counts <- t(seqtab)
rownames(asv_counts) <- asv_ids

out_dir <- dirname(opt$out)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

asv_fasta_path <- file.path(out_dir, "prism_asv_sequences.fasta")
writeLines(unlist(lapply(seq_along(asv_seqs), function(i) c(paste0(">", asv_ids[i]), asv_seqs[i]))),
           asv_fasta_path)

asv_tax_df <- data.frame(asv_id = asv_ids, lineage = lineage,
                          tax[, seq_len(n_ranks), drop = FALSE], row.names = NULL, check.names = FALSE)
write.table(asv_tax_df, file.path(out_dir, "prism_asv_taxonomy.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

asv_counts_df <- data.frame(asv_id = rownames(asv_counts), asv_counts, check.names = FALSE, row.names = NULL)
write.table(asv_counts_df, file.path(out_dir, "prism_asv_counts.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

# --- Real phylogenetic tree, via the shared build_tree_from_sequences
# (see lib/build_tree.R for the full method + citations -- extracted out of
# this script so the ONT/Emu path's tree, built from detected
# reference sequences instead of ASVs, can reuse the identical method
# rather than a copy-pasted second implementation). Optional/skippable
# (--build_tree FALSE) since it adds real runtime for cohorts with many
# ASVs and isn't needed if the user only wants the abundance table.
if (isTRUE(opt$build_tree)) {
  names(asv_seqs) <- asv_ids
  tree <- build_tree_from_sequences(asv_seqs, label = "ASVs")
  if (!is.null(tree)) {
    write.tree(tree, file.path(out_dir, "prism_tree.nwk"))
    cat(sprintf("dada2_pacbio: wrote prism_tree.nwk (%d tips)\n", length(tree$tip.label)))
  }
}

# Collapse ASVs sharing an identical assigned lineage into one row (matches
# MAGMA's own abundance table shape: one row per unique lineage, not per
# ASV) -- counts summed across ASVs, not just the first one kept. This
# remains the PRIMARY/default output (unchanged shape, still what the Plots
# tab consumes today) -- the ASV-level files above are additional, not a
# replacement.
agg <- rowsum(asv_counts, group = lineage)
out_df <- data.frame(tax = rownames(agg), agg, check.names = FALSE, row.names = NULL)

write.table(out_df, opt$out, sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("dada2_pacbio: wrote %d lineage rows x %d samples to %s\n",
            nrow(out_df), length(sample_names), opt$out))
