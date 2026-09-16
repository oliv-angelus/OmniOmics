# DEFINE

**D**ifferential **E**xpression, **F**unctional **I**nterpretation & **N**etwork **E**nrichment

Differential expression for a single organism: RNA-seq reads against a reference
genome, ending at an annotated count table. 17 rules across 9 tool environments.

<p align="center">
  <img src="../../pipelines/define/DEFINE.drawio.svg" alt="DEFINE workflow diagram" width="100%">
</p>

---

## What it takes in

Paired-end short-read RNA-seq from a bacterial isolate, plus a reference
genome for that organism — DEFINE does not assemble one. Where SIGMA
produces a genome, DEFINE consumes one: point it at SIGMA's own output, or
any FASTA the organism already has a public assembly for.

## What it produces

| | |
|---|---|
| Read mapping | Bowtie2 alignments, one BAM per sample |
| Strandedness | auto-detected per run, not assumed |
| Gene counts | one matrix, every sample, aligned rows |
| Annotated count table | counts joined to Bakta's gene/product calls and eggNOG's functional annotation |
| QC summary | one row per sample: trimming, alignment and assignment rates, detected strandedness |

---

## The stages

### 01 — QC and trimming

`fastp` · `fastqc_raw` · `fastqc_trim` · `multiqc_raw` · `multiqc_trim`

Standard short-read cleaning, with before/after FastQC and one consolidated
MultiQC report for each so the effect of trimming is visible in one place.

### 02 — Reference annotation

`bakta_reference` · `filter_rrna` · `bowtie2_index_reference` · `eggnog_reference`

Everything here runs **once per project**, not once per sample: the
reference genome is annotated by Bakta, its rRNA/tRNA/tmRNA features are
excluded before counting (left in, they would distort every downstream
normalisation), it is indexed once for Bowtie2, and its proteins are
functionally annotated by eggNOG-mapper for the final merge.

### 03 — Read mapping

`bowtie2_align` · `index_bam`

Every sample's trimmed reads against the one shared reference index.
Bowtie2's own `% overall alignment rate` (stderr) is kept and reused
directly by `qc_summary` in stage 06, not just left in a log file.

### 04 — Strandedness and counting

`bed12_from_gff` · `infer_experiment` · `decide_strandedness` · `featurecounts`

> **Strandedness is measured, not assumed.** RSeQC's `infer_experiment.py`
> runs on every sample (not a hand-picked "representative" one), and an
> explicit rule decides `featureCounts`' `-s` value from the result: one
> pattern above 90% means stranded forward/reverse, close to 50/50 means
> unstranded. Both the value used and a per-sample audit trail are written,
> so the threshold behind a differential-expression result is never left
> undocumented.

`featureCounts` then builds **one matrix over every sample's BAM at once**,
guaranteeing the same gene rows in the same order across samples, rather
than counting each sample separately and joining afterward.

### 05 — Table assembly

`merge_annotated_counts` · `qc_summary`

The raw count matrix is joined to Bakta's gene/product table and eggNOG's
functional annotation into one table. **This is where the pipeline stops on
purpose**: the experimental design (which sample is which condition, which
group is the reference) and the statistics (DESeq2) are left to the user's
own downstream work, the same principle every OmniOmics pipeline holds to.
`qc_summary` separately consolidates the metrics worth alerting on —
trimming retention, alignment rate, assignment rate, detected strandedness —
in one row per sample.

---

## In the Plots tab

7 analyses over the annotated count table: sample-level PCA and a
sample-distance heatmap for a first look at the experimental design, then
DESeq2-driven MA and volcano plots, a DE heatmap, functional enrichment
over the eggNOG annotation, and an UpSet plot for comparing DE gene sets
across contrasts.

---

## Requirements

The lightest of the five pipelines for bacterial genomes: mapping against a
single reference plus counting. **8 GB minimum, 16 GB recommended**, driven
by the Bowtie2 index. No AVX2 requirement — runs on an ordinary workstation.
Full figures in [`../REQUIREMENTS.md`](../REQUIREMENTS.md).
