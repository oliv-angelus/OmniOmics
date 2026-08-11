# Per-MAG detail view: the real content the user works with is an interactive
# table (rendered natively in Flutter from data.json's `records`, not from
# this script's own PNG) covering, per selected MAG: CheckM2 completeness/
# contamination, the MIMAG tier and the rRNA/tRNA evidence behind it, genome
# size, GTDB-Tk lineage, abundance in each sample, and every AMR/virulence
# gene hit WITH its real sequence -- protein for AMRFinder hits (matched
# 1:1 against Prodigal's own .faa by protein id), nucleotide for VFDB hits
# (sliced out of the MAG's own assembly fasta by abricate's coordinates).
#
# MAGMA pools and dereplicates bins from every sample, so a run routinely
# yields dozens of MAGs while only a handful are interesting -- --mags takes
# a comma-separated list (PlotParam's "samples" multi-select type) so those
# few can be inspected together, rather than one at a time or all at once.
#
# preview.png is a real, useful completeness-vs-contamination scatter for
# just the selected MAGs (same MIMAG reference band as
# magma_mag_quality_overview's all-MAGs version), colored by MIMAG tier --
# not the earlier per-MAG text-panel report card, which duplicated what the
# interactive table already shows better and didn't scale past a couple of
# MAGs before running out of readable space.

this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 0) return(getwd())
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))
source(file.path(lib_dir, "build_magma_mag_table.R"))

