# Installing OmniOmics

Linux only, for now. The application has been built and tested on Debian-family
Linux; Windows and macOS have not been attempted.

---

## What you need before starting

| | Why |
|---|---|
| **Linux, x86-64** | the only platform built and tested |
| **~25 GB free disk** | tool environments, before any reference database |
| **More disk for databases** | varies enormously; GTDB alone is tens of GB |
| **8 GB RAM minimum** | enough for the app, PRISM and DEFINE; MAGMA and DOGMA want far more |
| **A CPU with AVX2** | required by MAGMA and SIGMA (CheckM2, SemiBin2); check with `lscpu \| grep avx2` |
| **Internet access on first run** | conda, tool environments and databases are fetched on demand |

Per-pipeline figures, including the pipelines that will not run at all without
AVX2, are in [REQUIREMENTS.md](REQUIREMENTS.md). Read it before a large run:
MAGMA's memory floor is set by GTDB-Tk's documented 150 GB.

You do **not** need conda, Snakemake, R or any bioinformatics tool installed
beforehand. The application installs what it needs, when it needs it.

---

## Installing — the packaged build

This is how OmniOmics is meant to be installed. Download the `.deb` from the
[Releases page](https://github.com/oliv-angelus/OmniOmics/releases), then:

```bash
sudo dpkg -i omniomics_0.0.1_amd64.deb
omniomics
```

The application also appears in the desktop menu under Science.

To remove it:

```bash
sudo dpkg -r omniomics
```

Uninstalling does not delete conda environments, downloaded databases or your
run outputs. Those live under your home directory and in whatever output
folders you chose, and have to be removed by hand if you want the space back.

---

## Running from source — for development only

**This is not an installation method.** `run_dev.sh` rebuilds the Flutter app
and launches it against a backend started from the working tree; it exists for
modifying the pipelines or the analyses, and for debugging. If you only want to
use OmniOmics, install the `.deb` above — it needs no Flutter SDK, no Python
environment and no build toolchain.

Two practical differences from the packaged build, worth knowing if you are
comparing behaviour between them:

- The backend runs as `python3 main.py` rather than the compiled binary, so path
  resolution takes a different branch (`__file__` instead of `sys.executable`).
- `pipelines/` and `plots/` are read from the working tree instead of
  `/opt/omniomics/`, which means a packaging mistake in either can be invisible
  here and fatal there.

### Dependencies

```bash
sudo apt install git python3 python3-venv curl unzip \
                 clang cmake ninja-build pkg-config libgtk-3-dev
```

Flutter (3.x) must be on your `PATH` with Linux desktop support enabled:

```bash
flutter config --enable-linux-desktop
flutter doctor          # should report no blocking issues for Linux
```

### Running

```bash
git clone https://github.com/oliv-angelus/OmniOmics.git
cd OmniOmics
./run_dev.sh
```

`run_dev.sh` creates a Python virtual environment, installs the backend's
requirements, starts the backend, and launches the Flutter application against
it. Both stop together when you close the window.

### Building the package yourself

The same `.deb` the release ships.

```bash
./build.sh
```

Produces `dist/omniomics_<version>_amd64.deb`. Needs `dpkg-deb` and `fakeroot`
in addition to the dependencies above. The script compiles the backend into a
single binary with PyInstaller, builds the Flutter release bundle, and stages
both together with `pipelines/` and `plots/`.

---

## First run

The application walks through setup, but knowing the order helps:

1. **conda.** Offered on first launch if not found. Installs miniforge into your
   home directory; nothing system-wide is touched.
2. **Snakemake.** Installed into its own conda environment.
3. **Reference databases.** The Databases tab lists what each tool needs, with
   sizes. Download only what the pipelines you plan to run actually use — some
   are very large, and none are needed until a run asks for them.
4. **Tool environments.** Built automatically the first time you run a pipeline
   that needs them. The first run of any pipeline is therefore much slower than
   later ones; the log shows conda working rather than hanging.
5. **The R environment.** Built the first time you open the Plots tab. This one
   is large and takes a while, because it carries phyloseq, DESeq2, vegan and
   their dependency trees.

---

## Where things are stored

| What | Where |
|---|---|
| Settings, run history | `~/.omniomics.json` |
| conda environments | inside your conda installation |
| Reference databases | the folder you choose in the Databases tab |
| Run outputs | the folder you choose when launching each run |
| Plot outputs | `<run output>/plots/` |

The settings file is plain JSON and safe to read. Note that the Plots tab lists
runs from it, not from disk: if it is lost, previous runs stop appearing even
though their output is intact. **Plots → Import folder** brings them back.

---

## Troubleshooting

**The backend fails to start.** `run_dev.sh` reports the Python error. The most
common cause is a virtual environment built against a different Python version
after a system upgrade — delete `.venv` and run again.

**A pipeline fails immediately on first use.** Almost always a conda environment
that has not finished building, or a missing database. The run log names the
rule that failed and the tool it was trying to invoke.

**The Plots tab says the R environment is missing.** It is built on first use
and takes several minutes. If it failed, the Plots tab offers to rebuild it and
shows conda's own error.

**A tool dies with `Illegal instruction (core dumped)`.** The CPU lacks AVX2.
CheckM2 and SemiBin2 (MAGMA, SIGMA) cannot run without it — see
[REQUIREMENTS.md](REQUIREMENTS.md) for which pipelines are affected and what
still works.

**A step dies abruptly with no error of its own.** Usually the operating
system's OOM killer, which leaves nothing in the run log. Check the pipeline's
memory requirements; GTDB-Tk alone documents 150 GB.

**An analysis refuses with a message about missing data.** That is by design —
the message names what is missing and why. Analyses do not draw figures they
cannot support.

---

## Uninstalling completely

```bash
sudo dpkg -r omniomics                 # the application
rm ~/.omniomics.json                   # settings and run history
conda env remove -n r-plots            # the R environment
conda env remove -n snakemake          # Snakemake
```

Per-tool environments created by Snakemake live under each pipeline's conda
prefix and can be removed with `snakemake --conda-cleanup-envs`, or by deleting
the `.snakemake` directory in a run's output folder.
