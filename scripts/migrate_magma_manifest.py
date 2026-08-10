"""
One-off migration script: converts the hardcoded MAGMA-specific Python modules
(tool_definitions.py, database_manager.py, config_generator.py from the
MAGMA-ideia-de-app prototype) into a single declarative pipelines/magma/pipeline.yaml
manifest, so the generalized backend can serve MAGMA as "just another pipeline"
in the registry.

Written as valid JSON (a strict subset of YAML) to avoid a PyYAML dependency
for this generation step -- any YAML parser (including PyYAML) loads it correctly.

Run once: python3 scripts/migrate_magma_manifest.py
"""
import sys
import os
import json
import copy

PROTOTYPE_BACKEND = "/home/angelo/Downloads/MAGMA-ideia-de-app/backend"
OUT_PATH = os.path.join(os.path.dirname(__file__), "..", "pipelines", "magma", "pipeline.yaml")

sys.path.insert(0, PROTOTYPE_BACKEND)

# config_generator.py does `import yaml` at module level but we only need its
# DEFAULT_PARAMS dict (no yaml.* calls happen at import time) -- stub it out
# rather than requiring PyYAML just for this one-off migration script.
import types  # noqa: E402
sys.modules.setdefault("yaml", types.ModuleType("yaml"))

import tool_definitions as td   # noqa: E402
import database_manager as dm   # noqa: E402
import config_generator as cg   # noqa: E402

# setting_key (settings-file key, e.g. "db_kraken2") -> config.yaml "databases.<key>" name.
# Extracted 1:1 from config_generator.py's generate_config; two aliases exist
# today (amrfinder->amrfinderplus, vibrant->vibrant_files). "gunc" is downloadable
# via the DB manager but was never wired into config.yaml -- the gunc rule
# (workflow/rules/05_mag_refine.smk) never reads config["databases"]["gunc"],
# it relies on GUNC's own default DB location. Preserved as-is (config_key omitted).
SETTING_KEY_TO_CONFIG_KEY = {
    "db_kraken2":    "kraken2",
    "db_checkm2":    "checkm2",
    "db_gtdbtk":     "gtdbtk",
    "db_eggnog":     "eggnog",
    "db_amrfinder":  "amrfinderplus",
    "db_checkv":     "checkv",
    "db_virsorter2": "virsorter2",
    "db_genomad":    "genomad",
    "db_pfam":       "pfam",
    "db_antismash":  "antismash",
    "db_vibrant":    "vibrant_files",
}

databases = {}
for key, db in dm.DATABASES.items:
    entry = copy.deepcopy(db)
    entry["config_key"] = SETTING_KEY_TO_CONFIG_KEY.get(db["setting_key"])  # None for gunc
    databases[key] = entry

tools = copy.deepcopy(td.TOOL_DEFINITIONS)
defaults = dict(cg.DEFAULT_PARAMS)

# NOTE: an earlier version of this script added a plain, non-hybrid
# "metaspades" assembler entry here, reasoning that MAGMA-main's
# 02_assembly.smk had such a rule. That was based on a stale diff against the
# MAGMA-ideia-de-app prototype, which *did* have an extra `rule metaspades:`
# that MAGMA-main never had. MAGMA-main only ever assembles via
# megahit (short) / flye (long) / metaspades_hybrid (hybrid) -- confirmed by
# reading 02_assembly.smk directly, which has no standalone metaspades rule.
# Do not re-add a "metaspades" tool_id here.

manifest = {
    "id": "magma",
    "name": "MAGMA",
    "description": "Metagenome-assisted MAG analysis (metagenômica shotgun)",
    "category": "metagenomics",
    "icon": "assets/pipeline_icons/magma.png",
    "snakefile": "Snakefile",
    "categories": td.CATEGORIES,
    "sample_sheet": {
        "columns": ["sample", "read_type", "fq1", "fq2", "fq_long", "assembler"],
        "read_type_values": ["short", "long", "hybrid"],
        "input_dirs": [
            {"key": "short_reads_dir", "label": "Pasta de reads curtas"},
            {"key": "long_reads_dir", "label": "Pasta de reads longas"},
        ],
    },
    "tools": tools,
    "databases": databases,
    "special_overrides": {
        "ram_gb_targets": ["megahit", "metaspades_hybrid"],
        "active_binners": ["metabat2", "semibin2", "vamb", "maxbin2"],
    },
    "defaults": defaults,
}

os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
with open(OUT_PATH, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False, sort_keys=False)
    f.write("\n")

print(f"wrote {os.path.abspath(OUT_PATH)}")
print(f"tools: {len(manifest['tools'])}  databases: {len(manifest['databases'])}")
