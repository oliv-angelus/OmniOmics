# One-time "load" step for the Plots tab: reads a pipeline run's real output
# (MAGMA's abundance_table_final_RAW.tsv, PRISM's prism_abundance_table.tsv --
# see ABUNDANCE_FILE_PATTERNS below) + a user-picked metadata.tsv, builds
# the phyloseq object ONCE, and reports back the metadata's real column
# names (and each column's detected levels) so the app can render
# group_var/reference_group as real dropdowns instead of free-text boxes.
# Every subsequent analysis run reads the cached phyloseq.rds this writes
# (--phyloseq_rds) instead of re-parsing the raw tables -- see
# POST /api/plots/load in main.py and analyses/*.R's `readRDS(args$phyloseq_rds)`.
#
# Different phyloseq-shaped pipelines name their final abundance table
# differently (MAGMA: abundance_table_final_RAW.tsv; PRISM:
# prism_abundance_table.tsv, see 04_denoise_classify.smk's
# select_abundance_table rule) -- --pipeline_id (passed by the backend, which
# already knows the parent run's pipeline_id from runs_store) picks the right
# pattern instead of hardcoding one, so a future phyloseq-shaped pipeline
# just needs an entry added here.
# MAGMA's own pattern is keyed a second level deeper, by --classifier, since
# it has TWO independently-consolidated community tables: Kraken2/Bracken
# (read-level, k-mer) and Kaiju (translated-protein) -- see
# 01_qc_tax.smk's consolidate_taxonomy / consolidate_taxonomy_kaiju. Both are
# built by the exact same build_phyloseq() call below; the only difference
# is which raw table feeds it. Defaults to kraken (the original/only
# classifier before this existed), so every caller that never passes
# --classifier keeps today's exact behavior.
MAGMA_CLASSIFIER_PATTERNS <- list(
  kraken = list(pattern = "abundance_table_final_RAW\\.tsv$"),
  kaiju = list(pattern = "abundance_table_final_kaiju_RAW\\.tsv$")
)

ABUNDANCE_FILE_PATTERNS <- list(
  magma = list(pattern = "abundance_table_final_RAW\\.tsv$"),
  # Real bug caught by a real test: PRISM's own filename
  # "prism_abundance_table.tsv" isn't unique across a run's results tree --
  # results/04_DENOISE/dada2/ and results/04_DENOISE/emu/ each write their
  # OWN copy (one real, one an empty touch-placeholder, depending on which
  # platform actually ran, see 04_denoise_classify.smk) -- and
  # list.files(pattern=)'s pattern only ever matches against the file's
  # BASENAME, never the full path (confirmed directly: a path-containing
  # pattern like "05_ABUNDANCE_TABLE/prism_abundance_table\\.tsv$" matches
  # nothing at all, even against a real file at exactly that relative path).
  # So the fix can't be "make the pattern more specific" -- it has to
  # disambiguate AFTER listing every hit. `prefer` picks the one whose full
  # path contains this substring when more than one file matches `pattern`
  # -- here, the one real, unconditionally-correct location
  # (select_abundance_table's own output directory) instead of whichever
  # per-platform branch copy happened to sort first.
  prism = list(pattern = "prism_abundance_table\\.tsv$", prefer = "/05_ABUNDANCE_TABLE/")
)
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "build_phyloseq.R"))

