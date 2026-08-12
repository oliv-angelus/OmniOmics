# Plotting data OmniOmics did not produce

The Plots tab normally works on runs launched from the app. It can also be
pointed at a folder directly — **Plots → Importar pasta** — which covers three
real situations:

1. a run produced on another machine, or copied off a cluster;
2. a run this installation once had but no longer lists (settings reset, new
   machine, app reinstalled);
3. a table you built yourself, with no OmniOmics pipeline involved at all.

The folder is only **read**. Nothing is written into it, and nothing is moved.
Importing records where the folder is, so it appears in the run list.

For cases 1 and 2 there is nothing to prepare: point at the run directory (the
one containing `results/`, or `results/` itself) and the scan recognises it.
The rest of this document is about case 3.

---

## What the scan looks for

Every input the Plots tab can build is called an *input shape*. The scan reports
which shapes a folder can produce and which analyses that unlocks, before you
commit to importing.

| Input shape | Recognised by | Unlocks |
|---|---|---|
| `phyloseq` | `abundance_table_final_RAW.tsv` (MAGMA), `prism_abundance_table.tsv` (PRISM), or **`omniomics_abundance_table.tsv`** | community/diversity analyses |
| `count_matrix` | `contagem_anotada.tsv` (DEFINE) or **`omniomics_count_matrix.tsv`** | differential-expression analyses |
| `phyloseq_kaiju` | `abundance_table_final_kaiju_RAW.tsv` | MAGMA's classifier comparison |
| `magma_mags` | genome FASTAs under `07_DEREP/all_hq_mags/` or `06_MAG_REFINEMENT/` | MAG summary |
| `magma_qc` | `*_fastp.json`, `NanoStats.txt`, or MetaQuast's `transposed_report.tsv` | read-QC and assembly plots |
| `magma_functional` | `*_annotations.emapper.annotations` under `09_ANNOTATION/` | functional composition |
| `dogma_annotated` | `*_transdecoder.pep` | DOGMA's per-ORF analyses |
| `sigma_genomes` | `quality_report.tsv` under `05_QUALITY/` | genome summary, AMR heatmap |

The two names in bold are the **drop-in formats**: filenames that exist purely
so data from outside OmniOmics has a documented way in. Everything else in the
table is a pipeline's own output, recognised where that pipeline writes it.

A pipeline's own filename always wins over a drop-in of the same shape, so
adding a generic file to a real run folder can never silently replace the run's
own table.

---

## Drop-in format 1 — community table

**Filename:** `omniomics_abundance_table.tsv` (tab-separated)

One row per taxon, one column per sample.

| Column | Required | Contents |
|---|---|---|
| `tax` | yes | the full lineage, ranks separated by `;` |
| one per sample | yes | integer read counts |
| `total` | no | ignored if present (dropped on load) |

The `tax` column is the only thing that needs care, and it has one hard
requirement: **every lineage must have exactly 7 or 8 ranks**, semicolon
separated, outermost first.

- **7 ranks** — Domain, Phylum, Class, Order, Family, Genus, Species. This is
  GTDB's own shape (GTDB has no Kingdom rank by design).
- **8 ranks** — Domain, Kingdom, Phylum, …, Species. This is what current
  NCBI/Kraken2 databases produce, since NCBI's October 2024 rollout made
  Kingdom a formal rank for prokaryotes.

Any other depth is refused, with a message saying which it found: a 6-rank
lineage cannot be told apart from a 7-rank one missing a field, and guessing
would silently shift every name one rank over. The depth is taken from the
**deepest** row, and shorter rows are padded on the right — so a lineage that
stops at family is fine as long as the table as a whole is 7 or 8 deep.

Rank prefixes (`d__`, `k__`, `p__`, …) are accepted, and are **kept as written**
— they are not stripped. They will appear in plot legends exactly as they are in
your file, so leave them out if you do not want to see them.

