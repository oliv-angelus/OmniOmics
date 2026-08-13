# System requirements

What OmniOmics needs to run, and what each pipeline needs on top of that.

Two things are worth reading before the tables:

**The application is light; the tools are not.** OmniOmics itself is a desktop
app and a local backend, and would run on any modern laptop. The requirements
below are almost entirely driven by the bioinformatics tools it orchestrates,
and by the size of the data you feed them. A pipeline that never runs GTDB-Tk
has completely different needs from one that does.

**Requirements scale with your data, not with the software.** The figures here
are for the tools' own documented needs and for datasets of ordinary size. A
deeply sequenced soil metagenome can exceed any of them. Where a number comes
from a tool's own documentation it is marked; the rest are practical estimates
and are labelled as such.

---

## Baseline — the application itself

| | Minimum | Recommended |
|---|---|---|
| OS | Linux x86-64 | Linux x86-64 |
| CPU | 2 cores | — |
| RAM | 4 GB | 8 GB |
| Disk | 25 GB | 50 GB + database space |

This covers the interface, the backend, the conda tool environments and the R
plotting environment. It does **not** include reference databases or your own
data. Databases are by far the largest item and are downloaded only for the
tools you actually enable — see [Databases](#reference-databases).

Windows and macOS have not been built or tested.

---

## CPU instruction set: AVX2

**Some pipelines will not run on a CPU without AVX2.** This is not a
performance note — the affected tools abort with `Illegal instruction (core
dumped)`, which looks like a crash rather than an unsupported-hardware message.

Check your CPU before installing:

```bash
lscpu | grep -o avx2 | head -1        # prints "avx2" if supported
```

Practically every x86-64 CPU released since 2013 (Intel Haswell, AMD Excavator
and later) has AVX2. The ones that do not are older Xeons still common in
institutional servers, and some low-power/embedded parts.

| Tool | Why | Affects |
|---|---|---|
| **CheckM2** | depends on TensorFlow 2.17, whose official builds require AVX/AVX2 | MAGMA, SIGMA |
| **SemiBin2** | depends on PyTorch, same constraint | MAGMA |
| **MMseqs2** | ships separate AVX2 / SSE4.1 / SSE2 builds; conda normally installs the AVX2 one | DOGMA |
| **medaka** | ONT polishing, ML-backed | SIGMA (long-read path) |

**Without AVX2:** DEFINE and PRISM are unaffected. MAGMA and SIGMA lose genome
quality assessment (CheckM2) and MAGMA loses one of its three binners.

---

## Per-pipeline requirements

RAM is stated as the **peak** of the pipeline's heaviest step, since that is
what determines whether a run completes. Cores are the point past which more
cores stop helping much for a typical dataset.

### MAGMA — metagenomics

The most demanding of the five, by a wide margin.

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 64 GB | **150+ GB** | GTDB-Tk |
| Cores | 8 | 32+ | assembly, binning |
| Disk per run | 100 GB | 500 GB+ | intermediates |

- **GTDB-Tk requires 150 GB of memory** for classification against the
  bacterial tree — this is the tool's own documented figure, and it is the hard
  floor for a full MAGMA run. Taxonomy can be disabled; everything else in
  MAGMA runs comfortably below it.
- **Assembly** (MEGAHIT, SPAdes, Flye) is the next peak and scales directly with
  library size and community complexity. MEGAHIT is markedly lighter than
  SPAdes on metagenomes and is the better default on constrained hardware.
- **Binning** runs three binners over the same assembly; disk, not RAM, is
  usually the constraint.
- Requires **AVX2** (CheckM2, SemiBin2).

### SIGMA — isolate genomics

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 16 GB | **150+ GB with GTDB-Tk**, 32 GB without | GTDB-Tk |
| Cores | 4 | 16 | assembly, annotation |
| Disk per run | 20 GB | 100 GB | per genome |

An isolate genome is small, so everything except taxonomy is modest — assembly,
polishing, annotation and typing all run in 16-32 GB. The 150 GB figure is
GTDB-Tk's alone. Requires **AVX2** (CheckM2; medaka on the long-read path).

### DOGMA — metatranscriptomics

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 32 GB | 64-128 GB | Trinity |
| Cores | 8 | 16+ | assembly |
| Disk per run | 100 GB | 300 GB+ | assembly intermediates |

- **Trinity** dominates. Its own documented rule of thumb is roughly **1 GB of
  RAM per 1 million reads**, so requirements follow sequencing depth almost
  linearly. MEGAHIT is available as a lighter alternative.
- Requires **AVX2** if MMseqs2 is enabled.

### DEFINE — differential expression

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 8 GB | 16 GB | Bowtie2 index |
| Cores | 4 | 8 | mapping |
| Disk per run | 20 GB | 50 GB | BAM files |

The lightest of the five for bacterial genomes: mapping against a single
reference plus counting. No AVX2 requirement. Runs on an ordinary workstation.

### PRISM — amplicon sequencing

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 8 GB | 16-32 GB | DADA2 error model |
| Cores | 4 | 8 | denoising |
| Disk per run | 10 GB | 50 GB | modest |

- **DADA2's error model** is the peak and grows with the number of samples
  processed together. Very large cohorts benefit from more RAM.
- **PICRUSt2** is optional and is the one step that can exceed the rest; it is
  disabled by default.
- No AVX2 requirement.

---

## The Plots tab

Independent of which pipeline produced the data.

| | Minimum | Recommended |
|---|---|---|
| RAM | 4 GB | 8 GB |
| Cores | 2 | 4 |

Two things are heavier than the rest and worth knowing about:

- **Building the R environment** happens once, on first use, and pulls
  phyloseq, DESeq2, vegan and their dependency trees. It takes several minutes
  and looks stalled; the log shows conda working.
- **The genome ring** (`sigma_genome_ring`) computes GC in windows over the
  whole assembly and renders twice, at preview and publication resolution. It
  takes about half a minute per genome.

---

## Reference databases

Databases are downloaded only for the tools you enable, and are almost always
larger than everything else combined. Sizes vary between releases, so the
Databases tab reports the current size before downloading rather than repeating
a figure here that would go stale.

Order of magnitude, so you can plan disk:

| Database | Used by | Scale |
|---|---|---|
| GTDB | GTDB-Tk | tens of GB — the largest |
| Kraken2 standard/PlusPFP | Kraken2, Bracken | tens of GB |
| eggNOG | eggNOG-mapper | tens of GB |
| CheckM2, GUNC | quality assessment | a few GB each |
| SILVA | PRISM | a few GB |
| CARD, VFDB, AMRFinderPlus | resistance/virulence | under 1 GB each |
| Bakta | annotation | ~30 GB (full) or ~1.5 GB (light) |

Databases live in a folder you choose, and are shared across runs and pipelines
— they are downloaded once, not per run.

---

## Running on constrained hardware

If the machine is smaller than the recommendations above, these are the
adjustments that actually help, in order of impact:

1. **Disable GTDB-Tk.** It alone sets the 150 GB floor for MAGMA and SIGMA.
   Kraken2 and Kaiju still provide taxonomy at read level.
2. **Use MEGAHIT rather than SPAdes** for metagenomes, and MEGAHIT rather than
   Trinity for metatranscriptomes.
3. **Subsample reads** for a first pass, to confirm the configuration is right
   before committing to a full run.
4. **Reduce the core count.** Several tools scale their memory with threads, so
   fewer threads can be the difference between finishing and being killed.
5. **Use the Plots tab on its own.** It runs comfortably on a laptop and can
   import results produced elsewhere — see
   [`plot_input_formats.md`](plot_input_formats.md).

A run killed for memory usually appears in the log as the tool being terminated
with no error of its own — the operating system's OOM killer leaves no message
in the run log. If a step dies abruptly with no explanation, memory is the first
thing to check.

---

## Notes on these figures

- Numbers marked as documented come from the tool's own documentation:
  **GTDB-Tk 150 GB** and **Trinity ~1 GB per 1M reads**.
- The remaining figures are practical estimates for datasets of ordinary size.
  They have **not** been established by benchmarking on large datasets, for the
  reason given in the README's validation section: the compute available in our
  current laboratory does not permit it. A benchmark is in preparation and its
  measurements will replace these estimates.
- AVX2 dependencies were derived from the environment specifications under
  `pipelines/*/workflow/envs/` and from each tool's own build requirements.
