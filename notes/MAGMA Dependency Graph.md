# MAGMA Dependency Graph (ground truth, from reading the .smk rules directly)

Derived by reading every rule's `input:` section in `pipelines/magma/workflow/rules/*.smk` — not from the manifest's old `dependencies` field, which had drifted from reality (see [[Decisions Log]]).

## Key corrections made vs. what was assumed before

- **binette** requires **all 4** binners as a hard AND in the original code — NOT "at least 2" as the user initially recalled. Fixed by editing the actual Snakemake rule (`05_mag_refine.smk`) to read `config["active_binners"]` dynamically and validate `len(active) >= 2` at parse time (previously `active_tools`/`active_binners` were computed by the backend but **never read by the Snakefile at all** — toggles were 100% cosmetic before this fix).
- **mags_annot** is not a real Snakemake rule — no `rule mags_annot:` exists anywhere. It's a pure quality-threshold filter (`hq_min_completeness`/`hq_max_contamination`) embedded inside the `pool_hq_mags` rule in `06_dereplication_tax.smk`, thresholding checkm2's output before copying bins to drep.
- Many tools have **two separate Snakemake rules** sharing one GUI toggle: a `_sample` variant (runs on prokaryotic contigs, independent of binning) and a `_mags` variant (runs on drep's dereplicated genomes). E.g. `abricate_sample` + `abricate_mags`, both gated by one "Abricate" switch. `rule_names` in the manifest lists both so disabling the toggle omits both.
- 3 tools use **unfiltered** contigs (`finalize_assembly`'s output), not tiara's prokaryotic-filtered ones: `virsorter2_sample`, `genomad_sample`, `vibrant_sample` (viral/mobile-element detectors shouldn't be restricted to prokaryotes-only).
- `coverm` maps reads against a **fresh index of the dereplicated MAGs** (its own `coverm_map_short`/`coverm_map_long` rules), not a reuse of Stage 3's per-sample-contig mapping BAMs.
- There is no standalone non-hybrid `metaspades` rule in MAGMA-main — an earlier pass mistakenly added one to the manifest based on a stale diff against the old Electron-prototype copy of the pipeline (which *did* have one). Removed; MAGMA-main only ever assembles via megahit (short) / flye (long) / metaspades_hybrid (hybrid). If this needs re-deriving, read `02_assembly.smk` directly rather than trusting any diff against `MAGMA-ideia-de-app`.

## Chain summary (tool_id → direct prerequisite)

```
fastp, filtlong          → (raw sample sheet, no deps)
kraken2                  → fastp OR filtlong (read_type dependent)
bracken → kreport2mpa    → kraken2 → bracken
kaiju_classify → kaiju_table → fastp OR filtlong (independent of kraken2 entirely)
megahit                  → fastp
metaspades_hybrid        → fastp AND filtlong
flye                     → filtlong
tiara, metaquast         → any assembler (megahit/flye/metaspades_hybrid)
bowtie2 (index+map)      → tiara AND fastp
minimap2 (map)           → tiara AND filtlong
jgi_summarize            → (bowtie2 OR minimap2) AND samtools_index
samtools_index           → bowtie2 OR minimap2
metabat2, maxbin2        → tiara AND jgi_summarize
semibin2, vamb           → tiara AND (bowtie2 OR minimap2) AND samtools_index
binette                  → at least 2 of {metabat2, semibin2, vamb, maxbin2}  (fixed, was hard-4)
checkm2, gunc            → binette
drep                     → checkm2 AND binette (via pool_hq_mags/mags_annot filter)
gtdbtk                   → drep  (NOT binette/checkm2 directly)
prodigal/abricate/minced/isescan/antismash/vfdb (sample) → tiara
prodigal/abricate/minced/isescan/antismash/vfdb (mags)   → drep
eggnog                   → prodigal (sample or mags, matching track)
amrfinder(plus)          → tiara AND prodigal (sample) / drep AND prodigal (mags)
bigscape                 → antismash (sample or mags, matching track)
virsorter2, genomad, vibrant, mobsuite (sample only) → any assembler / tiara
checkv                   → virsorter2
barrnap, trnascan (mags only) → drep
coverm                   → drep AND (fastp OR filtlong, per-sample mapping)
```

Full agent research transcript with exact line-by-line citations is not preserved anywhere outside that one conversation — if this ever needs re-verifying, re-read the 8 rule files fresh rather than trusting a stale summary.
