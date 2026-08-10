# SIGMA Dependency Graph (ground truth, from reading the .smk rules directly)

Derived the same way as [[MAGMA Dependency Graph]]: reading every rule's `input:` section in `pipelines/sigma/workflow/rules/*.smk`, not trusting whatever the manifest already claimed.

## The bug this file exists to prevent recurring

Unlike MAGMA — where *every* analysis tool chains back to an assembler via `tiara` — SIGMA has no equivalent single choke point. When most of SIGMA's downstream tools were added, their `requires` in `pipeline.yaml` were left empty (`[]`) instead of pointing back at the assembler. Confirmed by reading `05_quality.smk`, `06_taxonomy.smk`, `08_annotation.smk`, `09_typing.smk`, `11_secondary_metabolites.smk`, and `04_mapping.smk` directly: **every one of them consumes `results/03_POLISH/{sample}/final_polished.fa`**, which only exists if an assembler ran.

Practical effect before the fix: turning off Unicycler/Flye left QUAST, CheckM2, GUNC, GTDB-Tk, Bakta, ABRicate, VFDB, ISEScan, MOB-suite, MLST, antiSMASH, RagTag, Bowtie2, and minimap2 all still showing as active in the UI. A real run would have gotten partway through and died with Snakemake's `MissingInputException` on whichever of those rules the DAG reached first. Fixed by adding `{"tools": ["unicycler","flye"], "min": 1}` to all 14 tools' `requires`. Verified two ways: (1) reimplementing the client's `settle()` cascade in a throwaway Python script against the fixed manifest — with both assemblers off, only `fastp`/`filtlong` survive; (2) a real `snakemake -n` dry-run with the correctly-cascaded active set, confirming the DAG resolves to just QC jobs with no missing-input errors.

If new SIGMA tools get added later, **don't assume `requires: []` is correct by default** — check what the rule's `input:` actually reads first.

## Chain summary (tool_id → direct prerequisite, post-fix)

```
fastp, filtlong                → (raw sample sheet, no deps)
kraken2                        → fastp OR filtlong  (contamination screening;
                                  the one category NOT downstream of assembly)
kaiju_classify → kaiju_table   → fastp OR filtlong  (independent of kraken2 too)
unicycler                      → fastp AND filtlong
flye                           → filtlong
racon → medaka                 → flye (long-only polish chain; short/hybrid use
                                  Unicycler's own self-polished output directly)
ragtag                         → unicycler OR flye  (scaffolds whatever the
                                  polished output is, against an optional
                                  per-sample reference_dir)
bowtie2 (index+map)            → fastp AND (unicycler OR flye)
minimap2 (map)                 → filtlong AND (unicycler OR flye)
samtools_index                 → bowtie2 OR minimap2
coverm                         → bowtie2 OR minimap2
quast, checkm2, gunc           → unicycler OR flye
gtdbtk                         → unicycler OR flye
bakta                          → unicycler OR flye
eggnog, amrfinderplus          → bakta   (transitively: unicycler OR flye)
abricate, vfdb                 → unicycler OR flye
isescan, mobsuite               → unicycler OR flye
mlst                           → unicycler OR flye
genomad, virsorter2, vibrant   → unicycler OR flye
checkv                         → virsorter2   (transitively: unicycler OR flye)
antismash                      → unicycler OR flye
bigscape                       → antismash   (transitively: unicycler OR flye)
```

All 29 tools now trace back to an assembler, either directly or through one hop (bakta→eggnog/amrfinderplus, virsorter2→checkv, antismash→bigscape, bowtie2/minimap2→samtools_index/coverm). If this ever needs re-verifying, re-read the rule files fresh rather than trusting this table — same caveat as the MAGMA graph.
