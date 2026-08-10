# Venn diagram of taxa present (above --min_abundance) per level of
# --group_var. Up to 4 sets (ggVennDiagram's
# practical/readable limit for this kind of label-heavy diagram).
this_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir(), "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))

suppressMessages({
  library(phyloseq)
  library(dplyr)
  library(ggplot2)
  library(ggVennDiagram)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(rank = "Genus", min_abundance = "0.0"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
rank <- args$rank
min_abundance <- as.numeric(args$min_abundance)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"

log_line("[venn_diagram] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[venn_diagram] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

groups <- unique(as.character(data.frame(sample_data(ps))[[group_var]]))
groups <- groups[!is.na(groups)]
if (length(groups) < 2) stop(sprintf("group_var '%s' needs at least 2 levels to compare -- found %d.", group_var, length(groups)))
if (length(groups) > 4) {
  stop(sprintf("Venn diagrams support at most 4 sets -- '%s' has %d levels (%s). Pick a group_var with fewer levels.",
               group_var, length(groups), paste(groups, collapse = ", ")))
}

ps_rel <- transform_sample_counts(ps, function(x) x / sum(x))
ps_glom <- if (rank == "ASV") ps_rel else tax_glom(ps_rel, taxrank = rank, NArm = FALSE)
tax_info <- as.data.frame(tax_table(ps_glom))

taxon_label <- function(taxon_id) {
  if (rank == "ASV") return(taxon_id)
  label <- tax_info[taxon_id, rank]
  if (is.na(label)) "Unclassified" else label
}

present_sets <- lapply(groups, function(g) {
  ps_g <- prune_samples(sample_names(ps_glom)[data.frame(sample_data(ps_glom))[[group_var]] == g], ps_glom)
  mean_abund <- taxa_sums(ps_g) / nsamples(ps_g)
  taxon_ids <- names(mean_abund)[mean_abund > min_abundance]
  unique(vapply(taxon_ids, taxon_label, character(1)))
})
names(present_sets) <- groups

log_line("[venn_diagram] set sizes: %s", paste(sprintf("%s=%d", groups, lengths(present_sets)), collapse = ", "))

# Every non-empty intersection (2^n - 1 combinations), computed directly
# rather than relying on ggVennDiagram's internal data structures --
# straightforward and independently checkable.
all_taxa <- unique(unlist(present_sets))
intersections <- list()
for (k in seq_along(groups)) {
  combos <- combn(groups, k, simplify = FALSE)
  for (combo in combos) {
    in_all <- Reduce(intersect, present_sets[combo])
    if (length(in_all) > 0) {
      intersections[[paste(combo, collapse = " & ")]] <- in_all
    }
  }
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

intersections_json <- lapply(names(intersections), function(nm) {
  list(sets = nm, n_taxa = length(intersections[[nm]]), taxa = intersections[[nm]])
})

write_json(
  list(analysis_id = "venn_diagram", group_var = group_var, rank = rank, min_abundance = min_abundance,
       set_sizes = as.list(stats::setNames(lengths(present_sets), groups)),
       intersections = intersections_json),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# Resolved BEFORE building effective_style, so what gets written matches
# what the plot actually uses (see default_style_for_groups's docstring).
palette <- resolve_palette(groups, style)

effective_style <- default_style_for_groups(groups, legend_position = "none", show_labels = FALSE,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(present_sets = present_sets, intersections = intersections), file.path(args$out_dir, "venn_diagram.rds"))

p <- ggVennDiagram(present_sets, label = "count", set_color = unname(palette), label_alpha = 0) +
  scale_fill_distiller(palette = "Spectral", direction = -1, name = "Taxa") +
  theme(text = element_text(family = font_family), legend.position = "right",
        plot.background = element_rect(fill = bg, color = NA))

title <- paste0("Shared/Unique Taxa (", rank, ", > ", min_abundance * 100, "% mean rel. abundance): ", group_var)
final_plot <- with_title_bar(p, title, size = 7, title_height = 0.1, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 11, height = 9, units = "in", dpi = 150, bg = "white")

log_line("[venn_diagram] wrote data.json, default_style.json, venn_diagram.rds, preview.png")
