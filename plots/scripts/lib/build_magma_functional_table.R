# Builds MAGMA's per-sample functional-annotation table for the Plots tab.
#
# Real eggNOG-mapper v2 emapper.annotations schema (25 columns, confirmed
# against the tool's own USAGE.md) -- the same file build_dogma_table.R
# already reads for DOGMA. Every functional vocabulary eggNOG reports is
# aggregated here at load time, so switching between them in the Plots tab
# is instant instead of re-parsing the annotations per plot.
#
# Unlike DOGMA/DEFINE, MAGMA's per-sample eggNOG has no Salmon quantification
# tied to it -- MAGMA's own community abundance comes from Kraken2/Kaiju read
# classification, not per-ORF read counts on the metagenome assembly. So the
# metric here is a COUNT of functional assignments, not read abundance. A
# real, defensible metric in its own right (gene content), just answering a
# different question than DOGMA's read-weighted version.

suppressMessages({
  library(dplyr)
})

#' The eggNOG columns worth plotting as a composition, and how each one's
#' values must be split into individual terms. Free-text columns
#' (Description, Preferred_name) and bookkeeping ones (evalue, score,
#' seed_ortholog) are deliberately absent -- they aren't categorical
#' vocabularies, so a stacked composition of them would be meaningless.
#'
#' `split`:
#'   "comma" -- comma-separated list of independent terms (the usual case).
#'   "chars" -- COG_category only: eggNOG concatenates the letters of every
#'              category a gene belongs to ("EJ" = both E and J), so each
#'              CHARACTER is its own category rather than the string being
#'              one bucket. Both this additive convention and a
#'              first-letter-only one are in real use; additive is chosen so
#'              a gene is represented in every category it belongs to.
#'              DOGMA's build_dogma_table.R now applies the same rules, via
#'              its own DOGMA_COLUMN_TERM_RULES.
#' `drop`: regex of terms to discard after splitting.
MAGMA_FUNCTIONAL_COLUMNS <- list(
  COG_category = list(split = "chars", drop = NULL),
  KEGG_ko      = list(split = "comma", drop = NULL),
  # KEGG reports the SAME pathway under two namespaces -- "ko00010" (the
  # orthology-based map) and "map00010" (the reference map) -- and eggNOG
  # passes both through in this column. Keeping both would count every
  # pathway exactly twice; the "ko" form is the one eggNOG actually assigns
  # from, so the "map" duplicates are dropped.
  KEGG_Pathway = list(split = "comma", drop = "^map"),
  KEGG_Module  = list(split = "comma", drop = NULL),
  EC           = list(split = "comma", drop = NULL),
  CAZy         = list(split = "comma", drop = NULL),
  PFAMs        = list(split = "comma", drop = NULL),
  GOs          = list(split = "comma", drop = NULL)
)

# A real metagenome sample has hundreds of thousands of ORFs, and vocabularies
# like KEGG_ko or GOs have thousands of distinct terms -- keeping every one
# would make the cached .rds grow with run size for no benefit, since the
# plot only ever shows a top-N. Terms outside the top N by total count across
# the run are summed into a single "Others" row per sample, which keeps every
# percentage exact (Others is a true sum, not a sample) for any top_n at or
# below this cap.
.MAX_TERMS_PER_COLUMN <- 300

#' Splits one raw eggNOG cell into its individual terms, per the column's
#' own rule. Empty/"-" (eggNOG's own no-assignment marker) becomes the
#' explicit "Unclassified" bucket rather than being dropped -- how much of a
#' metagenome has NO functional assignment is itself a real result.
.split_terms <- function(values, spec) {
  values[is.na(values)] <- "-"
  values <- trimws(values)
  unassigned <- values == "" | values == "-"
  out <- vector("list", length(values))
  out[unassigned] <- list("Unclassified")
  idx <- which(!unassigned)
  if (length(idx) > 0) {
    if (spec$split == "chars") {
      out[idx] <- strsplit(values[idx], "", fixed = TRUE)
    } else {
      out[idx] <- strsplit(values[idx], ",", fixed = TRUE)
    }
  }
  terms <- trimws(unlist(out, use.names = FALSE))
  terms <- terms[nzchar(terms)]
  if (!is.null(spec$drop)) terms <- terms[!grepl(spec$drop, terms)]
  terms
}

