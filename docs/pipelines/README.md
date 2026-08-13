# The five pipelines

Each has its own page with the workflow diagram and a stage-by-stage
description: **[MAGMA](MAGMA.md)** · **[SIGMA](SIGMA.md)** ·
**[DOGMA](DOGMA.md)** · **[DEFINE](DEFINE.md)** · **[PRISM](PRISM.md)**.
DEFINE's and PRISM's are still to be written; this page covers all five.

Each pipeline is a self-contained directory under `pipelines/`:

```
pipelines/<name>/
  manifest.yaml            what the interface shows: steps, tools, parameters
  workflow/
    Snakefile              includes the rule files below
    rules/*.smk            the stages, numbered in execution order
    envs/*.yaml            one pinned conda environment per tool
    scripts/               helper scripts the rules call
```

The interface builds itself from `manifest.yaml`: adding a pipeline, or adding
a tool to one, does not require touching the application code. The schema is the
manifest files themselves — `pipelines/*/pipeline.yaml` are the working
examples, and every field they use is read by `backend/pipelines.py`.

A principle that applies to all five: **pipelines stop at raw outputs.** No
workflow merges, aggregates or statistically summarises on the user's behalf.
Merging tables and choosing a model is the analyst's work, and burying it
inside a pipeline makes it invisible and unauditable. The Plots tab is where
that work is done, deliberately as a separate, visible step.

A second one: **genes are called once per pipeline, and every downstream tool
reuses those calls.** Several tools bundle their own gene finder and will
happily re-predict ORFs from the raw contigs — antiSMASH is the clearest case.
Letting them do so produces a second, independent set of genes that disagrees
with the annotation at some loci, so a result's coordinates no longer line up
with everything else built from the same assembly. Where a tool accepts existing
annotation, it is given it: SIGMA hands antiSMASH Bakta's GFF3, MAGMA hands it
Pyrodigal's.

---

## MAGMA — metagenomics

**Question:** what organisms are in this community, and can I recover their
genomes?

62 rules, 35 tool environments.

| Stage | What happens |
|---|---|
| `01_qc_tax` | read cleaning (fastp / filtlong+NanoPlot by read type), taxonomic profiling with Kraken2+Bracken and, independently, Kaiju |
| `02_assembly` | MEGAHIT or SPAdes (short), Flye (long); Tiara splits prokaryotic from eukaryotic contigs |
| `03_mapping` | reads back to the assembly, for the coverage signal binning needs |
| `04_binning` | MetaBAT2, MaxBin2 and SemiBin2 in parallel |
| `05_mag_refine` | Binette consolidates the three bin sets; CheckM2 and GUNC assess the result |
| `06_dereplication_tax` | dRep removes redundancy; GTDB-Tk classifies the surviving MAGs |
| `07_annotation_mobilome` | gene calling, eggNOG-mapper, rRNA/tRNA/CRISPR, AMR and virulence, plasmids, prophages, insertion sequences, BGCs |
| `08_coverage` | CoverM quantifies each MAG across samples |

**Two classifiers on purpose.** Kraken2 matches nucleotide k-mers; Kaiju
translates and matches proteins. They are not interchangeable — Kaiju tends to
assign more reads where there is taxonomic novelty, because amino-acid
similarity survives more divergence. The Plots tab can show either, or their
concordance, because agreement between two independent methods is itself
evidence.

**CheckM2 and GUNC both.** CheckM2 measures completeness and contamination from
single-copy markers, which a chimeric bin can satisfy while being two organisms
spliced together. GUNC asks instead whether the genes agree on one lineage. A
MAG can pass one and fail the other, so they are reported side by side and
never merged.

---

## SIGMA — isolate genomics

**Question:** I have isolate genomes — what are they, and what do they carry?

36 rules, 28 tool environments.

