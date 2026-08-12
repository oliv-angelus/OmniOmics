# Installing OmniOmics

Linux only, for now. The application has been built and tested on Debian-family
Linux; Windows and macOS have not been attempted.

---

## What you need before starting

| | Why |
|---|---|
| **Linux, x86-64** | the only platform built and tested |
| **~20 GB free disk** | tool environments, before any reference database |
| **More disk for databases** | varies enormously; GTDB alone is tens of GB |
| **8 GB RAM minimum** | assembly and binning want considerably more; 32 GB+ for real metagenomes |
| **Internet access on first run** | conda, tool environments and databases are fetched on demand |

You do **not** need conda, Snakemake, R or any bioinformatics tool installed
beforehand. The application installs what it needs, when it needs it.

---

## Option 1 — the packaged build (recommended)

Download the `.deb` from the repository's Releases page, then:

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

## Option 2 — running from source

Useful if you want to modify the pipelines or the analyses.

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
though their output is intact. **Plots → Importar pasta** brings them back.

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