#' One sample's eggNOG annotations, already aggregated to counts per term
#' for every configured column. Aggregating per sample (rather than
#' returning ORF-level rows and combining later) keeps peak memory flat in
#' the number of samples, which matters on a real run.
#'
#' Real emapper.annotations shape, same convention already proven in
#' build_dogma_table.R: eggNOG-mapper writes '##'-prefixed banner/footer
#' comment lines by default (only suppressed with --no_file_comments, which
#' this pipeline's real rule does not pass) AND the real header row itself
#' starts with a single '#' ("#query\t..."). '##' lines are dropped; the
#' header's leading '#' is preserved by comment.char="" and stripped
#' manually afterward, rather than letting read.delim's own comment handling
#' eat the header along with the banner.
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

  parts <- list()
  for (col in names(MAGMA_FUNCTIONAL_COLUMNS)) {
    if (!(col %in% colnames(df))) next
    terms <- .split_terms(df[[col]], MAGMA_FUNCTIONAL_COLUMNS[[col]])
    if (length(terms) == 0) next
    tab <- as.data.frame(table(term = terms), stringsAsFactors = FALSE)
    colnames(tab) <- c("term", "n")
    parts[[length(parts) + 1]] <- data.frame(
      sample = sample, annotation_column = col,
      term = as.character(tab$term), n = as.integer(tab$n),
      stringsAsFactors = FALSE
    )
  }
  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}

#' Long table: one row per sample x annotation_column x term, with the count
#' and that term's share of the sample's own assignments for that column.
#'
#' Shares are computed WITHIN (sample, annotation_column), so each column's
#' bars sum to 100% independently. Note this is a share of ASSIGNMENTS, not
#' of genes: a gene annotated with three PFAM domains contributes to all
#' three, which is the meaningful denominator for "what functions are
#' present" (and is exactly the same thing for COG_category, where nearly
#' every gene has a single letter).
build_magma_functional_table <- function(results_dir, samples) {
  parts <- list()
  for (s in samples) {
    row <- .read_eggnog_sample(results_dir, s)
    if (!is.null(row)) parts[[length(parts) + 1]] <- row
  }
  if (length(parts) == 0) return(NULL)
  df <- bind_rows(parts)

  # Cap distinct terms per column, keeping the run-wide top N and summing
  # everything else into "Others" (per sample, so percentages stay exact).
  keep <- df %>%
    group_by(annotation_column, term) %>%
    summarise(total = sum(n), .groups = "drop") %>%
    group_by(annotation_column) %>%
    slice_max(total, n = .MAX_TERMS_PER_COLUMN, with_ties = FALSE) %>%
    ungroup() %>%
    select(annotation_column, term) %>%
    mutate(keep = TRUE)

  df <- df %>%
    left_join(keep, by = c("annotation_column", "term")) %>%
    mutate(term = ifelse(is.na(keep) & term != "Unclassified", "Others", term)) %>%
    select(-keep) %>%
    group_by(sample, annotation_column, term) %>%
    summarise(n = sum(n), .groups = "drop") %>%
    group_by(sample, annotation_column) %>%
    mutate(pct = n / sum(n) * 100) %>%
    ungroup()

  df
}

#' The annotation columns this run actually has data for -- used to tell the
#' user which choices are real when they pick one that isn't (a run where
#' eggNOG found no CAZy hits at all, say).
magma_functional_columns_present <- function(functional_table) {
  if (is.null(functional_table)) return(character(0))
  sort(unique(functional_table$annotation_column))
}
