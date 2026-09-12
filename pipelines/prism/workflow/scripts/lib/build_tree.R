# Shared phylogenetic tree builder -- extracted from
# dada2_pacbio.R (the PacBio/DADA2 path's original tree-building code, kept
# working unchanged) so the ONT/Emu path's tree (build_emu_tree.R) can reuse
# the exact same method instead of a copy-pasted second implementation.
#
# Method (changed 2026-09-12, see below for why): DECIPHER::AlignSeqs
# (Wright 2016, 10.32614/RJ-2016-025) multiple-aligns the input sequences
# directly (no existing alignment assumed), then FastTree 2 (Price, Dehal &
# Arkin 2010, 10.1371/journal.pone.0009490) builds an approximately-ML
# GTR+CAT tree (`-nt -gtr -gamma`) from that alignment in one step -- no
# separate NJ-then-refine pass, FastTree does both together internally.
#
# Previously this used phangorn (Schliep 2011, 10.1093/bioinformatics/btq706):
# NJ tree via dist.ml/NJ, then optim.pml GTR+G+I ML refinement from that NJ
# starting topology. Replaced after a real run: a 4569-ASV COI tree
# (2026-09-11) took over 24h wall time and had to be killed at the walltime
# limit, because phangorn's optim.pml has no multicore support at all and
# scales very poorly (much worse than linear) past a few hundred tips --
# more processors does not speed that step up. FastTree 2 is the established
# fix for exactly this scale (it is, e.g., what QIIME2 uses by default for
# ASV/OTU trees for the same reason) -- near-linear scaling to tens of
# thousands of tips, real multithreading via FastTreeMP/OMP_NUM_THREADS.
#
#' @param seqs Named character vector of DNA sequences (names become tip labels).
#' @param label A short string used only in log messages (e.g. "3 ASVs", "12 detected species").
#' @param processors Cores to give DECIPHER::AlignSeqs and FastTreeMP (both
#'   real multithreaded steps here). NULL lets DECIPHER auto-detect (its own
#'   default) and leaves FastTreeMP's own default thread count in place.
#' @return An ape phylo tree object, or NULL if fewer than 3 sequences were given.
build_tree_from_sequences <- function(seqs, label = "sequences", processors = NULL) {
  if (length(seqs) < 3) {
    cat(sprintf("build_tree_from_sequences: skipping (%d %s, need >=3 for a meaningful tree)\n",
                length(seqs), label))
    return(NULL)
  }
  suppressPackageStartupMessages({
    library(DECIPHER)
    library(Biostrings)
    library(ape)
  })
  cat(sprintf("build_tree_from_sequences: building phylogenetic tree for %d %s (DECIPHER align -> FastTree2 GTR+CAT ML)...\n",
              length(seqs), label))
  seqs_dna <- DNAStringSet(seqs)
  names(seqs_dna) <- names(seqs)
  alignment <- AlignSeqs(seqs_dna, anchor = NA, verbose = FALSE, processors = processors)

  aln_file <- tempfile(fileext = ".fasta")
  tree_file <- tempfile(fileext = ".nwk")
  on.exit(unlink(c(aln_file, tree_file)), add = TRUE)
  writeXStringSet(alignment, aln_file)

  # FastTreeMP (OpenMP-threaded build) preferred; fall back to single-thread
  # FastTree/fasttree binary names, whichever the conda package provides.
  fasttree_bin <- Sys.which("FastTreeMP")
  is_mp <- fasttree_bin != ""
  if (!is_mp) fasttree_bin <- Sys.which("FastTree")
  if (fasttree_bin == "") fasttree_bin <- Sys.which("fasttree")
  if (fasttree_bin == "") {
    stop("build_tree_from_sequences: no FastTree/FastTreeMP/fasttree binary found on PATH -- is the 'fasttree' conda package installed in this env?")
  }

  if (is_mp && !is.null(processors)) {
    Sys.setenv(OMP_NUM_THREADS = as.character(processors))
  }

  status <- system2(fasttree_bin, args = c("-nt", "-gtr", "-gamma", "-quiet", aln_file),
                     stdout = tree_file, stderr = FALSE)
  if (status != 0 || !file.exists(tree_file) || file.info(tree_file)$size == 0) {
    stop(sprintf("build_tree_from_sequences: %s failed (exit status %s)", basename(fasttree_bin), status))
  }

  read.tree(tree_file)
}