suppressMessages({
  library(dplyr)
  library(ggplot2)
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(mags = ""))

style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0

log_line("[magma_mag_summary] reading cached MAG table from %s", args$magma_mag_table_rds)
loaded <- readRDS(args$magma_mag_table_rds)
mag_table <- loaded$mag_table

selected <- trimws(unlist(strsplit(args$mags %||% "", ",")))
selected <- selected[nzchar(selected)]
if (length(selected) == 0) {
  stop("--mags is required: pick at least one MAG from this run.")
}
unknown <- setdiff(selected, mag_table$mag)
if (length(unknown) > 0) {
  stop(sprintf("Not MAGs of this run: %s. Available: %s",
               paste(unknown, collapse = ", "), paste(mag_table$mag, collapse = ", ")))
}
log_line("[magma_mag_summary] %d MAG(s) selected: %s", length(selected), paste(selected, collapse = ", "))

df <- mag_table[match(selected, mag_table$mag), , drop = FALSE]

# Gene hits are cached without sequences (see load_magma_mag_table.R -- reading
# every MAG's protein/genome fasta at load time, before any MAG is even
# picked, would be wasted I/O on a run with dozens of MAGs). The real
# sequences are fetched here, scoped to just the selected MAGs, from the raw
# pipeline output cached alongside the tables (results_dir). A run loaded
# before this existed, or whose output folder was since removed (see main.py's
# output_exists), simply gets no sequences rather than failing the analysis.
results_dir <- loaded$results_dir
gene_hits <- loaded$gene_hits
if (!is.null(gene_hits)) gene_hits <- gene_hits[gene_hits$mag %in% selected, , drop = FALSE]
if (!is.null(gene_hits) && nrow(gene_hits) > 0 && !is.null(results_dir) && dir.exists(results_dir)) {
  gene_hits <- attach_gene_sequences(gene_hits, results_dir, selected)
  n_seq <- sum(!is.na(gene_hits$sequence))
  log_line("[magma_mag_summary] resolved %d/%d gene sequence(s)", n_seq, nrow(gene_hits))
} else if (!is.null(gene_hits) && nrow(gene_hits) > 0) {
  log_line("[magma_mag_summary] results_dir unavailable -- gene hits reported without sequences")
  gene_hits$sequence <- NA_character_
  gene_hits$sequence_type <- NA_character_
}

genes_for <- function(mag) {
  if (is.null(gene_hits)) return(list())
  rows <- gene_hits[gene_hits$mag == mag, , drop = FALSE]
  if (nrow(rows) == 0) return(list())
  lapply(seq_len(nrow(rows)), function(i) {
    r <- rows[i, ]
    list(source = r$source, gene = r$gene, product = r$product %||% NA,
        class = r$class %||% NA, subclass = r$subclass %||% NA,
        pct_identity = r$pct_identity, pct_coverage = r$pct_coverage,
        sequence = r$sequence, sequence_type = r$sequence_type)
  })
}

abundance <- loaded$abundance
abundance_for <- function(mag) {
  if (is.null(abundance)) return(list())
  rows <- abundance[abundance$mag == mag & !is.na(abundance$rel_abundance), , drop = FALSE]
  if (nrow(rows) == 0) return(list())
  lapply(seq_len(nrow(rows)), function(i)
    list(sample = rows$sample[i], rel_abundance = rows$rel_abundance[i]))
}

lineage_for <- function(row) {
  ranks <- c("gtdbtk_domain", "gtdbtk_phylum", "gtdbtk_class", "gtdbtk_order",
             "gtdbtk_family", "gtdbtk_genus", "gtdbtk_species")
  present <- ranks[ranks %in% colnames(row)]
  vals <- vapply(present, function(r) as.character(row[[r]]), character(1))
  vals[is.na(vals)] <- ""
  stats::setNames(as.list(vals), sub("^gtdbtk_", "", present))
}

records <- lapply(seq_len(nrow(df)), function(i) {
  row <- df[i, , drop = FALSE]
  list(
    mag = row$mag, sample = row$sample %||% NA, dereplicated = isTRUE(row$dereplicated),
    completeness = row$checkm2_completeness, contamination = row$checkm2_contamination,
    genome_size = row$checkm2_genome_size, mimag_quality = row$mimag_quality %||% NA,
    rrna_5s = row$rrna_5s, rrna_16s = row$rrna_16s, rrna_23s = row$rrna_23s,
    trna_types = row$trna_types,
    # GUNC's chimerism check, shown alongside the MIMAG tier per the user's
    # own request -- not folded into mimag_quality itself, since chimerism
    # detection is not part of the official MIMAG standard (see
    # build_magma_mag_table.R's .read_gunc_all docstring).
    gunc_pass = if (is.na(row$gunc_pass %||% NA)) NA else isTRUE(row$gunc_pass),
    gunc_css = row$gunc_css, gunc_contamination_portion = row$gunc_contamination_portion,
    lineage = lineage_for(row),
    abundance = abundance_for(row$mag),
    genes = genes_for(row$mag)
  )
})

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "magma_mag_summary", mags = selected, records = records),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# --- preview.png: real completeness-vs-contamination scatter, MIMAG-colored,
# scoped to just the selected MAGs -- see magma_mag_quality_overview.R for the
# all-MAGs version of the same plot.
plot_df <- df[!is.na(df$checkm2_completeness) & !is.na(df$checkm2_contamination), , drop = FALSE]
if (nrow(plot_df) > 0) {
  plot_df$tier <- ifelse(is.na(plot_df$mimag_quality), "Unknown", plot_df$mimag_quality)
  palette <- resolve_palette(plot_df$tier, style)
  p <- ggplot(plot_df, aes(x = checkm2_completeness, y = checkm2_contamination)) +
    annotate("rect", xmin = 90, xmax = Inf, ymin = -Inf, ymax = 5, fill = "#2CA02C", alpha = 0.08) +
    geom_point(aes(color = tier), size = 4, alpha = 0.9, shape = 21, fill = NA, stroke = 1.5) +
    geom_text_repel(aes(label = mag), size = 3.2, family = font_family, color = "black",
                    max.overlaps = 30, box.padding = 0.4, show.legend = FALSE) +
    scale_color_manual(values = palette, name = "MIMAG") +
    labs(x = "Completeness (%)", y = "Contamination (%)") +
    base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
    theme(legend.position = "right")
  title <- if (length(selected) == 1) sprintf("MAG Summary: %s", selected) else
    sprintf("MAG Summary (%d MAGs)", length(selected))
  final_plot <- with_title_bar(p, title, size = 10, font_family = font_family)
} else {
  # No MAG in the selection has both CheckM2 numbers -- draws a plain
  # placeholder rather than crashing ggplot on an empty aesthetic mapping;
  # the interactive table below is unaffected either way.
  final_plot <- with_title_bar(
    ggplot() + theme_void(base_family = font_family) +
      annotate("text", x = 0, y = 0, label = "No completeness/contamination data for the selected MAG(s)",
              family = font_family, size = 4),
    "MAG Summary", size = 10, font_family = font_family
  )
}

width <- 9; height <- 7
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

write_style_json(default_style_for_groups(character(0), legend_position = "none", show_labels = FALSE),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(df, file.path(args$out_dir, "magma_mag_summary.rds"))

log_line("[magma_mag_summary] wrote data.json, default_style.json, magma_mag_summary.rds, preview.png, plot_final.rds")