| Stage | What happens |
|---|---|
| `01_qc` | read cleaning by read type |
| `02_assembly` | Unicycler (short/hybrid) or Flye (long) |
| `03_polish` | Racon + Medaka for long reads; RagTag scaffolding |
| `04_mapping`, `07_coverage` | reads back to the polished assembly, CoverM |
| `05_quality` | QUAST, CheckM2, GUNC |
| `06_taxonomy` | GTDB-Tk |
| `08_annotation` | Bakta (genes, rRNA, tRNA, CRISPR), eggNOG-mapper, AMRFinderPlus, ABRicate (NCBI/CARD/VFDB), MOB-suite, ISEScan |
| `09_typing` | MLST |
| `10_viral` | geNomad, VirSorter2, CheckV, VIBRANT |
| `11_secondary_metabolites` | antiSMASH, BiG-SCAPE |
| `12_screening` | Kaiju contamination screen |

The Plots tab's genome ring draws most of this on one figure, and the mobilome
analysis crosses the AMR hits against MOB-suite's chromosome-versus-plasmid
call — which answers whether a resistance gene is mobilisable, the question
that changes what a resistome result means.

---

## DOGMA — metatranscriptomics

**Question:** what is this community *doing*?

34 rules, 18 tool environments.

| Stage | What happens |
|---|---|
| `01_qc` | read cleaning |
| `02_screening` | rRNA removal (RiboDetector), taxonomic screening |
| `03_assembly` | de novo transcriptome assembly (Trinity / MEGAHIT / SPAdes) |
| `04_orf_calling` | TransDecoder |
| `05_annotation` | eggNOG-mapper, dbCAN, NCyc/SCyc/MCycDB, CANT-HYD, FeGenie |
| `06_taxonomy` | CAT/BAT for prokaryotes, EUKulele for eukaryotes |
| `07_quantification` | Salmon, per transcript |
| `08_magma_xref` | optional: map ORFs against a MAGMA run's MAGs, tying expression to recovered genomes |

**Per-sample de novo assemblies share no gene identifiers**, which is why the
Plots tab reads DOGMA through a long per-ORF table rather than the matrix shape
the other pipelines use. That difference is structural, not stylistic.

---

## DEFINE — differential expression

**Question:** which genes change between my conditions?

17 rules, 9 tool environments.

| Stage | What happens |
|---|---|
| `01_qc` | fastp, FastQC, MultiQC |
| `02_reference` | reference genome indexing; Bakta annotation when none is supplied |
| `03_mapping` | Bowtie2 |
| `04_strandedness` | RSeQC infers library strandedness rather than asking the user to guess |
| `05_counts` | featureCounts |
| `06_merge` | one annotated count table, `contagem_anotada.tsv` |

The pipeline stops at the count table. DESeq2 modelling happens in the Plots
tab, where the design and the contrast are explicit choices.

---

## PRISM — amplicon sequencing

**Question:** community profiling from 16S/18S/ITS amplicons.

13 rules, 6 tool environments.

| Stage | What happens |
|---|---|
| `01_qc` | read cleaning by platform |
| `02_primer_trim` | cutadapt, with the primer pair as an explicit parameter |
| `03_chimera` | VSEARCH chimera filtering |
| `04_denoise_classify` | DADA2 (Illumina/PacBio) or Emu (ONT), taxonomy assignment, and — where enough taxa were detected — a phylogenetic tree |
| `05_functional_inference` | PICRUSt2, optional |

**PRISM is the only pipeline that builds a phylogenetic tree**, which is what
makes UniFrac and weighted UniFrac available in the Plots tab. Every other
pipeline's community table is lineage-collapsed with no placed sequences, so
those distances are refused there with an explanation rather than silently
substituted.

---

## Choosing between them

| You have | Use |
|---|---|
| Shotgun reads from a community, and want genomes | MAGMA |
| Shotgun reads from a community, and only want who is there | MAGMA (taxonomy stages) or PRISM if you have amplicons |
| Sequenced isolates | SIGMA |
| RNA from a community | DOGMA |
| RNA from one organism, with conditions to compare | DEFINE |
| 16S/18S/ITS amplicons | PRISM |

MAGMA and DOGMA are designed to be used together: `08_magma_xref` ties a
DOGMA run's expression back to the MAGs a MAGMA run recovered from the same
material.
