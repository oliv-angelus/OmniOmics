"""
One-off patch: adds `requires` (dependency groups, for the Launch screen's
cascade preview) and `rule_names` (actual Snakemake rule name(s), for
`--omit-from` when a tool is toggled off) to every tool in
pipelines/magma/pipeline.yaml.

Derived from a full read of every rule's `input:` section in
workflow/rules/*.smk (see conversation for the line-by-line trace), not
guessed. Two things this is NOT trying to perfectly model, by design:
  - `requires` only needs to be a good-enough preview -- actual run
    correctness comes from Snakemake's own DAG via `--omit-from`, which
    cascades correctly regardless of any gaps here.
  - Tools split into `_sample`/`_mags` Snakemake rules (e.g. abricate) share
    ONE GUI toggle; `rule_names` lists both so disabling the toggle omits
    both instances. Mags-level cascade when e.g. drep is disabled is handled
    automatically by Snakemake's DAG, not by this data.
"""
import json
import os

PIPELINE_YAML = os.path.join(os.path.dirname(__file__), "..", "pipelines", "magma", "pipeline.yaml")

ASSEMBLERS = ["megahit", "flye", "metaspades_hybrid"]
MAPPERS = ["bowtie2", "minimap2"]

# tool_id -> (requires groups, rule_names)
# No standalone "metaspades" entry: MAGMA-main's 02_assembly.smk only ever
# assembles via megahit (short) / flye (long) / metaspades_hybrid (hybrid) --
# a plain non-hybrid metaspades rule was mistakenly ported from a stale
# prototype diff in an earlier pass and has since been removed.
PATCH = {
    "fastp":              ([], ["fastp"]),
    "filtlong":           ([], ["filtlong"]),
    "kraken2":            ([{"tools": ["fastp", "filtlong"], "min": 1}], ["kraken2"]),
    "bracken":            ([{"tools": ["kraken2"], "min": 1}], ["bracken"]),
    "kreport2mpa":        ([{"tools": ["bracken"], "min": 1}], ["kreport2mpa"]),
    "megahit":            ([{"tools": ["fastp"], "min": 1}], ["megahit"]),
    "metaspades_hybrid":  ([{"tools": ["fastp"], "min": 1}, {"tools": ["filtlong"], "min": 1}], ["metaspades_hybrid"]),
    "flye":               ([{"tools": ["filtlong"], "min": 1}], ["flye"]),
    "metaquast":          ([{"tools": ASSEMBLERS, "min": 1}], ["metaquast", "metaquast_prokaryotic"]),
    "tiara":              ([{"tools": ASSEMBLERS, "min": 1}], ["tiara", "filter_prokaryotes"]),
    "bowtie2":            ([{"tools": ["tiara"], "min": 1}, {"tools": ["fastp"], "min": 1}], ["bowtie2_index", "map_reads"]),
    "minimap2":           ([{"tools": ["tiara"], "min": 1}, {"tools": ["filtlong"], "min": 1}], ["map_reads"]),
    "jgi_summarize":      ([{"tools": MAPPERS, "min": 1}, {"tools": ["samtools_index"], "min": 1}], ["calculate_depth"]),
    "samtools_index":     ([{"tools": MAPPERS, "min": 1}], ["index_bam"]),
    "metabat2":           ([{"tools": ["tiara"], "min": 1}, {"tools": ["jgi_summarize"], "min": 1}], ["metabat2"]),
    "maxbin2":            ([{"tools": ["tiara"], "min": 1}, {"tools": ["jgi_summarize"], "min": 1}], ["maxbin2"]),
    "semibin2":           ([{"tools": ["tiara"], "min": 1}, {"tools": MAPPERS, "min": 1}, {"tools": ["samtools_index"], "min": 1}], ["semibin2"]),
    "vamb":               ([{"tools": ["tiara"], "min": 1}, {"tools": MAPPERS, "min": 1}, {"tools": ["samtools_index"], "min": 1}], ["vamb"]),
    # Was previously modeled (wrongly) as "all 4" -- 05_mag_refine.smk now
    # actually enforces >=2 via config["active_binners"], so this matches reality.
    "binette":            ([{"tools": ["metabat2", "semibin2", "vamb", "maxbin2"], "min": 2}], ["binette"]),
    "checkm2":            ([{"tools": ["binette"], "min": 1}], ["checkm2"]),
    "gunc":               ([{"tools": ["binette"], "min": 1}], ["gunc"]),
    # Not a real Snakemake rule -- pure quality-threshold filter inside pool_hq_mags.
    "mags_annot":         ([{"tools": ["checkm2"], "min": 1}, {"tools": ["binette"], "min": 1}], []),
    "drep":               ([{"tools": ["checkm2"], "min": 1}, {"tools": ["binette"], "min": 1}], ["pool_hq_mags", "drep"]),
    "gtdbtk":             ([{"tools": ["drep"], "min": 1}], ["gtdbtk"]),
    "prodigal":           ([{"tools": ["tiara"], "min": 1}], ["prodigal_sample", "prodigal_mags"]),
    "eggnog":             ([{"tools": ["prodigal"], "min": 1}], ["eggnog_sample", "eggnog_mags"]),
    "abricate":           ([{"tools": ["tiara"], "min": 1}], ["abricate_sample", "abricate_mags"]),
    "amrfinderplus":      ([{"tools": ["tiara"], "min": 1}, {"tools": ["prodigal"], "min": 1}], ["amrfinder_sample", "amrfinder_mags"]),
    "checkv":             ([{"tools": ["virsorter2"], "min": 1}], ["checkv_sample"]),
    "virsorter2":         ([{"tools": ASSEMBLERS, "min": 1}], ["virsorter2_sample"]),
    "genomad":            ([{"tools": ASSEMBLERS, "min": 1}], ["genomad_sample"]),
    "isescan":            ([{"tools": ["tiara"], "min": 1}], ["isescan_sample", "isescan_mags"]),
    "minced":             ([{"tools": ["tiara"], "min": 1}], ["minced_sample", "minced_mags"]),
    "antismash":          ([{"tools": ["tiara"], "min": 1}], ["antismash_sample", "antismash_mags"]),
    "bigscape":           ([{"tools": ["antismash"], "min": 1}], ["bigscape_sample", "bigscape_mags"]),
    "vibrant":            ([{"tools": ASSEMBLERS, "min": 1}], ["vibrant_sample"]),
    "mobsuite":           ([{"tools": ["tiara"], "min": 1}], ["mobsuite_sample"]),
    "vfdb":               ([{"tools": ["tiara"], "min": 1}], ["vfdb_sample", "vfdb_mags"]),
    "barrnap":            ([{"tools": ["drep"], "min": 1}], ["barrnap_mags"]),
    "trnascan":           ([{"tools": ["drep"], "min": 1}], ["trnascan_mags"]),
    "coverm":             ([{"tools": ["drep"], "min": 1}, {"tools": MAPPERS, "min": 1}],
                           ["coverm_index", "coverm_map_short", "coverm_map_long", "coverm"]),
}

