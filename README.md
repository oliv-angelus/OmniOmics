# OmniOmics

**An integrated desktop environment for reproducible multi-omics analysis.**

OmniOmics packages five Snakemake workflows — metagenomics, metatranscriptomics,
isolate genomics, differential expression and amplicon sequencing — behind a
graphical interface, and adds a plotting environment that turns each workflow's
output into publication-ready figures without leaving the application.

It exists for a specific, common situation: the analysis a lab needs is not one
tool but twenty, each with its own installation, its own version pins, its own
output format, and its own way of breaking. Assembling that stack by hand is a
weeks-long task that has to be repeated on every machine and revisited every time
a tool updates. OmniOmics does that assembly once, declaratively, and keeps it
reproducible.

> **Status: alpha (0.0.1).** The workflows and the plotting environment run end
> to end and are exercised by an automated suite against synthetic fixtures for
> all five pipelines. What has *not* happened yet is sustained use on real data
> by people other than the author. Treat results accordingly, and read
> [Known limitations](#known-limitations) before relying on any of it.

---

## Contents

- [What it does](#what-it-does)
- [The five pipelines](#the-five-pipelines)
- [The plotting environment](#the-plotting-environment)
- [Design principles](#design-principles)
- [Installing](#installing)
- [Using it](#using-it)
- [Plotting data produced elsewhere](#plotting-data-produced-elsewhere)
- [Repository layout](#repository-layout)
- [Reproducibility and verification](#reproducibility-and-verification)
- [Known limitations](#known-limitations)
- [Citing](#citing)
- [Licence](#licence)

---

## What it does

| | |
|---|---|
| **Interface** | Flutter desktop application (Linux) |
| **Orchestration** | Snakemake, one workflow per pipeline |
| **Environments** | conda, one isolated environment per tool |
| **Analysis and figures** | R (phyloseq, DESeq2, vegan, ggplot2, circlize) |
| **Backend** | Python / FastAPI, local only |

Four things the interface handles that are usually left to the user:

1. **Installing the toolchain.** conda and Snakemake are installed on first
   run; each workflow's tools are installed into their own environments on
   first use. Nothing is assumed to be on the system already.
2. **Reference databases.** The Databases tab downloads, verifies by checksum
   and tracks the reference data each tool needs, which is frequently the
   hardest part of standing a pipeline up.
3. **Running and watching.** Runs stream their log live, can be stopped, and
   are recorded in a run history that survives restarts.
4. **Figures.** Every finished run can be opened in the Plots tab, where the
   analyses relevant to that pipeline are offered as cards, each parameterised
   and each exporting at publication resolution.

---

## The five pipelines

| Pipeline | Question it answers | Rules | Tool environments |
|---|---|---:|---:|
| **MAGMA** | What organisms are in this community, and can I recover their genomes? | 62 | 35 |
| **SIGMA** | I have isolate genomes — what are they, and what do they carry? | 36 | 28 |
| **DOGMA** | What is this community *doing*? (metatranscriptomics) | 34 | 18 |
| **DEFINE** | Which genes change between my conditions? | 17 | 9 |
| **PRISM** | Amplicon (16S/18S/ITS) community profiling | 13 | 6 |

Each pipeline is a self-contained directory under `pipelines/` holding its
Snakemake workflow, its per-tool conda environments, and a manifest describing
its steps and parameters to the interface. Adding a pipeline does not require
touching the application: the interface builds itself from the manifest.

Detailed per-pipeline documentation lives in [`docs/pipelines/`](docs/pipelines/).

---

## The plotting environment

41 analyses across the five pipelines, each reading a cached representation of
a finished run rather than re-parsing its raw output:

- **Community** — composition, alpha and beta diversity (PCoA/NMDS/CAP over
  Bray-Curtis, Jaccard and UniFrac), rarefaction, Good's coverage, core
  microbiome, co-occurrence networks, indicator species, Venn/UpSet.
- **Differential** — DESeq2 pairwise contrasts and likelihood ratio tests, MA
  and volcano plots, DE heatmaps, functional enrichment.
- **Genomes** — MIMAG quality tiers, GUNC chimerism, assembly landscape,
  AMR/virulence heatmaps, mobilome (plasmids, prophages, insertion sequences),
  biosynthetic gene clusters, and a Proksee-style circular genome map.
- **Quality** — read cleaning before and after, assembly metrics.

Every figure can be restyled (palette, background, fonts, grid, axes) and
exported as TIFF, PNG, PDF or SVG at up to 600 dpi.

---

## Design principles

These are the rules the codebase is actually held to, and they explain most of
what looks unusual in it.

**A reader is written against the tool's source, not its documentation.**
Every parser for a tool's output was written by reading the code that *writes*
that output, and the file and line are recorded in
[`docs/tool_output_samples/VERIFIED_FORMATS.md`](docs/tool_output_samples/VERIFIED_FORMATS.md).
This is not pedantry. It has repeatedly caught discrepancies that no
documentation mentions — a column renamed between versions, a header prefixed
differently from its banner, a tool that reports the full FASTA header where
its neighbour reports the first token. Those produce empty or silently wrong
figures, not error messages.

**An analysis that cannot answer honestly refuses.** UniFrac on data with no
phylogenetic tree, a functional vocabulary the annotation never assigned, a
group with too few replicates for dispersion estimation — each stops with a
message naming the reason, instead of drawing something defensible-looking.

**Running is the only verification that counts.** R scripts are not type
checked; a renamed column surfaces nowhere until execution.
`scripts/run_plots_suite.py` runs every analysis of a pipeline across *every*
value of every choice parameter, because the non-default branch is where
breakage hides.

**Statistical choices are grounded and recorded.** Where a method has more than
one defensible form, the choice and its citation are in the code beside it —
why the LRT is a separate analysis rather than a toggle, why `poscounts`
normalisation is a fallback rather than a default, why CAP is constrained by
the same factor PERMANOVA tests. See [`docs/CITATIONS.md`](docs/CITATIONS.md).

**Pipelines stop at raw outputs.** No workflow merges, aggregates or
statistically summarises on the user's behalf. That is the analyst's work, and
burying it inside a pipeline makes it invisible and unauditable.

---

## Installing

Requirements: Linux, and roughly 20 GB free for tool environments plus whatever
the reference databases you enable need (some are large).

```bash
git clone https://github.com/oliv-angelus/OmniOmics.git
cd OmniOmics
./run_dev.sh
```

`run_dev.sh` starts the Python backend and the Flutter application together. On
first run the application offers to install conda and Snakemake; each pipeline's
tool environments are then built on first use of that pipeline.

To build a standalone binary instead:

```bash
./build.sh
```

Full instructions, including how to build from source and what each dependency
is for, are in [`docs/INSTALL.md`](docs/INSTALL.md).

---

## Using it

1. **Databases** — download the reference data the tools you plan to use need.
2. **Hub** — pick a pipeline.
3. **Launch** — point at your reads, choose the tools and parameters, start.
4. **Monitor** — watch the log; stop it if needed.
5. **Results** — browse the output tree.
6. **Plots** — pick the finished run, choose a metadata table, and work through
   the analyses.

The interface is available in Portuguese and English, switchable at any time.

---

## Plotting data produced elsewhere

The Plots tab is usable on its own, without running any pipeline. **Plots →
Importar pasta** points it at any results folder: one produced on another
machine, one this installation has no record of, or a table built entirely
outside OmniOmics. The folder is scanned read-only and the application reports
which inputs it recognised and which analyses those unlock before anything is
registered.

The accepted input formats are specified in
[`docs/plot_input_formats.md`](docs/plot_input_formats.md), including two
documented drop-in filenames for data with no OmniOmics provenance at all.

---

## Repository layout

```
app/          Flutter desktop application
backend/      FastAPI backend: run orchestration, databases, plotting API
pipelines/    One directory per pipeline: Snakemake workflow + conda envs + manifest
plots/        R analysis and export scripts, plus the analysis manifest
scripts/      Developer tooling: test-fixture generators, the plotting test suite
docs/         Documentation (this file's companions)
notes/        Working notes and decision log kept during development
```

---

## Reproducibility and verification

- **Pinned environments.** Every tool is installed from a version-pinned conda
  environment file. Nothing depends on what happens to be on the host.
- **Checksummed databases.** Reference data is verified after download.
- **Synthetic fixtures.** `scripts/make_*_test_run.py` generate structurally
  faithful runs for all five pipelines — real paths, real column layouts, real
  edge cases (a chimeric genome that passes CheckM2, a genome with no MLST
  match, an assembly whose contig headers carry descriptions) with generated
  numbers. They make the whole plotting environment testable without a cluster.
- **An offline test suite.** `scripts/run_plots_suite.py` exercises every
  analysis across every parameter combination and distinguishes a real failure
  from a legitimate refusal and from an empty-but-correct result.

---

## Known limitations

Stated plainly, because a reviewer will find them anyway and because they bound
what the current version should be trusted for.

- **Alpha.** Not yet used sustainedly on real data by anyone other than the
  author.
- **Linux only.** The application has only been built and tested on Linux.
- **The fixtures are synthetic.** They reproduce real formats with generated
  numbers. They prove the code runs and reacts correctly to its inputs; they
  cannot prove a biological result is right.
- **Fixture coverage is uneven.** DOGMA's fixture exercises 5 of its 15
  annotation columns. The readers for the other 10 have been audited against
  their tools' source code, but have not been run against data.
- **Some steps are optional and untested end to end** on real input, notably
  the secondary-metabolite (antiSMASH/BiG-SCAPE) and viral blocks.
- **The genome ring is a static figure**, not an interactive browser. Tracks
  are toggled by re-running the analysis.

---

## Citing

If OmniOmics contributes to published work, please cite it using
[`CITATION.cff`](CITATION.cff) (GitHub renders a ready-made citation from it).

**Please also cite the tools you actually used.** OmniOmics orchestrates them;
the science is theirs. [`docs/CITATIONS.md`](docs/CITATIONS.md) lists every tool
with its reference, organised by pipeline, so the methods section can be
assembled from it directly.

---

## Author

**Angelo Felipe Barbosa de Oliveira**
Doctoral student in Bioinformatics, Programa de Pós-Graduação em Genética e
Biologia Molecular, Universidade Federal do Pará (UFPA), Belém, Pará, Brazil.
Laboratório de Engenharia Biológica.

ORCID: [0000-0003-0831-447X](https://orcid.org/0000-0003-0831-447X)

---

## Licence

MIT — see [`LICENSE`](LICENSE).

The licence covers OmniOmics itself. The bioinformatics tools it orchestrates
remain under their own licences, several of which are more restrictive, and the
reference databases under their own terms of use. If you redistribute
OmniOmics, or publish work using it, check the licence of each tool you
actually enabled.
