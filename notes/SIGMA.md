# SIGMA

Single Isolate Genome, Multi-platform Assembly — one isolate's genome per sample, from raw reads to annotation, taxonomy, AMR/virulence, strain typing, and secondary metabolites. Second pipeline plugged into [[Project Overview|OmniOmics]], after [[MAGMA]]. Category: `genomics`.

Lives at `pipelines/sigma/` — `Snakefile` + `workflow/rules/*.smk` (12 stage files: QC, contamination screening, assembly, polishing, mapping, genome quality, taxonomy, coverage, gene prediction/annotation, typing, viral, secondary metabolites) + `pipeline.yaml` (see [[Pipeline Manifest Schema]]).

Unlike MAGMA (ported from an external `MAGMA-main` repo), SIGMA's workflow was built directly in this app, tool by tool, over several sessions — there's no separate source-of-truth repo to diff against if something looks off; the `.smk` rule files themselves are the ground truth.

31 tools across 14 categories, 15 downloadable reference databases (mostly shared with MAGMA via the Hub-level Databases screen). Full dependency chain, including a real bug found and fixed: [[SIGMA Dependency Graph]].

## Pre-assembly contamination screening

Kraken2 and Kaiju, both optional/independent, run right after QC on the clean reads — flags whether a sample looks like a pure culture before spending time assembling/annotating a contaminated one. This closed a real gap: SIGMA previously had no equivalent of MAGMA's read-level taxonomy step at all. Kraken2 here is classify-only (no Bracken — a single isolate doesn't need community abundance re-estimation); Kaiju runs its own classify → table chain, same as MAGMA's. See [[Decisions Log]].

## Assembly: de novo or reference-guided, per sample

- Assembler picked by read type: `short`/`hybrid` → **Unicycler** (wraps SPAdes, bridges repeats with long reads when given), `long` → **Flye**. Long-only assemblies get polished with **Racon → Medaka**; short/hybrid assemblies come out of Unicycler already self-polished.
- Optional **reference-guided scaffolding via RagTag** — not variant calling (see [[Decisions Log]] for why Snippy was rejected). Gated by an optional `reference_dir` input using the same folder-per-sample convention as reads: a sample with a matching reference folder gets its polished assembly scaffolded against it; one without just uses the normal polished output. Fully independent of read type — short/long/hybrid and with/without-reference mix freely within one run.

## Sequencing platforms

Four long-read platform profiles (`nano_raw`, `nano_hq`, `pacbio_raw`, `pacbio_hifi`), each carrying its own Flye flag, SPAdes/Unicycler flag, and minimap2 preset — picked once per run in the Entradas tab, not hardcoded per-tool. Illumina short reads need no such choice (fastp handles them uniformly).

## Notable tool choices

