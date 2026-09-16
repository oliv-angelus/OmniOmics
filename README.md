# OmniOmics

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-333333?logo=linux&logoColor=white)](docs/INSTALL.md)
[![Dart](https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Python](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)](https://www.python.org)
[![R](https://img.shields.io/badge/R-%E2%89%A54.3-276DC3?logo=r&logoColor=white)](https://www.r-project.org)
[![Snakemake](https://img.shields.io/badge/Snakemake-workflows-039475?logo=snakemake&logoColor=white)](https://snakemake.readthedocs.io)
[![DOI](https://zenodo.org/badge/1367598567.svg)](https://doi.org/10.5281/zenodo.22780175)

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

> **Status: 1.0.0.** The workflows and the plotting environment run end to end
> and have been validated twice over: first against **synthetic control
> datasets** built to reproduce each tool's real output format and exercise
> every code path, including the edge cases; then for real, all five
> pipelines run end to end on **real, non-simulated public datasets** against
> independent, external ground truth (certified mock-community compositions,
> reference genomes, published papers' own reported results, and a sequencing
> vendor's own classification of the same read file), on real institutional
> HPC hardware, not a laptop-scale approximation. Exact configuration, ground
> truth, and raw results are published at
> [OmniOmics-validation](https://github.com/oliv-angelus/OmniOmics-validation).
> See [Validation status](#validation-status) for what that does and does not
> establish.

---

## Contents

- [What it does](#what-it-does)
- [The five pipelines](#the-five-pipelines)
  - Per-pipeline pages: [MAGMA](docs/pipelines/MAGMA.md), [SIGMA](docs/pipelines/SIGMA.md), [DOGMA](docs/pipelines/DOGMA.md), [DEFINE](docs/pipelines/DEFINE.md), [PRISM](docs/pipelines/PRISM.md)
- [The plotting environment](#the-plotting-environment)
- [Design principles](#design-principles)
- [Requirements](docs/REQUIREMENTS.md)
- [Installing](#installing)
- [Using it](#using-it)
- [Plotting data produced elsewhere](#plotting-data-produced-elsewhere)
- [Repository layout](#repository-layout)
- [Reproducibility](#reproducibility)
- [Validation status](#validation-status)
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

The names are acronyms, not arbitrary labels:

| Pipeline | Stands for | Question it answers | Rules | Envs |
|---|---|---|---:|---:|
| **MAGMA** | **M**etagenome **A**ssisted **G**UI & **M**AG **A**nalyses | What organisms are in this community, and can I recover their genomes? | 63 | 35 |
| **SIGMA** | **S**ingle **I**solate **G**enome, **M**ulti-platform **A**ssembly | I have isolate genomes — what are they, and what do they carry? | 36 | 28 |
| **DOGMA** | **D**iversity **O**f **G**ene expression — **M**etatranscriptome **A**nalysis | What is this community *doing*? | 34 | 18 |
| **DEFINE** | **D**ifferential **E**xpression, **F**unctional **I**nterpretation & **N**etwork **E**nrichment | Which genes change between my conditions? | 17 | 9 |
| **PRISM** | **P**rofiling **r**RNA **I**nference of **S**pecies via **M**etabarcoding | Amplicon community profiling: 16S/18S/23S/28S/ITS/rrn-operon/COI/12S, short- and long-read | 16 | 6 |

Each pipeline is a self-contained directory under `pipelines/` holding its
Snakemake workflow, its per-tool conda environments, and a manifest describing
its steps and parameters to the interface. Adding a pipeline does not require
touching the application: the interface builds itself from the manifest.

Each pipeline has its own page, with the workflow diagram and a stage-by-stage
description read from its actual rule files:

- [MAGMA](docs/pipelines/MAGMA.md) · [SIGMA](docs/pipelines/SIGMA.md) ·
  [DOGMA](docs/pipelines/DOGMA.md) · [DEFINE](docs/pipelines/DEFINE.md) ·
  [PRISM](docs/pipelines/PRISM.md)


---

## The plotting environment

43 analyses across the five pipelines, each reading a cached representation of
a finished run rather than re-parsing its raw output:

- **Community** — composition, alpha and beta diversity (PCoA/NMDS/CAP over
  Bray-Curtis, Jaccard and UniFrac), rarefaction, Good's coverage, core
  microbiome, co-occurrence networks, indicator species, Venn/UpSet.
- **Differential** — DESeq2 pairwise contrasts and likelihood ratio tests, MA
  and volcano plots, DE heatmaps, functional enrichment.
- **Genomes and MAGs** — MIMAG quality tiers, GUNC chimerism, assembly
  landscape, AMR/virulence heatmaps, mobilome (plasmids, prophages, insertion
  sequences), biosynthetic gene clusters, and a Proksee-style circular genome
  map. Completeness against contamination is drawn against the published MIMAG
  cut-offs rather than chosen thresholds, for both isolate genomes and
  metagenome-assembled ones.
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

Linux x86-64, roughly 25 GB free for tool environments, plus whatever the
reference databases you enable need.

**Check the hardware requirements first** —
[`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) gives minimum and recommended RAM
and cores per pipeline, and lists which pipelines need a CPU with **AVX2**
(MAGMA and SIGMA do; without it CheckM2 aborts with `Illegal instruction`).
MAGMA's floor is set by GTDB-Tk, which documents a 150 GB requirement.

Download the `.deb` from the
[Releases page](https://github.com/oliv-angelus/OmniOmics/releases) and install
it like any other application:

```bash
sudo dpkg -i omniomics_1.0.0_amd64.deb
omniomics
```

It also appears in the desktop menu under Science.

Nothing else needs to be installed first. On first launch the application
offers to install conda and Snakemake, and each pipeline's tool environments are
built the first time that pipeline is used.

Full instructions, including uninstalling and where everything is stored, are in
[`docs/INSTALL.md`](docs/INSTALL.md).

### Running from source

Only for modifying the pipelines or the analyses — `run_dev.sh` rebuilds and
launches the app against a local backend, and is a development tool rather than
a way to install OmniOmics. It needs the Flutter SDK and the build dependencies
listed in [`docs/INSTALL.md`](docs/INSTALL.md#running-from-source--for-development-only);
`./build.sh` produces the same `.deb` as the release.

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
```

---

## Reproducibility

- **Pinned environments.** Every tool is installed from a version-pinned conda
  environment file. Nothing depends on what happens to be on the host.
- **Checksummed databases.** Reference data is verified after download.
- **Recorded configuration.** Each run stores the configuration it was launched
  with, so it can be repeated.

How the application itself is checked is covered under
[Validation status](#validation-status).

---

## Validation status

What has been validated, what has not, and why — stated plainly, because it
bounds what this version should be trusted for.

### What OmniOmics adds, and therefore what needs validating

The tools OmniOmics runs were validated by their own authors, and revalidating
Kraken2 or DESeq2 here would be redundant. But orchestration adds surface of its
own, and that surface is what these checks target:

- **The readers.** Nothing in Kraken2's validation says *we* parse its output
  correctly. This is where every expensive bug in the project has been. A wrong
  parser produces a plausible, wrong figure rather than an error — which is why
  every reader was written against the code that *writes* the output, with file
  and line recorded in
  [`docs/tool_output_samples/VERIFIED_FORMATS.md`](docs/tool_output_samples/VERIFIED_FORMATS.md).
- **The statistical choices the application makes on the user's behalf.**
  Falling back to `poscounts` normalisation, constraining CAP by the tested
  factor, separating the LRT from the Wald contrast: DESeq2 validates that the
  tests work, not that these are the right tests to apply. Each choice is
  documented with its citation next to the code.
- **The composition.** The order tools are chained in, and what is deliberately
  *not* merged — GUNC reported beside CheckM2 rather than folded into it, for
  instance — is design, and design can be wrong.

### Done

- **Synthetic control datasets for all five pipelines**
  (`scripts/make_*_test_run.py`). These are not toy data: every path and column
  layout reproduces what the real tools write, including the awkward cases —
  a chimeric genome that passes CheckM2 while failing GUNC, an isolate with no
  MLST match, contig headers carrying descriptions that break a naive join,
  a tool that reports the full FASTA header where its neighbour reports the
  first token. The numbers are generated; the shapes are real.
- **An automated suite over every analysis and every parameter combination**
  (`scripts/run_plots_suite.py`), distinguishing a real failure from a
  legitimate refusal and from an empty-but-correct result.
- **Format verification against tool source code** for every reader.
- **End-to-end execution** of all five workflows and all 43 analyses.
- **Real, non-simulated validation of all five pipelines**, each run end to
  end on a public dataset with independent, external ground truth, on real
  institutional HPC hardware:
  - **MAGMA** — ZymoBIOMICS mock community (even + log-distributed): all 10
    reference species detected; 7 of 7 recovered MAGs correctly classified by
    GTDB-Tk with no false calls.
  - **SIGMA** — a Zymo reference *E. coli* isolate: hybrid ONT assembly
    reached 100.000% genome fraction against the certified reference genome
    with zero misassemblies.
  - **DOGMA** — a published soil metatranscriptome time course (Chuckran et
    al. 2021): 11 of 12 real nitrogen-cycle gene/category directions matched
    the paper's own reported results.
  - **DEFINE** — a published *E. coli* irradiation RNA-seq study: DEG call
    rate matched the source paper's order of magnitude, with full
    functional-category overlap.
  - **PRISM** — a ZymoBIOMICS 16S mock community sequenced by the vendor:
    strong compositional agreement (Bray-Curtis 0.08-0.11) with the vendor's
    own classification of the identical reads.
  
  Mixed and partial outcomes (e.g. MAGMA's read-based quantitative accuracy,
  SIGMA's PacBio-chemistry misassemblies) are reported alongside the strong
  results rather than smoothed over. Exact configuration, curated ground
  truth, and raw observed-vs-expected results for every pipeline are
  published at
  [OmniOmics-validation](https://github.com/oliv-angelus/OmniOmics-validation)
  ([Zenodo DOI](https://doi.org/10.5281/zenodo.22780175)), and reported in
  full in the accompanying manuscript (`paper/` in this repository).

### Pending

- **Sustained use by people other than the author.**
- **PRISM's PacBio marker-gene path** (the vendor's Kinnex 16S
  mock-community release) remains unvalidated: the vendor's own data host
  was unreachable from both the analysis machine and the compute node used
  for this work at the time it was set up, a real external infrastructure
  constraint documented in the companion repository.

### Roadmap

| | |
|---|---|
| **Now** | v1.0.0: all five pipelines validated end to end on real datasets (see above) |
| **Future** | Additional pipelines, a GROND/full rrn-operon mode for PRISM, an expanded Plots-tab library for SIGMA |

### Other current limitations

- **Linux only.** Built and tested on Linux; Windows and macOS not attempted.
- **Some optional steps have not been run end to end on real input**, namely
  BiG-SCAPE (secondary-metabolite block) and VIBRANT (viral block) —
  antiSMASH and the rest of the viral block (VirSorter2, CheckV, geNomad)
  have.
- **The genome ring is a static figure**, not an interactive browser. Tracks are
  toggled by re-running the analysis.

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
