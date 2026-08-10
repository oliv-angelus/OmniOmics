# abundance.tsv (a `tax` column of ';'-separated lineage, one sample per
# remaining column, exactly the shape MAGMA/DOGMA's
# abundance_table_final_RAW.tsv already is -- see the "Pipelines stop at raw
# outputs" convention, no merge/aggregation happens before this point) +
# metadata.tsv -> a real phyloseq object. Direct translation of
# microbiome.R's section 4 ("IMPORTAÇÃO E CRIAÇÃO DO PHYLOSEQ OBJECT"), kept
# as its own file since every community-ecology analysis
# (alpha/beta/composition/core/RDA/network/IndVal/Venn) needs this same
# object built the same way.
suppressMessages({
  library(phyloseq)
  library(dplyr)
  library(tidyr)
  library(ape)
})

#' @param abundance_path Path to a `tax`(+optional `total`)-plus-samples TSV.
#' @param metadata_path  Path to a sample metadata TSV (row names = sample
#'   IDs matching the abundance table's column names). Optional -- when NULL,
#'   sample_data is just a SampleID column, enough for analyses that don't
#'   need a grouping variable (e.g. taxonomic_composition).
#' @param tree Optional list describing a real phylogenetic tree to attach
#'   (see `find_prism_tree_files` below for how load_phyloseq.R builds
#'   this) -- `list(tree_path=, counts_path=, taxonomy_path=, id_col=,
#'   rank_cols=)`. When present, the OTU/TAX table is built at ASV/species
#'   resolution from `counts_path`/`taxonomy_path` INSTEAD OF the
#'   lineage-collapsed `abundance_path` table, because `phy_tree`'s tip
#'   labels must exactly match the OTU table's own row names -- something
#'   the collapsed shape can't provide (multiple ASVs/species routinely
#'   share one lineage string). This is a deliberate resolution change, not
#'   just an additive attachment: it's also the real, standard DADA2/
#'   phyloseq-tutorial convention (Callahan et al.) to build phyloseq at
#'   ASV/OTU resolution in the first place; PRISM's lineage-collapsing
#'   path reuses MAGMA's abundance-table shape, which is convenient but
#'   coarser. When `tree` is NULL (MAGMA/DOGMA, or a PRISM run with no
#'   tree -- e.g. fewer than 3 taxa detected), the lineage-collapsed path
#'   is used instead.
#' @return A phyloseq object with OTU/TAX/SAMPLE components, plus a real
#'   phy_tree when `tree` was given.
build_phyloseq <- function(abundance_path, metadata_path = NULL, tree = NULL) {
  if (!is.null(tree)) {
    return(.build_phyloseq_asv_level(tree, metadata_path))
  }
  raw <- read.delim(abundance_path, header = TRUE, check.names = FALSE)
  if ("total" %in% colnames(raw)) {
    raw <- raw %>% select(-total)
  }

  # Rank depth genuinely varies by reference database -- confirmed against
  # real, current documentation:
  # - GTDB (what MAGMA's GTDB-Tk actually produces, confirmed against the
  # real magma_demo fixture) has always used 7 ranks: domain, phylum,
  # class, order, family, genus, species -- no kingdom, by GTDB's own
  # design.
  # - NCBI/Kraken2 taxonomy (what microbiome.R's original reference data
  # used, and current Kraken2 PlusPFP-family databases) has carried a
  # real, *formal* 8th rank -- Kingdom, sitting between Domain and
  # Phylum -- for Bacteria/Archaea only since NCBI's October 2024
  # taxonomy rollout (8 new prokaryote kingdoms, e.g. "Bacillati"
  # replacing the old informal "Terrabacteria group", "Pseudomonadati",
  # etc. -- see NCBI Insights, "NCBI Taxonomy Updates to Prokaryotes",
  # 2024-10-02). That same rollout also renamed several phyla (e.g.
  # Euryarchaeota -> Methanobacteriota), which doesn't affect field
  # count/position here but is worth knowing if a taxon name looks
  # unfamiliar. Before this, "Kingdom" was informal/unranked in NCBI's
  # own taxonomy -- so which shape a given Kraken2-derived table has can
  # depend on how recently its database was built, not just "Kraken vs
  # GTDB" as a fixed rule.
  # A single hardcoded rank-name vector is wrong for whichever shape it
  # wasn't built against -- silently shifts every column one slot (caught
  # in practice: a hardcoded 8-field split against 7-field GTDB data put
  # Species-level strings under "Genus", visible as "s__X spNNN" in a
  # Genus-level composition plot's legend instead of real genus names).
  # Detect the actual depth instead of assuming it.
  n_ranks <- max(lengths(strsplit(raw$tax, ";", fixed = TRUE)))
  rank_cols <- switch(
    as.character(n_ranks),
    "8" = c("Domain", "Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species"),
    "7" = c("Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species"),
    stop(sprintf(
      "Unexpected number of taxonomic ranks in the 'tax' column: %d (expected 7 [GTDB-style, e.g. MAGMA] or 8 [NCBI/Kraken2-style with a formal Kingdom rank, current PlusPFP-family databases]).",
      n_ranks
    ))
  )

  tax_matrix <- raw %>%
    select(tax) %>%
    separate(tax, into = rank_cols, sep = ";", fill = "right") %>%
    as.matrix

  otu_matrix <- raw %>% select(-tax) %>% as.matrix

  ids <- paste0("ASV_", seq_len(nrow(otu_matrix)))
  rownames(otu_matrix) <- ids
  rownames(tax_matrix) <- ids

  metadata <-.build_sample_data(otu_matrix, metadata_path)

  phyloseq(
    otu_table(otu_matrix, taxa_are_rows = TRUE),
    tax_table(tax_matrix),
    sample_data(metadata)
  )
}

