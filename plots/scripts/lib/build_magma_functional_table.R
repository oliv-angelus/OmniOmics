# Builds MAGMA's per-sample functional-annotation table for the Plots tab.
#
# Real eggNOG-mapper v2 emapper.annotations schema (25 columns, confirmed
# against the tool's own USAGE.md): COG_category is column 7, KEGG_Pathway
# column 13 -- the same columns build_dogma_table.R already reads for
# DOGMA's own functional-composition analysis. Read by column NAME (not
# position), so column order or extra columns don't break it.
#
# Unlike DOGMA/DEFINE, MAGMA's per-sample eggNOG has no Salmon quantification
# tied to it -- MAGMA's own community abundance comes from Kraken2/Kaiju
# read classification, not per-ORF read counts on the metagenome assembly.
# So the metric here is genuinely different and is named accordingly:
# ORF/gene COUNT per functional category (how many predicted genes fall into
# each COG category), not read-abundance-weighted composition. A real,
# defensible metric in its own right (gene content), just not the same
# question DOGMA's read-abundance version answers.

suppressMessages({
  library(dplyr)
})

#' One sample's eggNOG annotations -> one row per ORF with its COG_category.
#' Un-annotated ORFs (eggNOG writes "-" for "no assignment", confirmed real
#' convention) and multi-category ORFs (eggNOG can report several COG
#' letters concatenated, e.g. "EJ") are kept as their own literal value
#' rather than split -- same convention build_dogma_table.R already
#' established for this exact column, kept for consistency rather than
#' reinvented here.
#' Real emapper.annotations shape, same convention already proven in
#' build_dogma_table.R: eggNOG-mapper writes '##'-prefixed banner/footer
#' comment lines by default (only suppressed with --no_file_comments, which
#' this pipeline's real rule does not pass) AND the real header row itself
#' starts with a single '#' ("#query\t..."). '##' lines are dropped; the
#' header's leading '#' is preserved by comment.char="" and stripped
#' manually afterward, rather than letting read.delim's own comment
#' handling eat the header along with the banner.
.read_eggnog_sample <- function(results_dir, sample) {
  f <- file.path(results_dir, "09_ANNOTATION", sample, "eggnog", paste0(sample, "_annotations.emapper.annotations"))
  if (!file.exists(f) || file.size(f) == 0) return(NULL)
  lines <- readLines(f, warn = FALSE)
  lines <- lines[!grepl("^##", lines)]
  if (length(lines) < 2) return(NULL)
  df <- try(read.delim(text = lines, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE,
                       comment.char = ""), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  colnames(df)[1] <- sub("^#", "", colnames(df)[1])  # real header col1 is literally "#query"
  if (!"COG_category" %in% colnames(df)) return(NULL)
  cat <- df[["COG_category"]]
  cat[is.na(cat) | cat == "" | cat == "-"] <- "Unclassified"
  data.frame(sample = sample, cog_category = cat, stringsAsFactors = FALSE)
}

#' Long table: one row per sample x COG category, with the ORF count and the
#' category's share of that sample's own annotated genes.
build_magma_functional_table <- function(results_dir, samples) {
  parts <- list()
  for (s in samples) {
    row <- .read_eggnog_sample(results_dir, s)
    if (!is.null(row)) parts[[length(parts) + 1]] <- row
  }
  if (length(parts) == 0) return(NULL)
  orfs <- bind_rows(parts)
  orfs %>%
    group_by(sample, cog_category) %>%
    summarise(n_orfs = n(), .groups = "drop") %>%
    group_by(sample) %>%
    mutate(pct = n_orfs / sum(n_orfs) * 100) %>%
    ungroup()
}
