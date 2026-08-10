# Pipeline Manifest Schema (`pipelines/<id>/pipeline.yaml`)

Written as pretty-printed JSON (valid YAML — JSON is a strict subset), specifically to avoid needing PyYAML for the one-off generation scripts in `scripts/`. The real backend parses it with real PyYAML at runtime, so this is just an implementation detail of how it was *generated*, not a constraint on the format.

## Top-level fields

- `id`, `name`, `description`, `category` (one of the [[Omics Category Taxonomy]] ids), `icon` (asset path), `snakefile` (relative path)
- `categories`: ordered list of tool-grouping category names (display order in the Launch screen's Tools tab)
- `sample_sheet`: `{columns, read_type_values, input_dirs: [{key, label}]}`. `backend/config_engine.py`'s `build_samples()` implements one folder-per-sample discovery convention (short_reads_dir/long_reads_dir, now also an optional reference_dir for SIGMA's [[SIGMA|reference-based scaffolding]]) — SIGMA reuses it unchanged, so it's more generic than originally assumed. A pipeline whose samples aren't discoverable that way (not one file/folder per sample) would still need its own function.
- `tools`: dict keyed by tool_id. Each tool has `name`, `description`, `category`, `read_type` (short/long/hybrid/all), `flags` (list), `requires` (list of [[Tool Dependency Groups]]), `rule_names` (list of real Snakemake rule names, for `--omit-from`).
  - **`description` on a tool and on each of its `flags[]` is `{"en": "...", "pt": "..."}`**, not a plain string — this is what actually renders in the Ferramentas tab (`app/lib/models/manifest_i18n.dart`'s `localizedManifestText()` picks `lang`, falling back to `en` if the requested language is missing, and to the raw value if `description` is still a legacy plain string). All 346 existing tool/flag descriptions across MAGMA/SIGMA/DOGMA were converted to this shape 2026-07-09 after the user reported these staying English-only when switching to PT. **When adding a new tool or flag, write both `en` and `pt`** — a plain string still works (shows unconditionally, ignoring the language toggle) but reintroduces the same bug.
- Same `{"en": ..., "pt": ...}` shape applies to `databases.*.description` and `databases.*.download_options[].description` — converted right after the tools/flags pass, same session (113 occurrences: 48 MAGMA + 46 SIGMA + 19 DOGMA), via `app/lib/models/database.dart`'s `DatabaseDef`/`DownloadOption.fromJson(..., lang)`, same `localizedManifestText()` helper.
- `databases`: dict keyed by db_key. Each has `name`, `description`, `setting_key` (key in the global `~/.omniomics.json` settings file), `config_key` (key under `config.yaml`'s `databases:` block — **can differ from db_key**, e.g. `amrfinder` → `amrfinderplus`, `vibrant` → `vibrant_files`; `gunc` has `config_key: null` because the gunc Snakemake rule never actually reads a configured path, it uses GUNC's own default DB location), `size_gb`, `detect_files`/`detect_dirs` (glob fingerprints for the "detect databases in a folder" feature), `download_options`.
- `special_overrides`: `{ram_gb_targets: [...], active_binners: [...]}` — small named escape hatches for non-declarative behavior (RAM flag injection, which binner tool_ids exist).
- `defaults`: dict keyed by tool_id → default CLI params string (or, for the one pseudo-tool `mags_annot`, a nested dict of threshold values, not a CLI string).

## Tool Dependency Groups (`requires`)

```json
"requires": [{"tools": ["fastp"], "min": 1}]
```
A tool's `requires` is a list of groups; **all** groups must be satisfied. Within a group, **at least `min`** of `tools` must be active. `min: 1` over a single tool = plain hard dependency; `min: 1` over several = an OR group (e.g. tiara needs *some* assembler); `min: N>1` = a real threshold (e.g. binette needs ≥2 binners).

This powers two independent things:
1. **Client-side preview** (`app/lib/logic/tool_dependency_graph.dart`, class `DependencyGraph`): instant UI feedback — turning a tool off cascades off its dependents (`settle()`), turning one on is blocked with a "Requer: X" message if unmet (`canEnable()`/`missingRequirementLabel()`). This is a *preview only*.
2. **Actual run correctness**: comes from Snakemake's own DAG via `--omit-from <rule1> <rule2> ...`, computed from `rule_names` of every currently-inactive tool (`DependencyGraph.omitFromRuleNames()`), passed through `MonitorScreen` → `/ws/pipelines/{pid}/run`'s `omit_from` field → appended to the real `snakemake` command in `backend/main.py`. **This is why (1) doesn't need to be perfectly accurate** — even if the client-side preview has a gap, the actual Snakemake run is still correct because `--omit-from` cascades through the *real* dependency graph, not this approximation.

See [[MAGMA Dependency Graph]] for the actual graph as derived from reading every `.smk` rule file (not guessed).
