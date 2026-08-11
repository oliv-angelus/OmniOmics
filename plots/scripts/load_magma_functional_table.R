# Builds MAGMA's per-sample functional-annotation object for the Plots tab:
# eggNOG-mapper's COG category calls for every predicted gene, one table per
# run. See build_magma_functional_table.R for the real column schema and
# why this is a gene-COUNT metric, not read-abundance-weighted like DOGMA's
# equivalent.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_magma_functional_table.R"))

suppressMessages(library(jsonlite))

args <- parse_cli_args()

#' Same 01_QC-based sample discovery as load_magma_qc_table.R -- present
#' regardless of whether annotation later succeeded for that sample.
.discover_samples <- function(results_dir) {
  d <- file.path(results_dir, "01_QC")
  if (!dir.exists(d)) return(character(0))
  sort(list.dirs(d, full.names = FALSE, recursive = FALSE))
}

samples <- .discover_samples(args$input)
if (length(samples) == 0) {
  stop("No samples found under 01_QC -- this run has no output to analyse.")
}

functional_table <- build_magma_functional_table(args$input, samples)
log_line("[load_magma_functional_table] functional annotation: %s",
         if (is.null(functional_table)) "no eggNOG output found" else
           sprintf("%d row(s) across %d sample(s)", nrow(functional_table), length(unique(functional_table$sample))))
if (is.null(functional_table)) {
  stop("No eggNOG-mapper output found for any sample in this run -- was eggNOG active?")
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(list(functional_table = functional_table, samples = samples),
        file.path(args$out_dir, "magma_functional_table.rds"))

write_json(
  list(columns = list(), column_levels = list(), samples = samples),
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_magma_functional_table] wrote magma_functional_table.rds, metadata_columns.json")
