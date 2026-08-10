# Shared CLI-arg parsing + I/O helpers for every analyses/*.R and
# export/render_final.R script. Base R only (no optparse) so this keeps
# working even before the full r-plots env (plots/r_env/plots.yaml) is built --
# every analysis script is invoked the same way by plots_engine.build_params_args
# (a flat --flag value... argv), so one small parser here covers all of them.

#' Parses `--flag value` pairs (and bare `--flag` boolean switches) from
#' commandArgs(trailingOnly = TRUE) into a named list.
parse_cli_args <- function(defaults = list) {
  argv <- commandArgs(trailingOnly = TRUE)
  args <- defaults
  i <- 1
  while (i <= length(argv)) {
    a <- argv[i]
    if (startsWith(a, "--")) {
      key <- sub("^--", "", a)
      if (i < length(argv) && !startsWith(argv[i + 1], "--")) {
        argskey <- argv[i + 1]
        i <- i + 2
      } else {
        argskey <- TRUE
        i <- i + 1
      }
    } else {
      i <- i + 1
    }
  }
  args
}

#' Directory this running script itself lives in -- lets a script under
#' scripts/analyses/ or scripts/export/ source scripts/lib/*.R by relative
#' path regardless of the caller's cwd (plots_engine spawns Rscript with
#' cwd = the run's out_dir, not the script's own directory).
this_script_dir <- function {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}

#' Finds a file under `input_dir` (searched recursively) whose BASENAME
#' matches `pattern` -- used to locate a pipeline run's real output file
#' (e.g. abundance_table_final_RAW.tsv, contagem_anotada.tsv) without the
#' backend needing to know each pipeline's exact results-folder layout.
#' `pattern` only ever matches the file's basename, never its directory --
#' confirmed directly (R's own `list.files(pattern=)` behavior, not
#' documented clearly enough to trust without checking): a path-containing
#' pattern like "dir/file\\.tsv$" matches nothing at all, even against a
#' real file at exactly that relative path.
#' @param prefer Optional substring -- when more than one file matches
#'   `pattern` (e.g. PRISM's "prism_abundance_table.tsv" name is reused by
#'   both platform branches' own copies plus the real merged one, see
#'   04_denoise_classify.smk), the first hit whose FULL path contains this
#'   substring is preferred over plain list-order (which is really just
#'   alphabetical directory order, not a deliberate choice). Ignored/unused
#'   when NULL (the default, and MAGMA's own case -- its filename really is
#'   unique in the tree, no disambiguation ever needed there).
find_input_file <- function(input_dir, pattern, prefer = NULL) {
  hits <- list.files(input_dir, pattern = pattern, recursive = TRUE, full.names = TRUE)
  if (length(hits) == 0) {
    stop(sprintf("No file matching '%s' found under %s", pattern, input_dir))
  }
  if (!is.null(prefer) && length(hits) > 1) {
    preferred <- hits[grepl(prefer, hits, fixed = TRUE)]
    if (length(preferred) > 0) return(preferred1)
  }
  hits1
}

log_line <- function(...) {
  cat(sprintf(...), "\n")
  flush(stdout)
}

#' `a %||% b`: `b` when `a` is NULL, `a` otherwise -- used throughout the
#' analysis scripts to fall back to a default when a style field (background,
#' font_family,...) wasn't provided.
`%||%` <- function(a, b) if (is.null(a)) b else a
