# Per-MAG detail view: the "report card" for one or several MAGs picked out
# of everything a run recovered. MAGMA pools and dereplicates bins from every
# sample, so a run routinely yields dozens of MAGs while only a handful are
# actually interesting -- --mags takes a comma-separated list (PlotParam's
# "samples" multi-select type) so those few can be inspected side by side,
# rather than one at a time or all at once.
#
# Shows, per MAG: CheckM2 completeness/contamination, the MIMAG tier and the
# evidence behind it (5S/16S/23S rRNA presence and tRNA type count), genome
# size, GTDB-Tk lineage, whether it survived dereplication, its abundance in
# each sample, and its AMR/virulence hits -- the facts a cross-MAG comparison
# (magma_mag_quality_overview / magma_mag_abundance) deliberately flattens away.

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

suppressMessages({
  library(dplyr)
  library(ggplot2)
  library(patchwork)
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

fmt_num <- function(x, digits = 2) {
  if (length(x) == 0 || is.na(x)) return("n/a")
  formatC(as.numeric(x), format = "f", digits = digits, big.mark = ",")
}
fmt_mb <- function(x) if (is.na(x)) "n/a" else sprintf("%.2f Mb", as.numeric(x) / 1e6)
fmt_lineage <- function(row) {
  ranks <- c("gtdbtk_phylum", "gtdbtk_class", "gtdbtk_order",
             "gtdbtk_family", "gtdbtk_genus", "gtdbtk_species")
  present <- ranks[ranks %in% colnames(row)]
  vals <- vapply(present, function(r) as.character(row[[r]]), character(1))
  vals <- vals[!is.na(vals) & nzchar(vals)]
  if (length(vals) == 0) return("unclassified")
  paste(vals, collapse = " > ")
}
# The tier label already carries its own caveat when the rRNA/tRNA evidence
# could not be read (see build_magma_mag_table.R's .mimag_tier), so the
# evidence line reports the raw counts and lets the tier speak for itself.
fmt_evidence <- function(row) {
  rr <- c(row$rrna_5s, row$rrna_16s, row$rrna_23s)
  rrna_txt <- if (all(is.na(rr))) "not available" else
    sprintf("5S %s / 16S %s / 23S %s",
            ifelse(is.na(rr[1]), "?", rr[1]), ifelse(is.na(rr[2]), "?", rr[2]),
            ifelse(is.na(rr[3]), "?", rr[3]))
  trna_txt <- if (is.na(row$trna_types)) "not available" else sprintf("%d types", row$trna_types)
  paste0("rRNA ", rrna_txt, "  |  tRNA ", trna_txt)
}

abundance <- loaded$abundance
gene_hits <- loaded$gene_hits

build_fields <- function(row) {
  mag <- row$mag
  ab <- if (is.null(abundance)) NULL else abundance[abundance$mag == mag & !is.na(abundance$rel_abundance), , drop = FALSE]
  ab_txt <- if (is.null(ab) || nrow(ab) == 0) "n/a" else
    paste(sprintf("%s %.2f%%", ab$sample, ab$rel_abundance), collapse = "   ")
  hits <- if (is.null(gene_hits)) NULL else gene_hits[gene_hits$mag == mag, , drop = FALSE]
  hits_txt <- if (is.null(hits) || nrow(hits) == 0) "none detected" else
    paste(sprintf("%s: %d", names(table(hits$source)), as.integer(table(hits$source))), collapse = "   ")
  list(
    c("Source sample",  as.character(row$sample %||% NA)),
    c("Dereplicated",   if (isTRUE(row$dereplicated)) "yes" else "no"),
    c("Completeness",   paste0(fmt_num(row$checkm2_completeness), " %")),
    c("Contamination",  paste0(fmt_num(row$checkm2_contamination), " %")),
    c("Genome size",    fmt_mb(row$checkm2_genome_size)),
    c("MIMAG tier",     as.character(row$mimag_quality %||% NA)),
    c("MIMAG evidence", fmt_evidence(row)),
    c("GTDB-Tk lineage", fmt_lineage(row)),
    c("Abundance",      ab_txt),
    c("AMR / virulence", hits_txt)
  )
}

# A full GTDB-Tk lineage is far wider than the panel, and geom_text neither
# wraps nor shrinks on its own, so long values are wrapped here and each row
# is given a height proportional to its own line count. Without that the
# lineage is silently clipped at the panel edge -- the same class of overflow
# wrap_title_to_width fixes for titles (see plot_theme.R).
.VALUE_WRAP_CHARS <- 58

panel_for <- function(row) {
  fields <- build_fields(row)
  labels <- vapply(fields, function(f) f[1], character(1))
  values <- vapply(fields, function(f) ifelse(is.na(f[2]) | !nzchar(f[2]), "n/a", f[2]), character(1))
  wrapped <- vapply(values, function(v) paste(strwrap(v, width = .VALUE_WRAP_CHARS), collapse = "\n"),
                    character(1), USE.NAMES = FALSE)
  n_lines <- vapply(wrapped, function(v) length(strsplit(v, "\n", fixed = TRUE)[[1]]), integer(1),
                    USE.NAMES = FALSE)

  # Rows stack downward from the top; each row's centre sits half its own
  # height below the previous row's bottom, so a two-line value pushes the
  # rows under it down instead of overlapping them.
  heights <- n_lines + 0.55
  bottoms <- cumsum(heights)
  centres <- bottoms - heights / 2
  total <- sum(heights)
  d <- data.frame(y = total - centres, label = labels, value = wrapped, stringsAsFactors = FALSE)

  ggplot(d) +
    geom_text(aes(x = 0, y = y, label = label), hjust = 0, vjust = 0.5,
              size = 3.6 * font_scale, family = font_family, fontface = "bold") +
    geom_text(aes(x = 0.32, y = y, label = value), hjust = 0, vjust = 0.5,
              size = 3.6 * font_scale, family = font_family, lineheight = 0.95) +
    scale_x_continuous(limits = c(0, 1.5), expand = c(0, 0)) +
    scale_y_continuous(limits = c(-0.2, total + 0.2), expand = c(0, 0)) +
    labs(title = row$mag) +
    theme_void(base_family = font_family) +
    theme(plot.background = element_rect(fill = bg, color = NA),
          plot.title = element_text(face = "bold", size = 11 * font_scale, hjust = 0,
                                    margin = margin(b = 6)),
          plot.margin = margin(10, 10, 10, 10))
}

panels <- lapply(seq_len(nrow(df)), function(i) panel_for(df[i, , drop = FALSE]))

n_cols <- min(2, length(panels))
n_rows <- ceiling(length(panels) / n_cols)
combined <- wrap_plots(panels, ncol = n_cols)

title <- if (length(selected) == 1) sprintf("MAG Summary: %s", selected) else
  sprintf("MAG Summary (%d MAGs)", length(selected))
final_plot <- with_title_bar(combined, title, size = 10, font_family = font_family)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(analysis_id = "magma_mag_summary",
       mags = selected,
       records = lapply(seq_len(nrow(df)), function(i) {
         row <- df[i, , drop = FALSE]
         fields <- build_fields(row)
         stats::setNames(
           as.list(vapply(fields, function(f) f[2], character(1))),
           vapply(fields, function(f) f[1], character(1))
         )
       })),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE
)
write_style_json(default_style_for_groups(character(0), legend_position = "none", show_labels = FALSE),
                 file.path(args$out_dir, "default_style.json"))
saveRDS(df, file.path(args$out_dir, "magma_mag_summary.rds"))

width <- 7 * n_cols
height <- max(4.5, 3.8 * n_rows)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = width, height = height, units = "in", dpi = 150, bg = "white", limitsize = FALSE)
saveRDS(list(plot = final_plot, width = width, height = height),
        file.path(args$out_dir, "plot_final.rds"))

log_line("[magma_mag_summary] wrote data.json, default_style.json, magma_mag_summary.rds, preview.png, plot_final.rds")
