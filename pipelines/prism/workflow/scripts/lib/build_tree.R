# Shared phylogenetic tree builder -- extracted from
# dada2_pacbio.R (the PacBio/DADA2 path's original tree-building code, kept
# working unchanged) so the ONT/Emu path's tree (build_emu_tree.R) can reuse
# the exact same method instead of a copy-pasted second implementation.
#
# Real, documented DADA2/phyloseq method (Callahan's DADA2 tutorials; Wright
# 2016 DECIPHER, 10.32614/RJ-2016-025; Schliep 2011 phangorn,
# 10.1093/bioinformatics/btq706): DECIPHER::AlignSeqs multiple-aligns the
# input sequences directly (no existing alignment assumed), phangorn builds
# a neighbor-joining tree from that alignment, then refines it to a
# GTR+G+I maximum-likelihood tree using the NJ tree as the starting
# topology.
#
#' @param seqs Named character vector of DNA sequences (names become tip labels).
#' @param label A short string used only in log messages (e.g. "3 ASVs", "12 detected species").
#' @return An ape phylo tree object, or NULL if fewer than 3 sequences were given.
build_tree_from_sequences <- function(seqs, label = "sequences") {
  if (length(seqs) < 3) {
    cat(sprintf("build_tree_from_sequences: skipping (%d %s, need >=3 for a meaningful tree)\n",
                length(seqs), label))
    return(NULL)
  }
  suppressPackageStartupMessages({
    library(DECIPHER)
    library(phangorn)
  })
  cat(sprintf("build_tree_from_sequences: building phylogenetic tree for %d %s (DECIPHER align -> phangorn NJ -> GTR+G+I ML)...\n",
              length(seqs), label))
  seqs_dna <- DNAStringSet(seqs)
  names(seqs_dna) <- names(seqs)
  alignment <- AlignSeqs(seqs_dna, anchor = NA, verbose = FALSE)

  phang_align <- phyDat(as(alignment, "matrix"), type = "DNA")
  dm <- dist.ml(phang_align)
  treeNJ <- NJ(dm)
  fit <- pml(treeNJ, data = phang_align)
  fitGTR <- update(fit, k = 4, inv = 0.2)
  fitGTR <- tryCatch(
    optim.pml(fitGTR, model = "GTR", optInv = TRUE, optGamma = TRUE,
              rearrangement = "stochastic", control = pml.control(trace = 0)),
    error = function(e) {
      cat(sprintf("build_tree_from_sequences: GTR+G+I ML refinement failed (%s) -- keeping the neighbor-joining tree unrefined rather than failing the whole run.\n",
                   conditionMessage(e)))
      fitGTR
    }
  )
  fitGTR$tree
}
