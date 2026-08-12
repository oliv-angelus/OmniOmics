# Builds MAGMA's per-sample "pipeline health" object for the Plots tab: read
# cleaning (fastp/NanoPlot, before vs. after) and assembly quality
# (MetaQuast), the two things every sample goes through before anything
# taxonomic or genomic happens to it. Kept as one shape/loader rather than
# two, since both describe the SAME rows (samples) and are naturally viewed
# together -- "how clean were the reads" and "how good was the resulting
# assembly" are two questions about one pipeline run, not two different
# kinds of data the way community taxa vs. assembled MAGs are.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_read_qc_table.R"))
source(file.path(lib_dir, "build_magma_assembly_table.R"))

suppressMessages(library(jsonlite))

args <- parse_cli_args()

#' Every sample this run has, from 01_QC's own per-sample directories --
#' present regardless of whether binning/refinement later succeeded for that
#' sample, unlike deriving sample identity from a downstream stage.
.discover_samples <- function(results_dir) {
  d <- file.path(results_dir, "01_QC")
  if (!dir.exists(d)) return(character(0))
  sort(list.dirs(d, full.names = FALSE, recursive = FALSE))
}

samples <- .discover_samples(args$input)
if (length(samples) == 0) {
  stop("No samples found under 01_QC -- this run has no QC output to analyse.")
}
log_line("[load_magma_qc_table] %d sample(s): %s", length(samples), paste(samples, collapse = ", "))

qc_table <- build_read_qc_table(args$input, samples)
log_line("[load_magma_qc_table] read-cleaning QC: %s",
         if (is.null(qc_table)) "no fastp/NanoPlot output found" else sprintf("%d row(s)", nrow(qc_table)))

assembly_table <- build_magma_assembly_table(args$input, samples)
log_line("[load_magma_qc_table] assembly quality: %s",
         if (is.null(assembly_table)) "no MetaQuast output found" else sprintf("%d row(s)", nrow(assembly_table)))

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(list(qc_table = qc_table, assembly_table = assembly_table, samples = samples),
        file.path(args$out_dir, "magma_qc_table.rds"))

# No metadata-driven grouping here (deliberately) -- read-cleaning and
# assembly quality are properties of the SEQUENCING RUN, not something a
# user's own experimental grouping (site, treatment) would meaningfully
# split by. `samples` still feeds a "sample" picker the same way MAGs do,
# for a future per-sample detail view.
write_json(
  list(columns = list(), column_levels = list(), samples = samples),
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_magma_qc_table] wrote magma_qc_table.rds, metadata_columns.json")
