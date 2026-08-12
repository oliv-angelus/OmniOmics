# Everything one genome's circular map needs, gathered from the tools SIGMA
# already runs, as a set of tracks keyed by contig + coordinate.
#
# Every column and literal value here was read from the tool's own source
# code -- see docs/tool_output_samples/VERIFIED_FORMATS.md for the file and
# line of each. Nothing in this file was written from documentation or memory.
#
# The design constraint that shapes it: a track is OPTIONAL. Bakta is the only
# tool that must have run (without it there are no coordinates at all); every
# other track is a step the user may not have enabled. A missing track returns
# NULL and the ring simply does not draw that ring, rather than failing.

suppressMessages({
  library(dplyr)
})

# .read_isescan and .read_mobsuite_contigs live beside the readers that
# verified their formats, and the ring reuses them rather than keeping a second
# copy that could drift. The caller sources build_sigma_table.R first.

#' Contig names and lengths, straight from the polished assembly.
#'
#' The assembly FASTA rather than any tool's report, because the ring's
#' backbone must be the REAL contig lengths: deriving them from the largest
#' annotated coordinate would silently shorten every contig by however much
#' unannotated sequence sits at its end, and the ring would misplace
#' everything near the origin.
#'
#' Counted by line rather than through Biostrings: the dependency is not worth
#' it for summing character counts, and a bacterial assembly is small enough
#' that readLines is instant.
.read_contig_lengths <- function(results_dir, sample) {
  fa <- file.path(results_dir, "03_POLISH", sample, "final_polished.fa")
  if (!file.exists(fa) || file.size(fa) == 0) return(NULL)
  lines <- readLines(fa, warn = FALSE)
  headers <- which(startsWith(lines, ">"))
  if (length(headers) == 0) return(NULL)
  # The first whitespace-delimited token, matching what every annotation tool
  # reports as the sequence id (see .first_token in build_sigma_table.R for
  # the MOB-suite case where this mattered).
  ids <- sub("^>", "", lines[headers])
  ids <- sub("[[:space:]].*$", "", ids)
  bounds <- c(headers, length(lines) + 1)
  lens <- vapply(seq_along(headers), function(i) {
    seq_lines <- lines[(bounds[i] + 1):(bounds[i + 1] - 1)]
    sum(nchar(seq_lines))
  }, numeric(1))
  data.frame(contig = ids, length = lens, stringsAsFactors = FALSE) %>%
    arrange(desc(length))
}

#' GC content and GC skew in fixed windows along each contig.
#'
#' GC skew ((G-C)/(G+C)) is on the ring for a real reason, not decoration: in a
#' complete bacterial chromosome it changes sign at the origin and terminus of
#' replication, so the cumulative skew makes those two points visible. A draft
#' assembly split over many contigs will not show it cleanly, which is itself
#' informative about how complete the assembly is.
.gc_windows <- function(results_dir, sample, window = 5000) {
  fa <- file.path(results_dir, "03_POLISH", sample, "final_polished.fa")
  if (!file.exists(fa) || file.size(fa) == 0) return(NULL)
  lines <- readLines(fa, warn = FALSE)
  headers <- which(startsWith(lines, ">"))
  if (length(headers) == 0) return(NULL)
  ids <- sub("[[:space:]].*$", "", sub("^>", "", lines[headers]))
  bounds <- c(headers, length(lines) + 1)

  parts <- list()
  for (i in seq_along(headers)) {
    seq_str <- paste(lines[(bounds[i] + 1):(bounds[i + 1] - 1)], collapse = "")
    n <- nchar(seq_str)
    if (n < window) next
    starts <- seq(1, n - window + 1, by = window)
    chars <- strsplit(toupper(seq_str), "", fixed = TRUE)[[1]]
    g <- cumsum(chars == "G"); c_ <- cumsum(chars == "C")
    at_end <- pmin(starts + window - 1, n)
    g_win <- g[at_end] - c(0, g[starts - 1])[seq_along(starts)]
    c_win <- c_[at_end] - c(0, c_[starts - 1])[seq_along(starts)]
    gc_total <- g_win + c_win
    parts[[length(parts) + 1]] <- data.frame(
      contig = ids[i], start = starts, end = at_end,
      gc_pct = 100 * gc_total / (at_end - starts + 1),
      gc_skew = ifelse(gc_total > 0, (g_win - c_win) / gc_total, 0),
      stringsAsFactors = FALSE
    )
  }
  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}

#' Bakta's per-feature TSV -- the backbone of every annotation track.
#'
#' Real shape (bakta/io/tsv.py:25-30): FIVE '#'-prefixed banner lines, then a
#' header row that itself starts with a single '#'. Identical trap to
#' eggNOG-mapper's, and handled the same way: strip the banner by pattern,
#' keep the header via comment.char = "" and remove its '#' manually. Letting
#' read.delim's own comment handling do it eats the header along with the
#' banner.
#'
#' `Type` values are case-sensitive and deliberately inconsistent
#' (bakta/constants.py:104-121): "cds" and "crispr" are lower case while
#' "tRNA"/"rRNA"/"tmRNA" are camel. Compared exactly, never via tolower().
BAKTA_FEATURE_TYPES <- list(
  cds    = "cds",
  trna   = "tRNA",
  rrna   = "rRNA",
  tmrna  = "tmRNA",
  ncrna  = c("ncRNA", "ncRNA-region"),
  crispr = c("crispr", "crispr-repeat", "crispr-spacer"),
  is     = c("is", "mite"),
  ori    = c("oriC", "oriV", "oriT")
)

