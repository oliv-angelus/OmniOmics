# Builds MAGMA's per-MAG object for the Plots tab, once per run + metadata
# pick, so every MAG analysis reads this instead of re-parsing CheckM2,
# GTDB-Tk, CoverM and the per-MAG annotations again.
#
# Deliberately separate from load_phyloseq.R even though both serve MAGMA:
# the community analyses work on read-level Kraken2/Bracken abundances, while
# these work on the assembled genomes -- different rows, different biology.
# The backend builds both for a MAGMA run (see main.py's INPUT_SHAPE_INFO).
#
# Metadata here is per SAMPLE, not per MAG: the user's metadata.tsv describes
# the sites/conditions that were sequenced, and a MAG inherits the metadata of
# the sample it was binned from.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_magma_mag_table.R"))

suppressMessages(library(jsonlite))

args <- parse_cli_args()

log_line("[load_magma_mag_table] building the per-MAG table from %s", args$input)
mag_table <- build_magma_mag_table(args$input)
log_line("[load_magma_mag_table] %d MAG(s) x %d column(s)", nrow(mag_table), ncol(mag_table))

abundance <- build_magma_mag_abundance(args$input)
log_line("[load_magma_mag_table] abundance: %s",
         if (is.null(abundance)) "no coverm_coverage.tsv found" else
           sprintf("%d MAG-sample pair(s)", nrow(abundance)))

gene_hits <- build_magma_mag_gene_hits(args$input, mag_table$mag)
log_line("[load_magma_mag_table] AMR/virulence hits: %s",
         if (is.null(gene_hits)) "none found" else sprintf("%d row(s)", nrow(gene_hits)))

mags <- mag_table$mag

# Groupable columns: the MAG's own facts first (taxonomy, quality tier,
# provenance), then whatever the user's metadata.tsv adds for its source
# sample. A MAG with no resolvable source sample (name doesn't match any
# sample directory) simply gets NA metadata rather than failing the load.
MAG_BUILTIN_GROUP_COLS <- c("sample", "dereplicated", "mimag_quality", "gunc_pass",
                            "gtdbtk_domain", "gtdbtk_phylum", "gtdbtk_class",
                            "gtdbtk_order", "gtdbtk_family", "gtdbtk_genus", "gtdbtk_species")
builtin_cols <- intersect(MAG_BUILTIN_GROUP_COLS, colnames(mag_table))
coldata <- mag_table[, builtin_cols, drop = FALSE]
rownames(coldata) <- mags

if (!is.null(args$metadata) && args$metadata != "") {
  metadata <- read.delim(args$metadata, header = TRUE, row.names = 1, check.names = FALSE)
  colnames(metadata) <- gsub(" ", "_", colnames(metadata))
  # Unlike the other loaders, a missing row is not an error: metadata is keyed
  # by sample and several MAGs map to the same sample, while a sample that
  # yielded no MAG never appears here at all.
  per_mag <- metadata[match(mag_table$sample, rownames(metadata)), , drop = FALSE]
  rownames(per_mag) <- mags
  resolved <- sum(!is.na(match(mag_table$sample, rownames(metadata))))
  log_line("[load_magma_mag_table] metadata matched for %d/%d MAG(s) via their source sample",
           resolved, length(mags))
  overlap <- intersect(colnames(per_mag), colnames(coldata))
  if (length(overlap) > 0) coldata <- coldata[, setdiff(colnames(coldata), overlap), drop = FALSE]
  coldata <- cbind(coldata, per_mag)
}

columns <- colnames(coldata)
column_levels <- lapply(columns, function(col) {
  vals <- unique(as.character(coldata[[col]]))
  vals <- vals[!is.na(vals)]
  sort(vals)
})
names(column_levels) <- columns

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
# results_dir is cached alongside the parsed tables so an analysis script
# (which normally only ever sees this .rds, not the raw pipeline output --
# see the header comment in main.py's /run endpoint) can still reach the raw
# genome/protein FASTAs on demand, e.g. magma_mag_summary.R's real gene
# sequence lookup. Only the tables above are meant to be read blindly; a
# script using results_dir must handle files that may no longer exist (see
# main.py's output_exists check on runs generally).
saveRDS(list(mag_table = mag_table, abundance = abundance, gene_hits = gene_hits, coldata = coldata,
            results_dir = args$input),
        file.path(args$out_dir, "magma_mag_table.rds"))

write_json(
  # `samples` feeds PlotParam's MAG picker -- the same mechanism SIGMA uses to
  # choose which genome to work on, here listing this run's real MAGs.
  list(columns = columns, column_levels = column_levels, samples = mags),
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_magma_mag_table] detected %d MAG(s): %s", length(mags), paste(mags, collapse = ", "))
log_line("[load_magma_mag_table] detected %d groupable column(s): %s", length(columns), paste(columns, collapse = ", "))
log_line("[load_magma_mag_table] wrote magma_mag_table.rds, metadata_columns.json")