suppressMessages({
  library(phyloseq)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(classifier = "kraken"))
file_spec <- ABUNDANCE_FILE_PATTERNS[[args$pipeline_id]]
if (is.null(file_spec)) {
  stop(sprintf("No abundance-file pattern registered for pipeline_id '%s' -- add one to ABUNDANCE_FILE_PATTERNS in load_phyloseq.R.",
               args$pipeline_id %||% "(missing --pipeline_id)"))
}
if (args$pipeline_id == "magma") {
  file_spec <- MAGMA_CLASSIFIER_PATTERNS[[args$classifier]]
  if (is.null(file_spec)) {
    stop(sprintf("Unknown --classifier '%s' for MAGMA. Use one of: %s",
                 args$classifier, paste(names(MAGMA_CLASSIFIER_PATTERNS), collapse = ", ")))
  }
}
# The documented drop-in name for a community table built OUTSIDE any
# OmniOmics pipeline (see docs/plot_input_formats.md) -- same `tax` + one
# column per sample shape build_phyloseq.R already reads, only the filename is
# a new contract. Accepted for every phyloseq-shaped pipeline rather than
# needing its own pipeline_id, so an imported folder plots through exactly the
# same path a real run does. The pipeline's own pattern is tried FIRST: a real
# run that happens to also contain a generic file must still use its own
# table, never the drop-in.
GENERIC_ABUNDANCE_PATTERN <- "omniomics_abundance_table\\.tsv$"

log_line("[load_phyloseq] resolving input under %s (pipeline_id=%s)", args$input, args$pipeline_id)
abundance_path <- tryCatch(
  find_input_file(args$input, file_spec$pattern, prefer = file_spec$prefer),
  error = function(e) {
    generic <- tryCatch(find_input_file(args$input, GENERIC_ABUNDANCE_PATTERN), error = function(e2) NULL)
    if (is.null(generic)) stop(conditionMessage(e), call. = FALSE)
    log_line("[load_phyloseq] no %s found -- using the generic omniomics_abundance_table.tsv instead",
             file_spec$pattern)
    generic
  }
)
log_line("[load_phyloseq] abundance file (classifier=%s): %s", args$classifier, abundance_path)

if (is.null(args$metadata) || args$metadata == "") {
  stop("--metadata is required")
}

# Real phylogenetic tree, when this run actually has one (PRISM only, and
# only when >=3 taxa were detected -- see find_prism_tree_files's own
# docstring). Switches build_phyloseq to ASV/species resolution + a real
# phy_tree, unlocking UniFrac-class distances for every analysis that
# calls phyloseq::distance -- not just beta_diversity.R specifically.
tree <- find_prism_tree_files(args$input)
if (!is.null(tree)) {
  log_line("[load_phyloseq] found a real phylogenetic tree at %s -- building phyloseq at ASV/species resolution instead of the lineage-collapsed table", tree$tree_path)
}

ps <- build_phyloseq(abundance_path, args$metadata, tree = tree)
log_line("[load_phyloseq] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))
has_tree <- !is.null(tryCatch(phy_tree(ps, errorIfNULL = FALSE), error = function(e) NULL))

meta <- data.frame(sample_data(ps), check.names = FALSE)
columns <- colnames(meta)

column_levels <- lapply(columns, function(col) {
  vals <- unique(as.character(meta[[col]]))
  vals <- vals[!is.na(vals)]
  sort(vals)
})
names(column_levels) <- columns

# The real taxonomic ranks this data actually has, in real hierarchical
# order -- straight from build_phyloseq's own dynamic 7-rank (GTDB) vs.
# 8-rank (Kraken2/NCBI, with Kingdom) detection, not a hardcoded list. Every
# analysis's --rank parameter (manifest type "tax_rank") is populated from
# this instead of a fixed choices: [...] in plots/manifest.yaml, which is
# what silently left "Domain"/"Kingdom"/"Species" unselectable even when the
# user's own data actually had them (a real reported gap -- the hardcoded
# lists were transcribed from a Genus-focused subset of microbiome.R's own
# examples, not meant to be the ceiling).
tax_ranks <- colnames(tax_table(ps))

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
# Filename must match INPUT_SHAPE_INFO's own rds_filename for whichever shape
# this run is (main.py): "phyloseq.rds" for kraken/every non-MAGMA pipeline,
# "phyloseq_kaiju.rds" for MAGMA's Kaiju variant -- both shapes point back at
# this same loader script, distinguished only by --classifier.
rds_filename <- if (args$classifier == "kaiju") "phyloseq_kaiju.rds" else "phyloseq.rds"
saveRDS(ps, file.path(args$out_dir, rds_filename))

write_json(
  # has_tree: not read by anything yet (no analysis/frontend gating on it
  # today -- beta_diversity.R just gives a clear runtime error if
  # unifrac/wunifrac is picked without one, see that script), but reported
  # here since it's a real, useful fact about this run and cheap to expose
  # now rather than needing another round-trip later. Explicitly unboxed
  # (unlike columns/column_levels/tax_ranks below) so it serializes as a
  # plain JSON boolean rather than a single-element array -- the call's own
  # auto_unbox stays FALSE to keep those other fields' existing
  # always-an-array contract unchanged for whatever already reads them.
  list(columns = columns, column_levels = column_levels, tax_ranks = tax_ranks,
       has_tree = jsonlite::unbox(has_tree)),
  file.path(args$out_dir, "metadata_columns.json"),
  auto_unbox = FALSE, pretty = TRUE
)

log_line("[load_phyloseq] detected %d metadata columns: %s", length(columns), paste(columns, collapse = ", "))
log_line("[load_phyloseq] detected %d taxonomic ranks: %s", length(tax_ranks), paste(tax_ranks, collapse = ", "))
log_line("[load_phyloseq] has_tree = %s", has_tree)
log_line("[load_phyloseq] wrote phyloseq.rds, metadata_columns.json")
