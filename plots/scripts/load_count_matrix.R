# One-time "load" step for the Plots tab, DEFINE's counterpart to
# load_phyloseq.R (MAGMA-only) -- reads DEFINE's real output
# (contagem_anotada.tsv) + a user-picked metadata.tsv, builds the
# counts+annotation+coldata bundle ONCE, and reports back the metadata's
# real column names + each column's detected values (same "column"/"level"
# dropdown mechanism plot_param_form.dart already has, reused unchanged).
# Every subsequent DEFINE analysis run reads the cached.rds this writes
# (--count_matrix_rds) instead of re-parsing the raw tables -- see
# POST /api/plots/load in main.py (input_shape-routed) and
# analyses/*.R's `readRDS(args$count_matrix_rds)`. DEFINE-only, mirrors but
# never shares code with load_phyloseq.R.
this_script_dir <- function {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir, "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_count_matrix.R"))

suppressMessages(library(jsonlite))

args <- parse_cli_args

log_line("[load_count_matrix] resolving input under %s", args$input)
counts_path <- find_input_file(args$input, "contagem_anotada\\.tsv$")
log_line("[load_count_matrix] counts file: %s", counts_path)

if (is.null(args$metadata) || args$metadata == "") {
  stop("--metadata is required")
}

count_data <- build_count_matrix(counts_path, args$metadata)
log_line("[load_count_matrix] count matrix: %d genes x %d samples", nrow(count_data$counts), ncol(count_data$counts))

columns <- colnames(count_data$coldata)

column_levels <- lapply(columns, function(col) {
  vals <- unique(as.character(count_data$coldatacol))
  vals <- vals[!is.na(vals)]
  sort(vals)
})
names(column_levels) <- columns

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(count_data, file.path(args$out_dir, "count_matrix.rds"))

write_json(
  list(columns = columns, column_levels = column_levels),
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_count_matrix] detected %d metadata columns: %s", length(columns), paste(columns, collapse = ", "))
log_line("[load_count_matrix] wrote count_matrix.rds, metadata_columns.json")
