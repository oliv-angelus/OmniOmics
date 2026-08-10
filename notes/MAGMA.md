# MAGMA

Metagenome-assisted MAG (metagenome-assembled genome) analysis pipeline. First pipeline plugged into [[Project Overview|OmniOmics]]. Category: `metagenomics`.

Lives at `pipelines/magma/` — `Snakefile` + `workflow/rules/*.smk` (8 stage files: QC/taxonomy, assembly, mapping, binning, MAG refinement, dereplication/taxonomy, annotation/mobilome, coverage) + `pipeline.yaml` (see [[Pipeline Manifest Schema]]).

Source of truth for the actual pipeline logic is `MAGMA-main` (a separate, non-app repo the user publishes independently) — `pipelines/magma/`'s Snakefile/workflow were copied from there, not from the `MAGMA-ideia-de-app` Electron prototype, which had drifted (see [[Decisions Log]] for a concrete example: a stale non-hybrid `metaspades` rule that only existed in the prototype).

42 tools across 11 categories, 13 downloadable reference databases. Full dependency chain: [[MAGMA Dependency Graph]].

## Read-level taxonomy: two independent classifiers

Kraken2/Bracken/kreport2mpa (k-mer/nucleotide) and Kaiju (protein-level, translated search) are both optional and independent — either, both, or neither can be active, since they only need clean reads, not each other. Kaiju's own output shape doesn't fit Kraken2's report format, so it gets its own chain (`kaiju_classify` → `kaiju_table` → `consolidate_taxonomy_kaiju`) instead of feeding Bracken/kreport2mpa. See [[Decisions Log]].

Icon: orange/black volcano, `build/icon.png` (kept from the original Electron prototype's branding).

## Pipeline flowchart — `pipelines/magma/MAGMA.drawio.svg`

User-maintained metro-map-style diagram (nf-core icon set, hand-edited in app.diagrams.net/draw.io) of the real MAGMA DAG. **Reviewed against [[MAGMA Dependency Graph]] 2026-07-28** (the ground-truth doc derived from reading the actual `.smk` rules) and found + the user fixed 6 real discrepancies: missing `drep` node (GTDB-Tk/CoverM were shown depending on Binette's raw output directly, not on `drep` — exactly the misconception that doc's "Key corrections" section already once flagged); Bowtie2/Minimap2 shown mapping against unfiltered `contigs` instead of Tiara's prokaryotic-filtered output; VirSorter2/Genomad/VIBRANT/MOBsuite shown gated behind Prodigal/Tiara when they actually run on the unfiltered assembly; "MOBsite" typo for MOBsuite; CheckV missing entirely (depends on VirSorter2); VFDB missing from both the sample and MAGs annotation tracks. All confirmed fixed after the user's edits (re-rendered and diffed against the dependency graph a second time). Remaining simplifications (CheckV/BIGscape drawn as siblings of their tool group rather than strictly downstream of VirSorter2/Antismash specifically) are deliberate legibility choices, not errors — flagged and accepted.

**How this file works, if it needs touching again**: it's a real draw.io SVG export with the full editable `mxfile` XML embedded in a `content="..."` attribute on the root `<svg>` (decode with `html.unescape` after regex-extracting the attribute) — so it opens natively in draw.io/diagrams.net despite being a `.svg` file. To render it headlessly for review (no draw.io CLI available in this environment): `firefox --headless --screenshot out.png --window-size=4300,2500 -profile <fresh-tmp-dir> "file://$(pwd)/MAGMA.drawio.svg"` — cairosvg fails on this file (chokes on a `requiredFeatures` URI it misparses as a color), Firefox handles it fine. The companion icon library (station dots, file-type icons, connector/bridge conventions, palette) lives at `pipelines/ICONES BASE.drawio.svg`, same embedding trick.