- **Bakta**, not Prodigal/Pyrodigal + eggNOG separately, for gene calling — already uses Pyrodigal internally (confirmed via Bakta's own GitHub), and does gene calling + ncRNA + functional annotation in one pass. eggNOG-mapper is kept as an **optional extra** on top, for deeper KEGG/COG/GO analysis Bakta doesn't provide.
- Mobilome/viral tooling (ISEScan, MOB-suite, geNomad, VirSorter2, CheckV, VIBRANT) and secondary-metabolite tooling (antiSMASH, BiG-SCAPE) were ported over from MAGMA's equivalent categories at the user's request, reasoning that isolate researchers doing BGC/AMR work (their own lab studies soil/actinobacteria/cyanobacteria isolates and BGCs) need the same analyses MAGMA offers metagenome researchers — "a ideia do omnimeta é ser um app cujo vários pesquisadores de diferentes áreas possam usar."
- MLST added for strain-level typing/surveillance, explicitly *not* extended into full epidemiological variant-calling (see [[Decisions Log]]).

Icon: Σ glyph mark, `app/assets/pipeline_icons/sigma.png`.

## Hub card tags

Carries a second tag beyond its one omics category: "Genômica" (the `category` field, closed enum) + "Procarioto"/"Prokaryote" (a new, separate `tags: [...]` list field on the manifest, since organism scope isn't the same axis as omics layer). See `app/lib/theme/category_colors.dart`'s `_extraTagLabels` for adding more (e.g. "eukaryote" already stubbed in, unused so far).

## Plots tab (2026-08-07) — a real 4th `input_shape`, plus a genuinely new Flutter mechanism: per-genome selection

User picked SIGMA as the second Plots-tab pipeline to build (after DOGMA), with one explicit design requirement stated up front: since a SIGMA run can assemble many genomes at once, an analysis needs a real way to ask "which genome do you want to work with" — not just "which run".

**SIGMA has no cross-sample table anywhere in its own real output** — confirmed by a real Explore-agent investigation that installed/read SIGMA's own pinned tool versions' actual source (not generic docs): QUAST, CheckM2, GTDB-Tk, CoverM, AMRFinderPlus, ABRicate, and MLST each write their own per-genome file, in 7 mutually incompatible formats, joined by nothing. One real, load-bearing gotcha this surfaced: **QUAST's own "Assembly" column and CoverM's own "Genome" column are both always the literal string `"final_polished"`** (SIGMA never passes `--labels`, and every genome's fasta is renamed identically before being handed to either tool) — neither can be used as a join key; every table in the real merge is instead keyed by the `{sample}` path segment from `results/`'s own directory structure, never by a tool's own internal identity column. AMRFinderPlus's real column names were also confirmed to differ from older/generic documentation (`Element symbol`/`Element name`, not `Gene symbol`/`Sequence name` — a real version-drift correction for the pinned 4.2.7 release). MLST's real output has no header and a genuinely ragged number of trailing allele columns (varies by which PubMLST scheme matched) — only `FILE`/`SCHEME`/`ST` are read for the summary table.

**Built**: `lib/build_sigma_table.R` — a dense, one-row-per-genome merge (no LEFT-JOIN spine needed the way DOGMA's sparse per-ORF table needed one; these 5 "quality-tier" tools each report exactly one row per genome) plus a separate sparse long "gene hits" table (AMRFinderPlus + ABRicate's NCBI/CARD/VFDB databases combined, 0+ hits per genome, for presence/absence-style analyses). `load_sigma_table.R` (new loader, `sigma_genomes` input_shape) additionally folds SIGMA's own real categorical columns (GTDB-Tk's taxonomy ranks, MLST's scheme) into the same `--group_var`/`--reference_group` dropdown mechanism every other pipeline's metadata.tsv columns use — e.g. `--group_var gtdbtk_genus` works with zero metadata.tsv required, since taxonomy/typing genuinely IS useful grouping information here, not just incidental data.

**A genuinely new Flutter mechanism, not a workaround**: neither "column" (picks a metadata column name) nor "level" (picks a value from a column the user already chose) fit "pick one of this run's real genomes" — there's no metadata column to depend on, genome identity is a fixed fact about the run itself. Added a new `PlotParam` type, `"sample"`, backed by a new `PlotLoadedData.samples` field (populated by `/api/plots/load`'s response, same forward-compat pattern as `tax_ranks`/`annotation_columns`) and a new dropdown branch in `plot_param_form.dart` — small, surgical, `flutter analyze` clean. This is real, deliberate new frontend work (unlike PRISM's "zero Flutter changes" precedent), justified because the underlying interaction genuinely doesn't exist anywhere else in the app yet.

**3 analyses built (first slice)**, `applies_to: [sigma]`, `input_shape: sigma_genomes`:
- `sigma_genome_summary` — the analysis directly answering the user's own requirement: `--genome` (the new "sample" type) picks one genome, shows its real assembly/quality/taxonomy/coverage/typing stats as a report-card panel plus its own AMR/virulence gene hits.
- `sigma_genome_quality_overview` — CheckM2 completeness vs. contamination for every genome at once, point size by N50, colored by any real taxonomy/typing/metadata column, with the real MIMAG high-quality threshold (Bowers et al. 2017, Nat Biotechnol, ">=90% complete, <=5% contamination" — the same real standard MAGMA's own genome-quality guidance already cites) drawn as a reference region, not just described in prose.
- `sigma_amr_heatmap` — presence/absence of AMR/virulence genes across every genome, hierarchically clustered on both axes, filterable by source database.

**One real bug found and fixed**: `sigma_genome_quality_overview`'s title (a long, dynamic string reporting the real MIMAG pass count) silently overflowed past the figure's right edge instead of wrapping — `with_title_bar()` only auto-wraps when `plot_width_in` is explicitly passed, which this script's first version omitted. Fixed by passing it (matching the pattern `dogma_de_heatmap.R` already uses). Caught by actually rendering and looking at the image, not just checking the script ran without error.

**Verified for real** against a small, fully controlled synthetic 4-genome fixture (2 *E. coli*, 2 *K. pneumoniae*, one deliberately low-quality/contaminated genome, real planted AMR gene overlaps) built to match every confirmed real column shape exactly: the merge recovered every planted value exactly (quality stats, taxonomy, MLST types including a deliberately unmatched `"-"` scheme, AMR gene hits); the quality-overview plot correctly identified 3/4 genomes as MIMAG-high-quality and visually isolated the contaminated one; the AMR heatmap's hierarchical clustering correctly grouped the two genomes sharing resistance genes together and correctly isolated the clean genome. All three preview.png images inspected directly, not just checked for "did the script exit 0".

**A real, persistent demo run built for manual click-testing**, same as DOGMA's: `~/omniomics_demo_runs/sigma_demo`'s `05_QUALITY`/`06_TAXONOMY`/`07_COVERAGE`/`08_ANNOTATION`/`09_TYPING` results (confirmed fake stub data, same class of fixture already caught for `dogma_demo`) replaced with the real-shaped 4-genome fixture above; other stages (`00_SCREENING`/`03_POLISH`/`10_VIRAL`/`11_BGC`, not read by the new Plots-tab code) deliberately left untouched, so those stages still reference the old `isolate_A`/`isolate_B` sample names -- a real, acknowledged cross-stage naming inconsistency in this demo run specifically, harmless for Plots-tab testing. Optional metadata at `~/Documentos/omniomics_test_metadata/metadata_sigma_demo.tsv` (isolation_source/collection_year, on top of the built-in taxonomy/typing columns).

**Not yet done**: only 3 analyses (a first slice, matching DOGMA's own initial scope before the user asked for more); the other ~5 SIGMA output categories (viral/mobilome: ISEScan, MOB-suite, geNomad, VirSorter2, CheckV, VIBRANT; secondary metabolites: antiSMASH, BiG-SCAPE) have no Plots-tab analyses at all yet -- real candidates for a future round (e.g. a BGC/mobilome summary per genome, reusing the same `--genome` picker). No dynamic annotation-source dropdown was needed here (unlike DOGMA) since the "sample" type IS the new dynamic mechanism this round was about.
