# Real co-occurrence network analysis (per-group Spearman correlation
# networks among the top N taxa), direct translation of microbiome.R's
# section 13. One network per level of --group_var, combined into a single
# preview grid. See plots/manifest.yaml for parameter descriptions.
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
  library(igraph)
  library(ggraph)
  library(ggplot2)
  library(patchwork)
  library(Hmisc)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(rank = "Genus", top_n = "25", cor_cutoff = "0.6", p_cutoff = "0.05", seed = "123"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
rank <- args$rank
top_n_taxa <- as.integer(args$top_n)
cor_cutoff <- as.numeric(args$cor_cutoff)
p_cutoff <- as.numeric(args$p_cutoff)
seed <- as.integer(args$seed)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"

log_line("[cooccurrence_network] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[cooccurrence_network] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

groups <- unique(as.character(data.frame(sample_data(ps))[[group_var]]))
groups <- groups[!is.na(groups)]

build_group_network <- function(group) {
  # Real bug, reproduced: phyloseq::subset_samples evaluates its filter
  # expression via NSE against the sample_data data.frame's own columns as
  # the environment (`eval(substitute(...), envir = data.frame(sample_data))`
  # internally) -- it can't see `group`, this function's own local
  # parameter, since that's not a sample_data column, and crashed with
  # "object 'group' not found". Sidestepped subset_samples's NSE entirely:
  # compute the keep-list in plain base R first, then prune_samples by
  # name, which takes a plain character vector, no NSE trap.
  keep <- sample_names(ps)[data.frame(sample_data(ps))[[group_var]] == group]
  ps_sub <- prune_samples(keep, ps)
  ps_sub <- prune_taxa(taxa_sums(ps_sub) > 0, ps_sub)

  # Hmisc::rcorr errors outright ("must have >4 observations") below this --
  # confirmed against a 1-sample-per-group pilot-study-shaped
  # fixture, where a group this small can't support a correlation network at
  # all. Skipped the same way a group with no correlations meeting the
  # cutoffs already is (see the sum(cor_matrix != 0) == 0 check below),
  # rather than crashing the whole analysis over one under-sampled group.
  if (nsamples(ps_sub) <= 4) {
    log_line("[cooccurrence_network] %s: only %d sample(s), need > 4 to compute correlations -- skipped",
              group, nsamples(ps_sub))
    return(NULL)
  }

  ps_glom <- tax_glom(ps_sub, taxrank = rank, NArm = FALSE)
  top_taxa <- names(sort(taxa_sums(ps_glom), decreasing = TRUE)[seq_len(min(top_n_taxa, ntaxa(ps_glom)))])
  ps_net <- prune_taxa(top_taxa, ps_glom)

  otu_net <- as.matrix(otu_table(ps_net))
  if (!taxa_are_rows(ps_net)) otu_net <- t(otu_net)

  cor_result <- Hmisc::rcorr(t(otu_net), type = "spearman")
  cor_matrix <- cor_result$r
  p_matrix <- cor_result$P
  cor_matrix[abs(cor_matrix) < cor_cutoff] <- 0
  cor_matrix[p_matrix > p_cutoff] <- 0
  diag(cor_matrix) <- 0

  if (sum(cor_matrix != 0) == 0) {
    log_line("[cooccurrence_network] %s: no correlation met the cutoffs -- skipped", group)
    return(NULL)
  }

  net_obj <- graph_from_adjacency_matrix(cor_matrix, mode = "undirected", weighted = TRUE)
  tax_info <- as.data.frame(tax_table(ps_net))
  total_reads <- sum(taxa_sums(ps_net))

  V(net_obj)$Abundance <- (taxa_sums(ps_net)[V(net_obj)$name] / total_reads) * 100
  V(net_obj)$Phylum <- tax_info[V(net_obj)$name, "Phylum"]
  V(net_obj)$TaxonName <- tax_info[V(net_obj)$name, rank]
  E(net_obj)$Interaction <- E(net_obj)$weight
  E(net_obj)$Sign <- ifelse(E(net_obj)$Interaction > 0, "Positive", "Negative")
  E(net_obj)$weight <- abs(E(net_obj)$weight)

  edge_df <- igraph::as_data_frame(net_obj, what = "edges")
  edge_table <- data.frame(taxon_a = edge_df$from, taxon_b = edge_df$to,
                            spearman_rho = E(net_obj)$Interaction, interaction_type = E(net_obj)$Sign)
  node_table <- igraph::as_data_frame(net_obj, what = "vertices") %>%
    dplyr::mutate(degree = degree(net_obj), betweenness = betweenness(net_obj), closeness = closeness(net_obj)) %>%
    dplyr::arrange(dplyr::desc(degree))

  phyla <- unique(V(net_obj)$Phylum)
  colors_phylum <- resolve_palette(phyla, style)

  set.seed(seed)
  p <- ggraph(net_obj, layout = "fr") +
    geom_edge_link(aes(edge_width = abs(Interaction), edge_alpha = abs(Interaction), color = Sign)) +
    scale_edge_color_manual(values = c(Positive = "green4", Negative = "red3"), name = "Correlation") +
    scale_edge_width(range = c(0.5, 2.5), guide = "none") +
    scale_edge_alpha(range = c(0.4, 0.8), guide = "none") +
    geom_node_point(aes(size = Abundance, fill = Phylum), shape = 21, color = "black", stroke = 0.5) +
    geom_node_text(aes(label = TaxonName), repel = TRUE, size = 3, fontface = "italic", family = font_family, color = "black") +
    scale_fill_manual(values = colors_phylum, name = "Phylum") +
    scale_size_continuous(range = c(3, 10), name = "Rel. Abundance (%)") +
    guides(fill = guide_legend(override.aes = list(size = 6))) +
    theme_void() +
    theme(
      text = element_text(family = font_family),
      legend.position = "right",
      legend.title = element_text(face = "bold", size = 9),
      legend.text = element_text(size = 8),
      panel.background = element_rect(fill = bg, color = NA),
      plot.background = element_rect(fill = "white", color = NA),
      panel.border = element_rect(color = "black", fill = NA, linewidth = 0.5)
    )

  title <- paste0(group, "  |  Top ", top_n_taxa, " ", rank, ", rho > ", cor_cutoff, ", p < ", p_cutoff)
  list(plot = with_title_bar(p, title, size = 5, title_height = 0.12, font_family = font_family),
       edges = edge_table, nodes = node_table, group = group, palette = colors_phylum)
}

results_by_group <- lapply(groups, build_group_network)
names(results_by_group) <- groups
results_by_group <- Filter(Negate(is.null), results_by_group)

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

if (length(results_by_group) == 0) {
  log_line("[cooccurrence_network] no group produced a network meeting the cutoffs -- writing an empty result, no plot")
  write_json(list(analysis_id = "cooccurrence_network", group_var = group_var, groups = list()),
             file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE)
  quit(save = "no", status = 0)
}

groups_json <- lapply(results_by_group, function(r) {
  list(
    group = r$group,
    edges = lapply(seq_len(nrow(r$edges)), function(i) as.list(r$edges[i, ])),
    nodes = lapply(seq_len(nrow(r$nodes)), function(i) as.list(r$nodes[i, c("name", "Phylum", "TaxonName", "Abundance", "degree", "betweenness", "closeness")]))
  )
})

write_json(
  list(analysis_id = "cooccurrence_network", group_var = group_var, groups = groups_json),
  file.path(args$out_dir, "data.json"), auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# Named palette exported for editing is the FIRST group's -- each group's
# network independently computes its own phylum set (same reasoning as
# taxonomic_composition's per-rank palette), so there's no single shared
# key space across every group's panel; still a real, useful starting
# point since phyla are typically shared across most groups in practice.
effective_style <- list(
  palette = as.list(results_by_group[[1]]$palette),
  legend_position = "right", show_labels = TRUE,
  background = bg, font_family = font_family
)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(results_by_group, file.path(args$out_dir, "cooccurrence_network.rds"))

n_groups <- length(results_by_group)
final_plot <- patchwork::wrap_plots(lapply(results_by_group, function(r) r$plot), ncol = min(2, n_groups))
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 9 * min(2, n_groups), height = 8 * ceiling(n_groups / min(2, n_groups)),
       units = "in", dpi = 120, bg = "white", limitsize = FALSE)

log_line("[cooccurrence_network] wrote data.json, default_style.json, cooccurrence_network.rds, preview.png (%d group network(s))", n_groups)