```
tax	sample_A	sample_B	sample_C
d__Bacteria;p__Bacillota;c__Bacilli;o__Bacillales;f__Bacillaceae;g__Bacillus;s__Bacillus subtilis	4213	1180	903
d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Pseudomonadales;f__Pseudomonadaceae;g__Pseudomonas;s__Pseudomonas putida	872	3341	4102
d__Archaea;p__Thermoproteota;c__Nitrososphaeria;o__Nitrososphaerales;f__Nitrososphaeraceae;g__Nitrososphaera;s__Nitrososphaera viennensis	311	120	88
```

Notes that matter in practice:

- **Counts, not proportions.** Several analyses rarefy or model counts
  (DESeq2, rarefaction, Good's coverage) and are meaningless on
  already-normalised values.
- **A missing rank becomes `Unclassified`** at plot time rather than dropping
  the row, so a partially-resolved lineage still contributes its counts.
- **Sample names must match the metadata table exactly**, including case.

### Optional: a phylogenetic tree

UniFrac and weighted UniFrac need a real tree, which is why they are refused on
data that has none. To supply one, put these three files in the same folder:

| File | Contents |
|---|---|
| `prism_tree.nwk` | Newick tree; tip labels are the feature IDs |
| `prism_asv_counts.tsv` | `asv_id` + one column per sample |
| `prism_asv_taxonomy.tsv` | `asv_id`, `lineage`, then `Kingdom`…`Species` |

When these are present the phyloseq object is built at feature resolution from
them instead of from the collapsed lineage table, and the UniFrac distances
become available. The tree's tip labels must match `asv_id` exactly.

---

## Drop-in format 2 — count matrix

**Filename:** `omniomics_count_matrix.tsv` (tab-separated)

One row per gene. The layout is DEFINE's, which puts one annotation block
before the sample columns and another after:

```
locus_tag  Chr  Start  End  Strand  Length  <sample columns…>  Gene  Product  eggNOG_OGs  COG_category  Description  GOs  EC  KEGG_ko  KEGG_Pathway  PFAMs
```

| Column | Required | Contents |
|---|---|---|
| `locus_tag` | yes | unique gene identifier; the table's key |
| one per sample | yes | integer raw counts (not TPM/FPKM/CPM) |
| `Chr` `Start` `End` `Strand` `Length` | no | genomic position |
| `Gene` `Product` `Description` | no | labels used on plots |
| `COG_category` | no | concatenated letters, no separator (`EJ` = both E and J) |
| `GOs` `KEGG_Pathway` `KEGG_ko` `EC` `PFAMs` | no | comma-separated lists |
| `eggNOG_OGs` | no | free text, not parsed |

Anything not in that fixed annotation list is treated as a **sample column**, so
do not add extra descriptive columns of your own — they would be read as
samples. Missing annotation is written `-`, eggNOG's own marker, and is handled
as "no assignment" rather than becoming a category named `-`.

Functional enrichment reads `COG_category`, `GOs` or `KEGG_Pathway`, whichever
you select; a column you leave out simply makes that choice unavailable.

---

## The metadata table

Independent of which drop-in format you use, every grouped analysis needs a
metadata TSV, chosen separately when the run is loaded.

- First column: the sample ID, matching the count/abundance columns exactly.
- Any number of further columns. Text columns become grouping variables
  (`--group_var`); numeric ones are additionally usable as environmental
  variables in the RDA.
- Spaces in column names are converted to underscores on load.

```
SampleID	habitat	pH	depth_m
sample_A	sediment	6.4	12.0
sample_B	water	7.9	2.0
sample_C	water	7.7	2.4
```

A metadata table with **extra** samples not in the count table is fine — it is
subset, not rejected, since one metadata file is often reused across runs. The
reverse is an error: a sample present in the counts but absent from the metadata
stops the load, because silently dropping it would change every group's
composition without saying so.

---

## Minimum group sizes

Some analyses need more than data to be present; they need enough of it. These
limits are the tools' own, not choices made here:

| Analysis | Needs |
|---|---|
| DESeq2 differential abundance/expression | ≥ 2 samples per group |
| PERMANOVA / beta diversity | ≥ 3 samples |
| Co-occurrence network | > 4 samples **per group** |
| UpSet | ≥ 2 non-reference groups to intersect |
| Venn | ≤ 4 groups |

An analysis whose requirement is not met refuses with a message naming the
requirement, rather than producing a figure that looks fine and means nothing.
