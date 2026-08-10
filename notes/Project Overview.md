# OmniOmics — Project Overview

**What it is:** A desktop hub (Flutter, native UI, light/dark theme) for running Snakemake bioinformatics pipelines without touching a terminal. [[MAGMA]] (metagenomics), [[SIGMA]] (single isolate genomes), [[DOGMA]] (metatranscriptomics, structurally complete through Phase 2 — assembly, annotation, taxonomy, quantification, MAGMA Cross-Reference), and **DEFINE** (bacterial isolate RNA-seq / differential expression — "Differential Expression, Functional Interpretation & Network Enrichment," `pipelines/define/`) are the four pipelines plugged in, proving out the "add a pipeline as a new folder under `pipelines/`, no app/backend code changes" architecture for real. A 5th, **[[PRISM]]** (long-read amplicon sequencing, 16S/ITS metabarcoding, ONT+PacBio HiFi), has its first slice built (`pipelines/prism/`, dry-run verified, no real tools installed/run yet) — see [[PRISM]] for the full design and status. Several more (Proteômica, Metaproteômica, Metabolômica, Single-cell, Pangenômica, Genotipagem) exist as "Em construção" placeholder cards in the Hub, not yet built.

**Gráficos (Plots) tab**: a separate `plots/` engine (R/phyloseq/DESeq2/vegan-based, sibling to `pipelines/`) generates real statistical analyses from a finished run's output — 11 community-ecology analyses for MAGMA (alpha/beta diversity, taxonomic composition, DESeq2, RDA, co-occurrence network, indicator species, Venn, Good's Coverage, rarefaction), 7 differential-expression analyses for DEFINE (PCA, MA/volcano plots, DE heatmap, functional enrichment, UpSet). SIGMA, DOGMA, and the upcoming amplicon pipeline don't have their own analysis sets yet — building those out is the current next step alongside the amplicon pipeline itself.

**Location:** `/home/angelo/Downloads/OmniOmics/` (renamed from `MAGMA-hub` on 2026-07-03).

## Architecture

```
OmniOmics/
  app/            Flutter desktop app (Dart) — the UI, no HTML/WebView
  backend/        FastAPI/Python backend — pipeline registry, install flows,
                   database downloads, Snakemake execution, log parsing
  pipelines/
    magma/        Metagenomics: Snakefile + workflow/ + pipeline.yaml manifest
    sigma/        Single isolate genomes: same shape as magma/
    dogma/        Metatranscriptomics: same shape, see [[DOGMA]]
    define/       Bacterial isolate RNA-seq / differential expression: same shape
  plots/          Gráficos tab's R engine (sibling to pipelines/): manifest.yaml +
                   r_env/ + scripts/{lib,analyses,export}/ — see the Plots tab
                   entries in [[Known Issues and Next Steps]] for the full design
  scripts/        One-off migration/patch scripts that generated pipeline.yaml
  build.sh        Packages everything into dist/omniomics_<ver>_amd64.deb
  .venv/          Backend's Python venv (dev mode only; packaged mode bundles
                   a PyInstaller binary instead)
```

**Key design decision:** the Flutter app is a thin client. It spawns the FastAPI backend as a child process (`BackendLauncher` in `app/lib/services/backend_launcher.dart`) and talks to it over HTTP + WebSocket on `127.0.0.1:8765`. All the hard logic (conda/snakemake install, database downloads with progress, Snakemake log parsing) lives in the backend, ported near-verbatim from an earlier Electron prototype (`MAGMA-ideia-de-app`).

**Pipeline registry:** `backend/pipelines.py` discovers pipelines by scanning `pipelines/*/pipeline.yaml` at startup. Adding a pipeline means creating `pipelines/<id>/` with its own `Snakefile` + `pipeline.yaml` — no backend/app code changes needed; SIGMA is the proof this actually works, not just the plan. See [[Pipeline Manifest Schema]].

**Shared databases live at the Hub level, not per-pipeline** — `DatabasesScreen` (nav rail, before picking a pipeline) lists every database across every installed pipeline, deduped by its underlying `setting_key`, so e.g. CheckM2 (used by both MAGMA and SIGMA) is configured once. Each pipeline's own Launch screen only shows a read-only status check now.

**The Launch screen (per pipeline) embeds in the Hub's body instead of pushing a full-screen route** (`embeddedPipelineProvider`/`embeddedMonitorProvider` in `providers.dart`) — the sidebar nav rail stays usable while configuring or watching a run. Tab order is Entradas → Ferramentas → Bancos de dados → Recursos → Revisão.

## Running it

- **Dev desktop launcher (recommended day-to-day)**: `run_dev.sh` (repo root) or the "OmniOmics (Dev)" app-menu entry it's wired to (`~/.local/share/applications/omniomics-dev.desktop`) — rebuilds Flutter fresh, forces `GDK_BACKEND=x11` (this machine's Wayland session otherwise produces zero window, silently), and sets `OMNIOMICS_DEV_RELOAD=1` so `pipeline.yaml` edits reflect live without closing the app. See [[Known Issues and Next Steps]].
- Dev mode (no install needed): `app/build/linux/x64/debug/bundle/omniomics` (rebuild via `cd app && flutter build linux --debug`) — same binary `run_dev.sh` wraps, useful directly if you don't need the X11/reload conveniences.
- Packaged: `./build.sh` produces `dist/omniomics_<ver>_amd64.deb` → `sudo dpkg -i ...`. **No packaged build currently exists** — the last one (`dist/magma-hub_0.1.0_amd64.deb`) predated the rename and SIGMA, and was deleted as stale; run `./build.sh` fresh before distributing.
- Backend deps: `.venv` (recreate with `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`).

## Branding

- Hub name: **OmniOmics** (was "Ominiomics" typo'd by the user, corrected; alternatives considered: PanOmics, OmicsForge, OmicsFlow, NexOmics).
- First pipeline keeps the name **MAGMA** (user's call — has brand equity/icon already, backronym meaning no longer "Metagenome Assisted GUI" since it's not its own GUI anymore, but the name itself stays).
- Second pipeline named **SIGMA** — see [[SIGMA]] and [[Decisions Log]] for the naming story.
- Third pipeline named **DOGMA** — chosen for the MAGMA/SIGMA "-GMA" sound family *and* the "central dogma" (DNA→RNA→protein) callback, exactly what metatranscriptomics adds on top of MAGMA. See [[DOGMA]]/[[Decisions Log]].
- Fourth pipeline named **DEFINE** ("Differential Expression, Functional Interpretation & Network Enrichment") — a real letter-by-letter acronym of what the pipeline does, not forced to rhyme with the MAGMA/SIGMA/DOGMA "-GMA" family. **Naming convention going forward**: every pipeline name needs genuine meaning (a real acronym mapping to real capabilities, and/or a real scientific-concept callback like DOGMA's) — the "-GMA" rhyme was never a hard requirement, DEFINE is proof, and a name should never be picked just because it sounds nice.
- App icon: hub-and-spokes design (teal, matches the UI's primary accent color `#0D9488`), at `build/app_icon.png` / `app/assets/app_icon.png`. Two alternative concepts (orbit rings, overlapping circles) exist in case the user wants to switch later — ask if unsure where they are, they were scratchpad-only and may not be preserved.
- MAGMA pipeline keeps its own icon (orange/black volcano) at `build/icon.png` / `app/assets/pipeline_icons/magma.png`, shown on its Hub card. SIGMA's icon is a Σ glyph mark.
