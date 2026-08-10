# contagem_anotada.tsv (DEFINE's own final output -- see
# pipelines/define/workflow/rules/06_merge.smk's merge_annotated_counts rule
# and workflow/scripts/merge_annotated_counts.py) + metadata.tsv -> a plain
# counts + gene annotation + sample metadata bundle. Deliberately NOT a
# DESeqDataSet here -- which samples belong to which group (design formula)
# is chosen per-analysis (group_var), exactly like build_phyloseq.R defers
# that same choice; see deseq_helpers.R's run_deseq for where the design
# actually gets applied. DEFINE-only: this file (and everything under
# analyses/ that reads its output) is never read by MAGMA's phyloseq-shaped
# scripts, and vice versa -- separate pipelines get separate scripts, no
# shared "handles both shapes" code.
suppressMessages(library(dplyr))

# The fixed non-sample columns merge_annotated_counts.py always writes,
# regardless of which samples exist -- everything else in the table is a
# per-sample raw count column. Matching against this fixed set (rather than
# assuming sample columns are contiguous) is robust to samples happening to
# sit before/after the annotation block, which is exactly today's real
# column order (locus_tag..Length, THEN samples, THEN Gene..PFAMs).
DEFINE_ANNOTATION_COLS <- c(
  "locus_tag", "Chr", "Start", "End", "Strand", "Length",
  "Gene", "Product", "eggNOG_OGs", "COG_category", "Description",
  "GOs", "EC", "KEGG_ko", "KEGG_Pathway", "PFAMs"
)

#' @param counts_path Path to DEFINE's contagem_anotada.tsv.
#' @param metadata_path Path to a sample metadata TSV (row names = sample
#'   IDs matching the count table's sample columns). Optional, same as
#'   build_phyloseq.R -- NULL is enough for analyses that don't need a
#'   grouping variable.
#' @return list(counts = gene x sample integer matrix, gene_info = data.frame
#'   keyed by locus_tag with Chr/Start/End/Strand/Length/Gene/Product/
#'   eggNOG_OGs/COG_category/Description/GOs/EC/KEGG_ko/KEGG_Pathway/PFAMs,
#'   coldata = data.frame keyed by sample, from metadata_path).
build_count_matrix <- function(counts_path, metadata_path = NULL) {
  raw <- read.delim(counts_path, header = TRUE, check.names = FALSE)
  if (!("locus_tag" %in% colnames(raw))) {
    stop("contagem_anotada.tsv is missing its 'locus_tag' column -- is this really a DEFINE output file?")
  }

  annotation_cols <- intersect(DEFINE_ANNOTATION_COLS, colnames(raw))
  sample_cols <- setdiff(colnames(raw), DEFINE_ANNOTATION_COLS)
  if (length(sample_cols) == 0) {
    stop("No sample count columns found in contagem_anotada.tsv (every column matched the fixed annotation set) -- unexpected file shape.")
  }

  gene_info <- raw[, annotation_cols, drop = FALSE]
  rownames(gene_info) <- raw$locus_tag

  counts <- as.matrix(raw[, sample_cols, drop = FALSE])
  rownames(counts) <- raw$locus_tag
  storage.mode(counts) <- "integer"

  if (!is.null(metadata_path)) {
    metadata <- read.delim(metadata_path, header = TRUE, row.names = 1, check.names = FALSE)
    colnames(metadata) <- gsub(" ", "_", colnames(metadata))
    # Sample columns in the count table are the source of truth for which
    # samples exist -- same reasoning as build_phyloseq.R: a metadata.tsv
    # with extra rows (reused across runs) is common, subset rather than error.
    missing_samples <- setdiff(colnames(counts), rownames(metadata))
    if (length(missing_samples) > 0) {
      stop(sprintf("metadata.tsv is missing %d sample(s) present in the count table: %s",
                    length(missing_samples), paste(missing_samples, collapse = ", ")))
    }
    coldata <- metadata[colnames(counts),, drop = FALSE]
  } else {
    coldata <- data.frame(SampleID = colnames(counts), row.names = colnames(counts))
  }

  list(counts = counts, gene_info = gene_info, coldata = coldata)
}
