# Circular map of one genome -- the Proksee-style overview, as a publication
# figure.
#
# Every track is a toggle. Turning one off and pressing "Reanalisar" redraws
# without it, which is how this fits the Plots tab's compute-then-render model
# rather than needing an interactive canvas.
#
# Track order, outside in, is the convention circular genome viewers converged
# on (Proksee/CGView, Grant et al. 2023 Nucleic Acids Res 51:W484; GenoVi,
# Cumsille et al. 2023 PLoS Comput Biol 19:e1010998): coordinate ruler
# outermost, then coding sequences split by strand, then the sparse features
# worth spotting (RNA, CRISPR, AMR, BGC, prophage, IS), then GC content and GC
# skew innermost. Sparse tracks sit outside the GC ones because a handful of
# thin marks is unreadable when squeezed into the smallest radius.
#
# On a draft assembly this is several arcs, one per contig, not one closed
# circle -- and that is honest: a fragmented assembly HAS no single circle, and
# drawing one would invent adjacencies the data does not support.

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
source(file.path(lib_dir, "build_sigma_table.R"))
source(file.path(lib_dir, "build_genome_ring.R"))

suppressMessages({
  library(circlize)
  library(dplyr)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(
  max_contigs = "20", min_contig_length = "5000",
  show_cds = "true", show_rna = "true", show_crispr = "true", show_amr = "true",
  show_bgc = "true", show_prophage = "true", show_is = "true",
  show_gc = "true", show_gc_skew = "true", label_features = "true"
))
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"

on_off <- function(v, default = TRUE) {
  if (is.null(v) || v == "") return(default)
  !(tolower(v) %in% c("false", "0", "no"))
}
show <- list(
  cds = on_off(args$show_cds), rna = on_off(args$show_rna), crispr = on_off(args$show_crispr),
  amr = on_off(args$show_amr), bgc = on_off(args$show_bgc), prophage = on_off(args$show_prophage),
  is = on_off(args$show_is), gc = on_off(args$show_gc), skew = on_off(args$show_gc_skew)
)
label_features <- on_off(args$label_features)
max_contigs <- as.integer(args$max_contigs)
min_len <- as.numeric(args$min_contig_length)

if (is.null(args$genome) || args$genome == "") stop("--genome is required: pick which genome to draw.")
genome <- args$genome

log_line("[sigma_genome_ring] reading cached SIGMA table from %s", args$sigma_table_rds)
loaded <- readRDS(args$sigma_table_rds)
if (!(genome %in% loaded$genome_summary$sample)) {
  stop(sprintf("--genome '%s' is not in this run. Available: %s",
               genome, paste(sort(loaded$genome_summary$sample), collapse = ", ")))
}

# The ring reads the run folder directly rather than the cached table: it needs
# per-feature COORDINATES, and caching every feature of every genome in the
# shared .rds would grow it by orders of magnitude to serve one analysis that
# looks at a single genome at a time.
results_dir <- loaded$results_dir %||% args$results_dir
if (is.null(results_dir) || !dir.exists(results_dir)) {
  stop("This run's results directory is not recorded in the cached table -- reload the run (Trocar metadados) so the genome ring can read the per-feature coordinates.")
}

ring <- build_genome_ring(results_dir, genome)
if (is.null(ring$contigs) || nrow(ring$contigs) == 0) {
  stop(sprintf("No polished assembly found for '%s' (results/03_POLISH/%s/final_polished.fa) -- the ring is laid out on the real contig lengths, so it cannot be drawn without it.",
               genome, genome))
}
if (is.null(ring$bakta) || nrow(ring$bakta) == 0) {
  stop(sprintf("No Bakta annotation found for '%s' -- every annotation track comes from it. Enable Bakta and re-run.", genome))
}

# Small contigs are dropped rather than drawn: below a few kb a sector is a
# sliver too thin to carry any mark, and dozens of them turn the ring into a
# dashed line. Both limits are parameters, so a genuinely fragmented assembly
# can still be inspected in full.
contigs <- ring$contigs %>% filter(length >= min_len) %>% slice_head(n = max_contigs)
if (nrow(contigs) == 0) {
  stop(sprintf("No contig in '%s' is at least %s bp -- lower --min_contig_length.", genome, format(min_len, big.mark = ",")))
}
n_dropped <- nrow(ring$contigs) - nrow(contigs)
log_line("[sigma_genome_ring] %d contig(s) drawn of %d (%s bp total)",
         nrow(contigs), nrow(ring$contigs), format(sum(contigs$length), big.mark = ","))

keep_contigs <- contigs$contig
sub_contig <- function(df, contig_col = "contig") {
  if (is.null(df) || nrow(df) == 0) return(NULL)
  out <- df[df[[contig_col]] %in% keep_contigs, , drop = FALSE]
  if (nrow(out) == 0) NULL else out
}

bakta <- sub_contig(ring$bakta)
by_type <- function(keys) {
  types <- unlist(BAKTA_FEATURE_TYPES[keys], use.names = FALSE)
  out <- bakta[bakta$type %in% types, , drop = FALSE]
  if (nrow(out) == 0) NULL else out
}

# AMR/virulence hits for this genome, from the already-loaded gene-hit table.
amr <- NULL
if (!is.null(loaded$gene_hits) && nrow(loaded$gene_hits) > 0 && "start" %in% colnames(loaded$gene_hits)) {
  amr <- loaded$gene_hits %>% filter(sample == genome, !is.na(start), !is.na(end))
  amr$contig <- sub("[[:space:]].*$", "", as.character(amr$contig))
  # AMRFinder and ABRicate report overlapping hits for the same gene; one mark
  # per gene per position is what the ring should show.
  amr <- distinct(amr, contig, start, end, gene, .keep_all = TRUE)
  amr <- sub_contig(amr)
}

bgc <- sub_contig(ring$bgc)
prophage <- sub_contig(ring$prophage)
is_el <- sub_contig(ring$is)
gc <- sub_contig(ring$gc)

# --- Draw ------------------------------------------------------------------
dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

palette <- list(
  cds_fwd = "#4C78A8", cds_rev = "#72B7B2", rna = "#59A14F", crispr = "#B279A2",
  amr = "#E45756", bgc = "#F58518", prophage = "#9D755D", is = "#BAB0AC",
  gc = "#54A24B", skew_pos = "#4C78A8", skew_neg = "#E45756"
)
palette <- modifyList(palette, as.list(style$palette %||% list()))

side <- max(9, 7 + nrow(contigs) * 0.12)
drawn <- character(0)

# The whole figure as a function, called once per output device.
#
# circlize draws straight to a device instead of building an object, so there
# is no plot_final.rds for render_final.R to re-render at publication size the
# way every other analysis has. Rather than leave the ring unexportable, it is
# drawn twice here -- the preview and the 600 dpi TIFF -- from this one
# function, so the two can never drift apart.
draw_ring <- function() {
  drawn <<- character(0)
  circos.clear()
  circos.par(start.degree = 90, gap.degree = if (nrow(contigs) == 1) 2 else 1.5,
             cell.padding = c(0, 0, 0, 0), track.margin = c(0.004, 0.004))
  circos.initialize(factors = factor(contigs$contig, levels = contigs$contig),
                    xlim = as.matrix(data.frame(start = 0, end = contigs$length)))

  # Outermost: the contig ruler.
  circos.track(ylim = c(0, 1), track.height = 0.06, bg.border = NA, panel.fun = function(x, y) {
    ct <- CELL_META$sector.index
    circos.rect(CELL_META$xlim[1], 0, CELL_META$xlim[2], 1,
                col = "gray35", border = NA)
    # Written INSIDE the ruler band rather than outside it: placed outside, the
    # labels of the sectors nearest the horizontal axis run off the device and
    # get clipped, since circlize does not reserve canvas for them.
    if (nrow(contigs) <= 12) {
      circos.text(CELL_META$xcenter, 0.5, sub("^.*_", "", ct), cex = 0.5, col = "white",
                  facing = "bending.inside", niceFacing = TRUE, family = font_family)
    }
    circos.axis(h = "top", labels.cex = 0.4, major.at = pretty(CELL_META$xlim, n = 4),
                labels = paste0(round(pretty(CELL_META$xlim, n = 4) / 1000), "kb"),
                labels.facing = "clockwise", major.tick.length = mm_y(0.6))
  })


  # A single gene is invisible at genome scale, and that is not a styling
  # preference -- an 900 bp AMR gene on a 3 Mb contig covers 0.03% of the arc,
  # which is well under one pixel at any figure size a paper would use. Sparse
  # features are therefore drawn at a MINIMUM arc width, so the mark points at
  # the feature rather than rendering its length to scale. Proksee and CGView do
  # the same thing for the same reason.
  #
  # The consequence is stated rather than hidden: on the AMR/BGC/prophage/IS
  # tracks a mark's WIDTH is not the feature's length. The dense CDS track is
  # left to scale, since there a gene is one of thousands and the band's texture
  # is the information.
  .MIN_MARK_FRACTION <- 0.0035  # of the total drawn assembly

  add_feature_track <- function(df, color, height = 0.05, start_col = "start", end_col = "end",
                                widen = FALSE) {
    min_w <- if (widen) sum(contigs$length) * .MIN_MARK_FRACTION else 0
    circos.track(ylim = c(0, 1), track.height = height, bg.border = NA,
                 bg.col = adjustcolor(bg, alpha.f = 0.35), panel.fun = function(x, y) {
      ct <- CELL_META$sector.index
      d <- df[df$contig == ct, , drop = FALSE]
      if (nrow(d) == 0) return(invisible(NULL))
      s <- d[[start_col]]; e <- d[[end_col]]
      if (min_w > 0) {
        short <- (e - s) < min_w
        mid <- (s + e) / 2
        s[short] <- pmax(CELL_META$xlim[1], mid[short] - min_w / 2)
        e[short] <- pmin(CELL_META$xlim[2], mid[short] + min_w / 2)
      }
      circos.rect(s, 0.05, e, 0.95, col = color, border = NA)
    })
  }

  if (show$cds) {
    cds <- by_type("cds")
    if (!is.null(cds)) {
      # Two tracks, one per strand: gene direction is the first thing a circular
      # map is read for, and merging the strands hides it.
      add_feature_track(cds[cds$strand == "+", , drop = FALSE], palette$cds_fwd, 0.06, "start", "stop")
      add_feature_track(cds[cds$strand == "-", , drop = FALSE], palette$cds_rev, 0.06, "start", "stop")
      drawn <<- c(drawn, "CDS (+)", "CDS (-)")
    }
  }
  if (show$rna) {
    rna <- by_type(c("trna", "rrna", "tmrna", "ncrna"))
    if (!is.null(rna)) { add_feature_track(rna, palette$rna, 0.04, "start", "stop", widen = TRUE); drawn <<- c(drawn, "rRNA / tRNA / ncRNA") }
  }
  if (show$crispr) {
    cr <- by_type("crispr")
    if (!is.null(cr)) { add_feature_track(cr, palette$crispr, 0.035, "start", "stop", widen = TRUE); drawn <<- c(drawn, "CRISPR") }
  }
  if (show$amr && !is.null(amr)) { add_feature_track(amr, palette$amr, 0.04, widen = TRUE); drawn <<- c(drawn, "AMR / virulence") }
  if (show$bgc && !is.null(bgc)) { add_feature_track(bgc, palette$bgc, 0.04, widen = TRUE); drawn <<- c(drawn, "BGC") }
  if (show$prophage && !is.null(prophage)) { add_feature_track(prophage, palette$prophage, 0.04, widen = TRUE); drawn <<- c(drawn, "Prophage") }
  if (show$is && !is.null(is_el) && all(c("is_begin", "is_end") %in% colnames(is_el))) {
    add_feature_track(is_el, palette$is, 0.035, "is_begin", "is_end", widen = TRUE)
    drawn <<- c(drawn, "Insertion sequences")
  }

  if (show$gc && !is.null(gc)) {
    circos.track(ylim = range(gc$gc_pct), track.height = 0.09, bg.border = NA,
                 bg.col = adjustcolor(bg, alpha.f = 0.35), panel.fun = function(x, y) {
      d <- gc[gc$contig == CELL_META$sector.index, , drop = FALSE]
      if (nrow(d) == 0) return(invisible(NULL))
      circos.lines((d$start + d$end) / 2, d$gc_pct, col = palette$gc, area = TRUE,
                   baseline = mean(gc$gc_pct), border = NA)
    })
    drawn <<- c(drawn, "GC content")
  }
  if (show$skew && !is.null(gc)) {
    lim <- max(abs(gc$gc_skew), na.rm = TRUE)
    circos.track(ylim = c(-lim, lim), track.height = 0.09, bg.border = NA,
                 bg.col = adjustcolor(bg, alpha.f = 0.35), panel.fun = function(x, y) {
      d <- gc[gc$contig == CELL_META$sector.index, , drop = FALSE]
      if (nrow(d) == 0) return(invisible(NULL))
      mid <- (d$start + d$end) / 2
      circos.rect(d$start, 0, d$end, d$gc_skew, border = NA,
                  col = ifelse(d$gc_skew >= 0, palette$skew_pos, palette$skew_neg))
    })
    drawn <<- c(drawn, "GC skew")
  }

  title_txt <- sprintf("%s  |  %s bp in %d contig%s", genome,
                       format(sum(contigs$length), big.mark = ","), nrow(contigs),
                       if (nrow(contigs) == 1) "" else "s")
  text(0, 0, labels = paste(strwrap(title_txt, 28), collapse = "\n"),
       cex = 0.85, font = 2, family = font_family)

  if (length(drawn) > 0) {
    cols <- c("CDS (+)" = palette$cds_fwd, "CDS (-)" = palette$cds_rev,
              "rRNA / tRNA / ncRNA" = palette$rna, "CRISPR" = palette$crispr,
              "AMR / virulence" = palette$amr, "BGC" = palette$bgc,
              "Prophage" = palette$prophage, "Insertion sequences" = palette$is,
              "GC content" = palette$gc, "GC skew" = palette$skew_pos)
    legend("bottomleft", legend = drawn, fill = unname(cols[drawn]), border = NA,
           bty = "n", cex = 0.62, ncol = 1)
  }
  circos.clear()
}

png(file.path(args$out_dir, "preview.png"), width = side, height = side,
    units = "in", res = 150, bg = "white")
draw_ring()
dev.off()

# Publication copy, written now rather than by render_final.R. Its filename
# matches what the export step produces for every other analysis, so the app's
# download path finds it unchanged.
tiff(file.path(args$out_dir, "figure_final.tiff"), width = side, height = side,
     units = "in", res = 600, compression = "lzw", bg = "white")
draw_ring()
dev.off()

log_line("[sigma_genome_ring] tracks drawn: %s", paste(drawn, collapse = ", "))

counts <- list(
  cds = if (!is.null(by_type("cds"))) nrow(by_type("cds")) else 0,
  rrna = if (!is.null(by_type("rrna"))) nrow(by_type("rrna"))  else 0,
  trna = if (!is.null(by_type("trna"))) nrow(by_type("trna")) else 0,
  crispr = if (!is.null(by_type("crispr"))) nrow(by_type("crispr")) else 0,
  amr = if (!is.null(amr)) nrow(amr) else 0,
  bgc = if (!is.null(bgc)) nrow(bgc) else 0,
  prophage = if (!is.null(prophage)) nrow(prophage) else 0,
  insertion_sequences = if (!is.null(is_el)) nrow(is_el) else 0
)
write_json(
  list(analysis_id = "sigma_genome_ring", genome = genome,
       contigs_drawn = nrow(contigs), contigs_dropped = n_dropped,
       total_bp = sum(contigs$length), tracks = drawn, feature_counts = counts,
       contigs = lapply(seq_len(nrow(contigs)), function(i)
         list(contig = contigs$contig[i], length = contigs$length[i]))),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# No plot_final.rds: circlize draws straight to a device rather than building a
# ggplot object, so there is nothing to re-render the way render_final.R does
# for every other analysis. The export path writes the figure at publication
# size directly instead -- see the write below.
saveRDS(list(ring = ring, contigs = contigs, tracks = drawn),
        file.path(args$out_dir, "sigma_genome_ring.rds"))
write_style_json(list(palette = palette, legend_position = "bottomleft", show_labels = label_features,
                      background = bg, font_family = font_family),
                 file.path(args$out_dir, "default_style.json"))

log_line("[sigma_genome_ring] wrote data.json, default_style.json, sigma_genome_ring.rds, preview.png")
