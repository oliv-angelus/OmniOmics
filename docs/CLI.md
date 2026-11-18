# Command line and HPC

The pipelines can run without the graphical interface: on a workstation or
server from a terminal, or on an HPC cluster as one PBS job. The command line
builds `samples.tsv`, `config.yaml` and the Snakemake call with the same code
as the app's Launch screen, so the same settings give the same run.

Plotting is not part of the command line: copy the run's `results/` folder to
a computer with the app and open it in the Plots tab (or analyse it in R).

## Install on a server

```bash
git clone https://github.com/oliv-angelus/OmniOmics.git
cd OmniOmics
conda env create -f envs/omniomics-cli.yaml     # Snakemake 9.26.0, conda 26.7.2, pinned
conda activate omniomics-cli
bin/omniomics list
```

Works on any x86-64 Linux with conda (Debian, RHEL, openSUSE, ...); no
administrator rights are needed. The tools themselves are installed by
Snakemake into per-tool conda environments on the first run.

## 1. Describe the run

```bash
bin/omniomics init magma -o run.yaml
```

writes a commented run file with every default of the pipeline. Fill in:

```yaml
pipeline: magma
output_dir: /data/project/magma_run1
inputs:
  short_reads_dir: /data/project/reads_illumina   # one sub-folder per sample
  long_reads_dir: /data/project/reads_nanopore    # optional
databases_dir: /data/databases                     # every database found below it is used
databases:
  kraken2: /data/databases/k2_pluspf_16            # explicit paths win
conda_prefix: /data/omniomics_envs                  # shared by all runs
ram_gb: 240
disable_tools: [maxbin2]
tool_flags:
  kraken2: "--confidence 0.1"
```

Inputs follow the app's convention: each sample is a sub-folder holding its
reads (`SAMPLE_R1.fastq.gz` / `SAMPLE_R2.fastq.gz`, `SAMPLE_1.fq.gz`, or the
Illumina `SAMPLE_S1_L001_R1_001.fastq.gz` names; long reads as any
`.fastq(.gz)`/`.fq(.gz)`).

A run set up in the app can be exported instead: **Launch → Review → Export
for command line** writes `<output_dir>/config/run.yaml`. Edit its paths if
the server sees the data elsewhere.

## 2. Databases

```bash
bin/omniomics db list magma                       # databases and download options
bin/omniomics db detect magma /data/databases     # which are already installed
bin/omniomics db download magma kraken2 --option k2_pf_16 --dir /data/databases/kraken2
```

## 3. Run

On the machine you are logged into:

```bash
bin/omniomics envs run.yaml                       # optional: build the tool environments first
bin/omniomics run run.yaml -n                     # dry run: what would run
bin/omniomics run run.yaml --cores 32 --ram-gb 120
```

`--ram-gb` (or `ram_gb` in the run file) is the memory budget: rules that load
a whole database into memory (Kraken2, Kaiju: database size on disk × 1.15)
or are known to need more (GTDB-Tk, CheckM2, GUNC, antiSMASH) declare it, so
Snakemake never starts two of them at once beyond the budget. A failed run is
retried up to `--attempts` times (default 3), unlocking first; re-running the
same command later resumes where it stopped.

## 4. On an HPC cluster (PBS Pro)

```bash
bin/omniomics run run.yaml --submit pbs \
    --queue cpu --ncpus 64 --mem-gb 240 --walltime 72:00:00
```

submits **one job** in which the whole pipeline runs (the Snakemake
controller and every rule on the same node, using `--ncpus` cores and 95% of
`--mem-gb`). Nothing heavy runs on the login node: it only writes the run's
config and calls `qsub`. This works on clusters whose compute nodes cannot
submit jobs themselves. Other options: `--account`, `--select-extra
host=node02` (extra terms for `-l select`), `--print-only` (show the job
script without submitting). The job script is kept in
`<output_dir>/logs/omni_<pipeline>_<date>.pbs` and its output in
`<output_dir>/logs/omni_<pipeline>.out`.

Database downloads and environment builds can be sent as jobs too:

```bash
bin/omniomics envs run.yaml --submit pbs --ncpus 4 --mem-gb 16 --walltime 12:00:00
bin/omniomics db download magma gtdbtk --option ... --dir /data/databases/gtdbtk \
    --submit pbs --walltime 24:00:00
```

Choose `--mem-gb` from the databases you use: with Kraken2 PlusPFP (~232 GB)
MAGMA and SIGMA need a node with about 256 GB; with Standard-16 or PlusPF-16
(~11 GB) and Kaiju off, 64 GB is enough for most runs. Measured time and
memory per pipeline are in the manuscript's Table S2.

SLURM is not supported yet.

## Other commands

```bash
bin/omniomics unlock run.yaml      # stale lock after an interrupted run
bin/omniomics run run.yaml --snakemake-args --forcerun vibrant_sample   # pass options to Snakemake
```
