# One-time "load" step for SIGMA runs in the Plots tab -- mirrors
# load_dogma_table.R's role, but SIGMA's own real shape is dense (one row
# per genome, not a sparse per-ORF long table -- see lib/build_sigma_table.R's
# header for why no LEFT-JOIN-spine design was needed for the summary part).
#
# Real, deliberate design choice: the genome-summary table's own real
# CATEGORICAL columns (GTDB-Tk's taxonomy ranks, MLST's scheme) are folded
# into the same --group_var/--reference_group "column"/"level" dropdown
# mechanism every other pipeline's metadata.tsv columns already use --
# e.g. "--group_var gtdbtk_genus" works out of the box, no metadata.tsv
# required, since taxonomy/typing genuinely IS useful grouping information
# here, not just incidental data (unlike MAGMA/DOGMA, where a real
# metadata.tsv the user prepared is the only source of grouping variables).
# User-supplied --metadata is still optional and additive on top of this.
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_sigma_table.R"))
source(file.path(lib_dir, "build_read_qc_table.R"))

suppressMessages(library(jsonlite))

args <- parse_cli_args()
log_line("[load_sigma_table] building the per-genome summary table from %s", args$input)
genome_summary <- build_sigma_table(args$input)
log_line("[load_sigma_table] genome summary: %d genome(s) x %d column(s)", nrow(genome_summary), ncol(genome_summary))

log_line("[load_sigma_table] building the AMR/virulence gene-hit table from %s", args$input)
gene_hits <- build_sigma_gene_hits(args$input)
log_line("[load_sigma_table] gene hits: %d row(s) across %d genome(s)", nrow(gene_hits), length(unique(gene_hits$sample)))

samples <- genome_summary$sample

# Before/after read cleaning, from the same fastp/NanoPlot output layout MAGMA
# uses -- shared reader, not a copy (see build_read_qc_table.R). Optional: a
# run whose QC output was cleaned up, or that started from assemblies, simply
# has no table here and the read-QC analysis says so instead of failing the
# whole load.
mobilome <- build_sigma_mobilome(args$input)
log_line("[load_sigma_table] mobilome: %s",
         paste(vapply(names(mobilome), function(k)
           sprintf("%s=%s", k, if (is.null(mobilome[[k]])) "-" else nrow(mobilome[[k]])),
           character(1)), collapse = ", "))

bgc <- build_sigma_bgc(args$input)
log_line("[load_sigma_table] BGC: %s",
         if (is.null(bgc$regions)) "no BiG-SCAPE output found" else
           sprintf("%d region(s) across %d genome(s)", nrow(bgc$regions), length(unique(bgc$regions$sample))))

qc_table <- build_read_qc_table(args$input, samples)
log_line("[load_sigma_table] read QC: %s",
         if (is.null(qc_table)) "no fastp/NanoPlot output found" else
           sprintf("%d row(s) across %d genome(s)", nrow(qc_table), length(unique(qc_table$sample))))

# Real, always-available "metadata" derived from the genome summary itself
# -- the categorical columns only (numeric QC stats like completeness/N50
# are meant for a quality-overview plot's own axes, not "pick a level"
# group_var choices; see this file's header comment for the reasoning).
SIGMA_BUILTIN_GROUP_COLS <- c("gtdbtk_domain", "gtdbtk_phylum", "gtdbtk_class", "gtdbtk_order",
                              "gtdbtk_family", "gtdbtk_genus", "gtdbtk_species", "mlst_scheme", "mlst_st")
builtin_cols <- intersect(SIGMA_BUILTIN_GROUP_COLS, colnames(genome_summary))
coldata <- genome_summary[, c("sample", builtin_cols), drop = FALSE]
rownames(coldata) <- coldata$sample
coldata$sample <- NULL

if (!is.null(args$metadata) && args$metadata != "") {
  metadata <- read.delim(args$metadata, header = TRUE, row.names = 1, check.names = FALSE)
  colnames(metadata) <- gsub(" ", "_", colnames(metadata))
  # Same "subset, don't error on extra rows" convention every other loader
  # already uses -- a metadata.tsv reused across runs is common.
  missing_samples <- setdiff(samples, rownames(metadata))
  if (length(missing_samples) > 0) {
    stop(sprintf("metadata.tsv is missing %d genome(s) present in this SIGMA run: %s",
                 length(missing_samples), paste(missing_samples, collapse = ", ")))
  }
  metadata <- metadata[samples,, drop = FALSE]
  # User-supplied columns win on a real name collision (e.g. the user's own
  # "mlst_scheme" column, unlikely but possible) -- their own data is the
  # more deliberate, specific choice.
  overlap <- intersect(colnames(metadata), colnames(coldata))
  if (length(overlap) > 0) coldata <- coldata[, setdiff(colnames(coldata), overlap), drop = FALSE]
  coldata <- cbind(coldata, metadata)
}

columns <- colnames(coldata)
column_levels <- lapply(columns, function(col) {
  vals <- unique(as.character(coldata[[col]]))
  vals <- vals[!is.na(vals)]
  sort(vals)
})
names(column_levels) <- columns

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(list(genome_summary = genome_summary, gene_hits = gene_hits, qc_table = qc_table,
             mobilome = mobilome, bgc = bgc, coldata = coldata),
        file.path(args$out_dir, "sigma_table.rds"))

write_json(
  list(columns = columns, column_levels = column_levels,
       samples = samples),  # feeds PlotParam's "sample" type -- the real per-genome picker
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_sigma_table] detected %d genome(s): %s", length(samples), paste(samples, collapse = ", "))
log_line("[load_sigma_table] detected %d groupable column(s): %s", length(columns), paste(columns, collapse = ", "))
log_line("[load_sigma_table] wrote sigma_table.rds, metadata_columns.json")