.read_bakta <- function(results_dir, sample) {
  f <- file.path(results_dir, "08_ANNOTATION", sample, "bakta", paste0(sample, ".tsv"))
  if (!file.exists(f) || file.size(f) == 0) return(NULL)
  lines <- readLines(f, warn = FALSE)
  # The banner lines start "# " (hash space); the header starts "#Sequence".
  lines <- lines[!grepl("^# ", lines)]
  if (length(lines) < 2) return(NULL)
  df <- try(read.delim(text = lines, header = TRUE, check.names = FALSE,
                       stringsAsFactors = FALSE, comment.char = ""), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  colnames(df)[1] <- sub("^#", "", colnames(df)[1])  # "#Sequence Id" -> "Sequence Id"
  if (!("Type" %in% colnames(df))) return(NULL)
  data.frame(
    contig = sub("[[:space:]].*$", "", as.character(df[["Sequence Id"]])),
    type = as.character(df$Type),
    start = suppressWarnings(as.numeric(df$Start)),
    stop = suppressWarnings(as.numeric(df$Stop)),
    strand = as.character(df$Strand),
    gene = as.character(df[["Gene"]] %||% NA),
    product = as.character(df[["Product"]] %||% NA),
    stringsAsFactors = FALSE
  )
}

#' antiSMASH region coordinates, from each region GenBank's own structured
#' comment.
#'
#' antiSMASH writes no tabular output at all, but every region .gbk carries
#' "Orig. start" and "Orig. end" in its antiSMASH-Data comment block
#' (antismash/common/secmet/features/region/helpers.py:71-72). Reading the
#' first lines of each file for those two numbers is far cheaper, and far less
#' fragile, than parsing GenBank properly -- nothing else in the record is
#' needed, since the BGC's class already comes from BiG-SCAPE.
#'
#' The contig is taken from the file name, which antiSMASH builds as
#' "{contig}.region001.gbk".
.read_antismash_regions <- function(results_dir, sample) {
  dir_as <- file.path(results_dir, "11_BGC", sample, "antismash")
  if (!dir.exists(dir_as)) return(NULL)
  gbks <- list.files(dir_as, pattern = "\\.region[0-9]+\\.gbk$", recursive = TRUE, full.names = TRUE)
  if (length(gbks) == 0) return(NULL)
  parts <- lapply(gbks, function(f) {
    head_lines <- tryCatch(readLines(f, n = 80, warn = FALSE), error = function(e) character(0))
    s_line <- grep("Orig\\. start", head_lines, value = TRUE)
    e_line <- grep("Orig\\. end", head_lines, value = TRUE)
    if (length(s_line) == 0 || length(e_line) == 0) return(NULL)
    num <- function(x) suppressWarnings(as.numeric(gsub("[^0-9]", "", x[1])))
    base <- basename(f)
    data.frame(
      contig = sub("\\.region[0-9]+\\.gbk$", "", base),
      region = sub("^.*\\.(region[0-9]+)\\.gbk$", "\\1", base),
      start = num(s_line), end = num(e_line),
      stringsAsFactors = FALSE
    )
  })
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) return(NULL)
  bind_rows(parts)
}

#' geNomad's virus summary carries an explicit `coordinates` column
#' (summary.py:670) for proviruses -- "start..end" within the host contig, or
#' NA for a contig that is viral end to end. CheckV has no coordinate column
#' of its own, which is why the prophage track reads geNomad.
.read_prophage_regions <- function(results_dir, sample) {
  dir_g <- file.path(results_dir, "10_VIRAL", sample, "genomad")
  if (!dir.exists(dir_g)) return(NULL)
  hits <- list.files(dir_g, pattern = "_virus_summary\\.tsv$", recursive = TRUE, full.names = TRUE)
  if (length(hits) == 0) return(NULL)
  df <- try(read.delim(hits[1], header = TRUE, check.names = FALSE, stringsAsFactors = FALSE), silent = TRUE)
  if (inherits(df, "try-error") || nrow(df) == 0) return(NULL)
  coords <- as.character(df[["coordinates"]] %||% NA)
  seq_name <- sub("[[:space:]].*$", "", as.character(df$seq_name))
  # A provirus's seq_name is "{contig}|provirus_{start}_{end}"; the host contig
  # is the part before the pipe. A whole-contig virus has no pipe.
  contig <- sub("\\|.*$", "", seq_name)
  starts <- suppressWarnings(as.numeric(sub("\\.\\..*$", "", coords)))
  ends <- suppressWarnings(as.numeric(sub("^.*\\.\\.", "", coords)))
  # Missing coordinates mean the whole contig is the virus.
  whole <- is.na(starts) | is.na(ends)
  data.frame(
    contig = contig,
    start = ifelse(whole, 1, starts),
    end = ifelse(whole, suppressWarnings(as.numeric(df[["length"]])), ends),
    whole_contig = whole,
    taxonomy = as.character(df[["taxonomy"]] %||% NA),
    stringsAsFactors = FALSE
  )
}

#' Every track for one genome. Bakta is required; everything else is optional
#' and comes back NULL when its tool did not run.
build_genome_ring <- function(results_dir, sample) {
  list(
    sample   = sample,
    contigs  = .read_contig_lengths(results_dir, sample),
    gc       = .gc_windows(results_dir, sample),
    bakta    = .read_bakta(results_dir, sample),
    bgc      = .read_antismash_regions(results_dir, sample),
    prophage = .read_prophage_regions(results_dir, sample),
    is       = .read_isescan(results_dir, sample),
    plasmid  = .read_mobsuite_contigs(results_dir, sample)
  )
}