#' Shared sample_data builder -- identical logic for both the lineage-
#' collapsed and ASV-level code paths above/below, extracted so the tree
#' addition didn't need a second copy.
.build_sample_data <- function(otu_matrix, metadata_path) {
  if (!is.null(metadata_path)) {
    metadata <- read.delim(metadata_path, header = TRUE, row.names = 1, check.names = FALSE)
    colnames(metadata) <- gsub(" ", "_", colnames(metadata))
    # Sample columns in the abundance table are the source of truth for which
    # samples exist -- a metadata.tsv with extra rows (samples not in this
    # run) is common when the same file is reused across runs, so subset
    # rather than error.
    missing_samples <- setdiff(colnames(otu_matrix), rownames(metadata))
    if (length(missing_samples) > 0) {
      stop(sprintf("metadata.tsv is missing %d sample(s) present in the abundance table: %s",
                    length(missing_samples), paste(missing_samples, collapse = ", ")))
    }
    metadata[colnames(otu_matrix),, drop = FALSE]
  } else {
    data.frame(SampleID = colnames(otu_matrix), row.names = colnames(otu_matrix))
  }
}

#' Builds a phyloseq object at real ASV/species resolution (PacBio's
#' prism_asv_counts.tsv/prism_asv_taxonomy.tsv, or the ONT/Emu path's
#' prism_species_counts.tsv/prism_species_taxonomy.tsv) with a real
#' phy_tree attached -- see build_phyloseq's own docstring for why this
#' is a separate code path rather than just tacking a tree onto the
#' lineage-collapsed shape.
#' @param tree list(tree_path=, counts_path=, taxonomy_path=, id_col=,
#'   rank_cols=) -- see find_prism_tree_files for how this gets built.
.build_phyloseq_asv_level <- function(tree, metadata_path) {
  counts <- read.delim(tree$counts_path, header = TRUE, check.names = FALSE, colClasses = "character")
  tax <- read.delim(tree$taxonomy_path, header = TRUE, check.names = FALSE, colClasses = "character")

  ids <- as.character(counts[[tree$id_col]])
  otu_matrix <- as.matrix(counts[, setdiff(colnames(counts), tree$id_col), drop = FALSE])
  storage.mode(otu_matrix) <- "numeric"
  rownames(otu_matrix) <- ids

  # Real rank-column-name variance between the two platforms' own taxonomy
  # files (PacBio's assignTaxonomy output uses DADA2's own default
  # "Kingdom" for rank 1; the Emu db's own taxonomy.tsv uses lowercase
  # "domain") is normalized here to the same "Domain/Phylum/.../Species"
  # naming the lineage-collapsed path already uses, so every downstream
  # analysis's --rank parameter (populated from tax_table's own column
  # names, see load_phyloseq.R) stays consistent regardless of which
  # platform produced the run.
  rank_cols_out <- c("Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species")
  tax <- tax[match(ids, as.character(tax[[tree$id_col]])),, drop = FALSE]
  tax_matrix <- as.matrix(tax[, tree$rank_cols, drop = FALSE])
  colnames(tax_matrix) <- rank_cols_out
  rownames(tax_matrix) <- ids

  metadata <-.build_sample_data(otu_matrix, metadata_path)
  phy_tree_obj <- read.tree(tree$tree_path)

  # phyloseq's own constructor intersects taxa names across every
  # taxa-indexed component given to it (otu_table/tax_table/phy_tree) rather
  # than erroring on a mismatch -- real, useful behavior here since the tree
  # is deliberately built only from *detected* tax_ids (build_emu_tree.R)
  # while counts/taxonomy list every reference tax_id/ASV that passed
  # upstream filtering; no manual pre-filtering needed.
  ps <- phyloseq(
    otu_table(otu_matrix, taxa_are_rows = TRUE),
    tax_table(tax_matrix),
    sample_data(metadata),
    phy_tree(phy_tree_obj)
  )
  log_line("[build_phyloseq] ASV/species-resolution phyloseq object with a real phylogenetic tree: %d taxa (tree had %d tips before intersection) x %d samples",
            ntaxa(ps), length(phy_tree_obj$tip.label), nsamples(ps))
  ps
}