with open(PIPELINE_YAML, encoding="utf-8") as f:
    manifest = json.load(f)

# coverm never made it into the original TOOL_DEFINITIONS dict despite being a
# real rule (08_coverage.smk) with a `config["params"]["coverm"]` key already
# referenced by the example config.yaml -- same class of gap as the missing
# `metaspades` entry fixed earlier during manifest migration.
if "coverm" not in manifest["tools"]:
    manifest["tools"]["coverm"] = {
        "name": "CoverM",
        "description": "Calculates MAG relative abundance/coverage across samples",
        "category": "Bin Quality & Dereplication",
        "read_type": "all",
        "flags": [
            {"flag": "-m", "type": "choice", "default": "relative_abundance", "enabled": True,
             "description": "Metric(s) to calculate",
             "choices": ["relative_abundance", "mean", "trimmed_mean", "covered_fraction", "variance", "length", "count", "metabat", "coverage_histogram", "rpkm", "tpm"]},
            {"flag": "--min-covered-fraction", "type": "float", "default": 0, "enabled": True,
             "description": "Minimum fraction of a genome covered to report abundance (0 = no filter)", "min": 0.0, "max": 100.0},
            {"flag": "--min-read-percent-identity", "type": "float", "default": 0.0, "enabled": False,
             "description": "Minimum alignment percent identity for a read to be counted", "min": 0.0, "max": 100.0},
        ],
    }
    manifest.setdefault("defaults", {})["coverm"] = "-m relative_abundance --min-covered-fraction 0"

missing = set(manifest["tools"]) - set(PATCH)
extra = set(PATCH) - set(manifest["tools"])
if missing:
    raise SystemExit(f"PATCH is missing tool_ids present in manifest: {sorted(missing)}")
if extra:
    raise SystemExit(f"PATCH has tool_ids not present in manifest: {sorted(extra)}")

for tool_id, (requires, rule_names) in PATCH.items():
    manifest["tools"][tool_id]["requires"] = requires
    manifest["tools"][tool_id]["rule_names"] = rule_names
    manifest["tools"][tool_id].pop("dependencies", None)  # superseded by `requires`

with open(PIPELINE_YAML, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"Patched {len(PATCH)} tools in {PIPELINE_YAML}")
