#!/usr/bin/env Rscript
# Real phylogenetic tree for the ONT/Emu path -- built from the actual
# REFERENCE sequences Emu matched reads to, not from raw reads or a
# per-sample consensus (Emu has neither: it's expectation-maximization
# against a reference database, no ASV-calling, so there is no per-sample
# sequence to align/tree the way DADA2's ASVs work for the PacBio path).
#
# Real, established closed-reference-tree approach, not improvised: since
# Emu already reports exactly which reference tax_id(s) each classified
# read most closely matches, the tree only needs to cover the (typically
# small -- tens to low hundreds of species, not the whole tens-of-thousands
# reference database) set of tax_ids actually DETECTED across the run's
# cohort -- computationally bounded by what was found, not by database
# size. Same DECIPHER align -> phangorn NJ -> GTR+G+I ML method as the
# PacBio path (see lib/build_tree.R), reused rather than reimplemented.
#
# Real structural mirror of dada2_pacbio.R's own design: writes ASV-level-
# equivalent output (prism_tree.nwk + prism_species_taxonomy.tsv) alongside,
# not instead of, the existing lineage-collapsed prism_abundance_table.tsv
# -- phyloseq's phy_tree needs tip labels that exactly match real
# taxon/row identifiers, which the lineage-collapsed shape can't provide.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
source(file.path(this_script_dir(), "lib", "build_tree.R"))

suppressPackageStartupMessages({
  library(optparse)
  library(Biostrings)
})

opt_list <- list(
  make_option("--species_counts", type = "character"),  # tax_id x sample counts (join_emu_tables.py --out_species)
  make_option("--ref_fasta", type = "character"),        # Emu db's own species_taxid.fasta (tax_id-headered)
  make_option("--taxonomy", type = "character"),         # Emu db's own taxonomy.tsv (tax_id -> rank columns)
  make_option("--out_dir", type = "character"),
  make_option("--threads", type = "integer", default = 4)
)
opt <- parse_args(OptionParser(option_list = opt_list))

dir.create(opt$out_dir, showWarnings = FALSE, recursive = TRUE)

counts <- read.delim(opt$species_counts, header = TRUE, check.names = FALSE, colClasses = "character")
sample_cols <- setdiff(colnames(counts), "tax_id")
totals <- rowSums(sapply(counts[sample_cols], as.numeric))
detected_ids <- as.character(counts$tax_id[totals > 0])

cat(sprintf("build_emu_tree: %d tax_id(s) detected across the cohort (out of %d in the reference database)\n",
            length(detected_ids), nrow(counts)))

if (length(detected_ids) < 3) {
  cat(sprintf("build_emu_tree: skipping (only %d detected tax_id(s), need >=3 for a meaningful tree)\n", length(detected_ids)))
  quit(save = "no", status = 0)
}

ref_seqs <- readDNAStringSet(opt$ref_fasta)
# species_taxid.fasta headers are not the bare tax_id. That holds for
# build_emu_taxonomy.py's own *input* prep fasta, but `emu build-database`
# rewrites its output fasta with its own internal naming, observed as
# "{tax_id}:{db_dir}:{seq_index} ['{accession}']" -- e.g.
# ">1:results/04_DENOISE/emu/db_16S:1 ['1']". The tax_id is reliably the first
# ':'-delimited field of the FASTA ID, so parse that rather than taking the
# whole ID.
raw_ids <- sub("\\s.*$", "", names(ref_seqs))  # FASTA ID token only, drop any description
ref_tax_ids <- sub(":.*$", "", raw_ids)
matched <- ref_tax_ids %in% detected_ids
if (sum(matched) == 0) {
  stop("None of the detected tax_ids were found in --ref_fasta -- mismatched files?")
}
# One representative sequence per tax_id (a species can have more than one
# reference sequence in the database) -- keep the first encountered, same
# "one representative per taxon" intent as the PacBio path's one-row-per-ASV
# tree (there each ASV is already unique; here we collapse to unique tax_id).
detected_seqs <- as.character(ref_seqs[matched])
names(detected_seqs) <- ref_tax_ids[matched]
detected_seqs <- detected_seqs[!duplicated(names(detected_seqs))]

tree <- build_tree_from_sequences(detected_seqs, label = "detected reference species", processors = opt$threads)
if (!is.null(tree)) {
  write.tree(tree, file.path(opt$out_dir, "prism_tree.nwk"))
  cat(sprintf("build_emu_tree: wrote prism_tree.nwk (%d tips)\n", length(tree$tip.label)))
}

# Filter the Emu db's own taxonomy.tsv down to just the tree's tips, mirroring
# dada2_pacbio.R's prism_asv_taxonomy.tsv shape.
tax <- read.delim(opt$taxonomy, header = TRUE, check.names = FALSE, colClasses = "character")
tax_out <- tax[tax$tax_id %in% names(detected_seqs),, drop = FALSE]
write.table(tax_out, file.path(opt$out_dir, "prism_species_taxonomy.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("build_emu_tree: wrote prism_species_taxonomy.tsv (%d rows)\n", nrow(tax_out)))