#' Looks for a real PRISM phylogenetic tree (prism_tree.nwk) under a run's
#' output dir, and if found, figures out which platform produced it (by
#' which sibling file exists alongside it -- PacBio/DADA2's
#' prism_asv_taxonomy.tsv vs. the ONT/Emu path's prism_species_taxonomy.tsv,
#' see workflow/rules/04_denoise_classify.smk) so build_phyloseq knows
#' which counts/taxonomy file shape + id column + rank-column names to read.
#' Returns NULL when no tree exists for this run (MAGMA/DOGMA always; a
#' PRISM run where tree-building was skipped for <3 detected taxa; a PRISM
#' run predating this feature) -- build_phyloseq falls back to its
#' original lineage-collapsed behavior in that case, unchanged.
find_prism_tree_files <- function(input_dir) {
  tree_hits <- list.files(input_dir, pattern = "^prism_tree\\.nwk$", recursive = TRUE, full.names = TRUE)
  if (length(tree_hits) == 0) return(NULL)
  tree_path <- tree_hits[[1]]
  tree_dir <- dirname(tree_path)

  dada2_taxonomy <- file.path(tree_dir, "prism_asv_taxonomy.tsv")
  emu_taxonomy <- file.path(tree_dir, "prism_species_taxonomy.tsv")

  if (file.exists(dada2_taxonomy)) {
    list(
      tree_path = tree_path,
      counts_path = file.path(tree_dir, "prism_asv_counts.tsv"),
      taxonomy_path = dada2_taxonomy,
      id_col = "asv_id",
      rank_cols = c("Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species")
    )
  } else if (file.exists(emu_taxonomy)) {
    list(
      tree_path = tree_path,
      counts_path = file.path(tree_dir, "prism_species_counts.tsv"),
      taxonomy_path = emu_taxonomy,
      id_col = "tax_id",
      rank_cols = c("domain", "phylum", "class", "order", "family", "genus", "species")
    )
  } else {
    warning(sprintf("Found %s but no matching prism_asv_taxonomy.tsv/prism_species_taxonomy.tsv beside it -- ignoring the tree.", tree_path))
    NULL
  }
}
