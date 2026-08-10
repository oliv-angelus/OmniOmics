# Shared body for every scripts/analyses/*.R file until the real statistics
# are implemented (see plots/manifest.yaml's header comment -- alpha_diversity
# and beta_diversity are real now, the rest are still stubs). Proves the real
# wiring end-to-end (Rscript spawn, PATH-clean conda env, arg passing, reading
# the cached phyloseq.rds /api/plots/load already built, writing data.json
# under --out_dir) without pretending to compute real statistics yet.
suppressMessages({
  library(jsonlite)
  library(phyloseq)
})

run_stub <- function(analysis_id) {
  source(file.path(this_script_dir(), "..", "lib", "io_helpers.R"))
  args <- parse_cli_args()
  log_line("[%s] stub analysis starting", analysis_id)
  log_line("[%s] phyloseq_rds: %s", analysis_id, args$phyloseq_rds)
  log_line("[%s] out dir: %s", analysis_id, args$out_dir)

  ps <- readRDS(args$phyloseq_rds)
  log_line("[%s] phyloseq object: %d taxa x %d samples", analysis_id, ntaxa(ps), nsamples(ps))

  dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)
  write_json(
    list(
      analysis_id = analysis_id,
      implemented = FALSE,
      n_taxa = ntaxa(ps),
      n_samples = nsamples(ps),
      metadata_columns = colnames(sample_data(ps)),
      parameters = args
    ),
    file.path(args$out_dir, "data.json"),
    auto_unbox = TRUE, pretty = TRUE
  )
  write_json(
    list(palette = "Dark2", legend_position = "right", labels = FALSE),
    file.path(args$out_dir, "default_style.json"),
    auto_unbox = TRUE, pretty = TRUE
  )
  log_line("[%s] wrote data.json + default_style.json (stub, not real statistics)", analysis_id)
}
