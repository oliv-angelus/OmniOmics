# System requirements

What OmniOmics needs to run, and what each pipeline needs on top of that.

Two things are worth reading before the tables:

**The application is light; the tools are not.** OmniOmics itself is a desktop
app and a local backend, and would run on any modern laptop. The requirements
below are almost entirely driven by the bioinformatics tools it orchestrates,
and by the size of the data you feed them. A pipeline run with a 232-GB
Kraken2 database has completely different needs from one run with a 16-GB one.

**Requirements scale with your data, not with the software.** The figures here
are the peaks measured in the validation runs (Snakemake's benchmark directive,
on the datasets of the OmniOmics-validation repository) unless marked
otherwise. A deeply sequenced soil metagenome can exceed any of them.

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

**Read-classifier databases set the peak.** Kraken2 and Kaiju load their whole
database into RAM, about 1.05-1.15 × its size on disk. In the validation,
Kraken2 with the PlusPFP database (232 GB on disk) peaked at 232-248 GB and
Kaiju with nr_euk (174 GB on disk) at 194-199 GB. With a smaller Kraken2
database (Standard-16 or PlusPF-16, ~16 GB) and Kaiju off, the pipelines below
need a fraction of that. Rules that load a database declare its memory, so
Snakemake never starts two of them at once beyond the memory you give the run.

### MAGMA — metagenomics

| | With PlusPFP Kraken2 | With a 16-GB Kraken2 database, Kaiju off |
|---|---|---|
| RAM | **~256 GB** | 64 GB |
| Cores | 32+ | 16+ |
| Disk per run | ~60 GB (validation: 2 samples) | same |

- Measured peaks apart from the classifiers: metaSPAdes 44 GB, GTDB-Tk 15 GB
  (2.7.2, release R232, 8 MAGs), BBNorm 96 GB (a Java heap sized to the memory
  available, not a requirement).
- **Assembly** scales with library size and community complexity. MEGAHIT is
  markedly lighter than metaSPAdes and is the better choice on constrained
  hardware.
- Requires **AVX2** (CheckM2, SemiBin2).

### SIGMA — isolate genomics

| | With PlusPFP Kraken2 screening | Without it |
|---|---|---|
| RAM | **~256 GB** | 32 GB |
| Cores | 16 | 8 |
| Disk per run | ~5 GB | same |

An isolate genome is small: assembly, polishing, annotation and typing all ran
within 23 GB (Unicycler's peak). The large figure is the optional Kraken2 read
screening. Requires **AVX2** (CheckM2; medaka on the long-read path).

### DOGMA — metatranscriptomics

| | With PlusPFP Kraken2 screening | Without it |
|---|---|---|
| RAM | **~256 GB** | 64 GB |
| Cores | 16+ | 16+ |
| Disk per run | ~270 GB (validation: 8 samples) | same |

- Measured peaks apart from the classifiers: Trinity 54 GB, eggNOG-mapper
  42 GB with its database loaded in memory (`--dbmem`; the run's memory budget
  decides how many run at once).
- **Trinity** grows with sequencing depth (its documentation: roughly 1 GB of
  RAM per million reads); MEGAHIT is the lighter alternative.
- Requires **AVX2** if MMseqs2 is enabled.

### DEFINE — differential expression

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 8 GB | 16 GB | Bowtie2 (13 GB measured) |
| Cores | 4 | 8 | mapping |
| Disk per run | 20 GB | 50 GB | BAM files |

The lightest of the five for bacterial genomes: mapping against a single
reference plus counting. No AVX2 requirement. Runs on an ordinary workstation.

### PRISM — amplicon sequencing

| | Minimum | Recommended | Peak driver |
|---|---|---|---|
| RAM | 8 GB | 16-32 GB | DADA2 error model; Emu 3.5 GB measured |
| Cores | 4 | 8 | denoising |
| Disk per run | 10 GB | 50 GB | modest |

- **DADA2's error model** grows with the number of samples processed together.
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

- **Building the R environment** happens once and pulls phyloseq, DESeq2,
  vegan, ape and their dependency trees -- around 700 conda packages. Expect
  tens of minutes, most of it with nothing printed while conda solves and
  downloads; the log shows it working. Install it from **Settings →
  Dependencies → R environment**, or from the banner the Plots tab shows while
  it is missing. Until 2026-08-14 there was no way to start it from the
  interface at all, and the spec it builds from did not solve; both are fixed.
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
| Kraken2 PlusPFP / Standard-16 | Kraken2, Bracken | ~232 GB / ~16 GB |
| Kaiju nr_euk | Kaiju (optional) | ~174 GB |
| GTDB | GTDB-Tk | ~110 GB |
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

1. **Use a small Kraken2 database and leave Kaiju off.** Kraken2 PlusPFP
   (~232 GB) and Kaiju (~200 GB) set the memory floor of MAGMA, SIGMA and
   DOGMA; Standard-16 or PlusPF-16 (~16 GB) brings it down to the assembly's
   needs.
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

- Measured figures come from the validation runs (OmniOmics-validation; time,
  memory and disk per pipeline are also in the accompanying manuscript). They
  are for those datasets, not upper bounds.
- Trinity's ~1 GB per million reads is from its own documentation.
- AVX2 dependencies were derived from the environment specifications under
  `pipelines/*/workflow/envs/` and from each tool's own build requirements.
