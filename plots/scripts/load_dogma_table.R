# One-time "load" step for DOGMA runs in the Plots tab -- mirrors
# load_phyloseq.R/load_count_matrix.R's role (build the cached object ONCE,
# every analysis then reads it instead of re-parsing DOGMA's ~10 separate
# per-tool tables per run), but DOGMA's own shape needs its own loader:
# there's no single pre-merged table to just read (see build_dogma_table.R's
# header for why, and notes/DOGMA.md's "deliberately NOT one merged table"
# section for the full design reasoning this loader implements).
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir, "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_dogma_table.R"))

suppressMessages(library(jsonlite))

args <- parse_cli_args

if (is.null(args$metadata) || args$metadata == "") {
  stop("--metadata is required")
}

log_line("[load_dogma_table] building the merged per-ORF table from %s", args$input)
long_table <- build_dogma_table(args$input)

metadata <- read.delim(args$metadata, header = TRUE, row.names = 1, check.names = FALSE)
colnames(metadata) <- gsub(" ", "_", colnames(metadata))

sample_domain_map <- unique(long_table[, c("sample", "domain", "sample_domain")])
n_domains <- length(unique(long_table$domain))

# Real samples in the data are the source of truth (same "subset, don't
# error on a metadata.tsv with extra rows" convention build_phyloseq.R/
# build_count_matrix.R already use) -- checked against the BASE sample
# name (metadata is one row per real sample, never per sample_domain unit;
# a user picking a plain sample-sheet-shaped metadata.tsv shouldn't need to
# know about DOGMA's internal domain-splitting to use it).
missing_samples <- setdiff(unique(sample_domain_map$sample), rownames(metadata))
if (length(missing_samples) > 0) {
  stop(sprintf("metadata.tsv is missing %d sample(s) present in the DOGMA run: %s",
               length(missing_samples), paste(missing_samples, collapse = ", ")))
}

# Real, load-bearing replication step for the mode=both case: since
# sample_domain (not sample) is the actual comparable unit downstream (see
# build_dogma_table.R's own comment on why), each real metadata row is
# repeated once per domain that sample_domain unit belongs to, and a
# synthetic `domain` column is ADDED (not overwritten if the user's own
# metadata.tsv already happens to have one -- real column takes priority,
# see the rename below) so "prokaryote vs eukaryote expression" is always
# at least available as a --group_var choice even without the user having
# to prepare that column by hand.
coldata <- metadata[sample_domain_map$sample,, drop = FALSE]
rownames(coldata) <- sample_domain_map$sample_domain
if (n_domains > 1 && !("domain" %in% colnames(coldata))) {
  coldata$domain <- sample_domain_map$domain
}

log_line("[load_dogma_table] %d sample x domain unit(s), %d ORF rows total", nrow(coldata), nrow(long_table))

# Real, curated set (see build_dogma_table.R's DOGMA_ANNOTATION_COLUMNS) --
# only the ones actually present in THIS run's data get offered, since most
# of the *cycDB/CANT-HYD/FeGenie annotators are optional extras that won't
# all be active in a given run.
annotation_columns <- intersect(DOGMA_ANNOTATION_COLUMNS, colnames(long_table))
if (length(annotation_columns) == 0) {
  warning("No functional/taxonomic annotation columns found at all -- was eggNOG-mapper (or any other annotation extra) active for this run? Composition/differential-abundance-by-gene-family analyses need at least one.")
}

meta <- coldata
columns <- colnames(meta)
column_levels <- lapply(columns, function(col) {
  vals <- unique(as.character(metacol))
  vals <- vals[!is.na(vals)]
  sort(vals)
})
names(column_levels) <- columns

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(list(long_table = long_table, coldata = coldata), file.path(args$out_dir, "dogma_table.rds"))

write_json(
  list(columns = columns, column_levels = column_levels, annotation_columns = annotation_columns),
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_dogma_table] detected %d metadata columns: %s[[", length(columns), paste(columns, collapse = "]], "))
log_line("[load_dogma_table] detected %d usable annotation columns: %s[[", length(annotation_columns), paste(annotation_columns, collapse = "]], "))
log_line("[load_dogma_table] wrote dogma_table.rds, metadata_columns.json")
