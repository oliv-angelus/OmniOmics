"""
Generic config/samples-sheet engine. Replaces the old MAGMA-only config_generator.py:
driven by a pipeline manifest's `sample_sheet`, `defaults`, `databases` and
`special_overrides` fields instead of hardcoded MAGMA specifics.
"""
import yaml
import os
import re
import csv
import glob

from pipelines import get_pipeline
from databases_engine import get_databases_status

_SAMPLE_COLUMNS_FALLBACK = ["sample", "read_type", "fq1", "fq2", "fq_long", "assembler"]


def _find_short_reads(sample_dir: str):
    # (pattern, R1 token, R2 token): the token pair is how the mate file is
    # derived from R1's name. The first two patterns cover the standard
    # Illumina bcl2fastq output (SAMPLE_S1_L001_R1_001.fastq.gz) -- the "_001"
    # (or any lane/chunk suffix) after "_R1" means it does NOT end in "_R1."
    # and so was silently missed before, producing a sample row with an empty
    # read path that only blew up later as a cryptic Snakemake error.
    # More specific naming is tried first so "..._R1_001..." isn't mistaken
    # for the app's own "..._R1." convention.
    patterns = [
        ("*_R1_*.fastq.gz", "_R1_", "_R2_"),
        ("*_R1_*.fq.gz",    "_R1_", "_R2_"),
        ("*_R1.fastq.gz",   "_R1.", "_R2."),
        ("*_R1.fq.gz",      "_R1.", "_R2."),
        ("*_1.fastq.gz",    "_1.",  "_2."),
        ("*_1.fq.gz",       "_1.",  "_2."),
    ]
    for pattern, r1_tok, r2_tok in patterns:
        hits = sorted(glob.glob(os.path.join(sample_dir, pattern)))
        if hits:
            r1 = hits[0]  # multi-lane: first lane only (see build_samples note)
            r2 = r1.replace(r1_tok, r2_tok)
            return r1, r2 if os.path.isfile(r2) else ""
    return "", ""


def _find_long_reads(sample_dir: str):
    for pattern in ["*.fastq.gz", "*.fq.gz", "*.fastq", "*.fq"]:
        hits = glob.glob(os.path.join(sample_dir, pattern))
        if hits:
            return hits[0]
    return ""


def _find_reference(sample_dir: str):
    for pattern in ["*.fasta", "*.fa", "*.fna", "*.fasta.gz", "*.fa.gz", "*.fna.gz"]:
        hits = glob.glob(os.path.join(sample_dir, pattern))
        if hits:
            return hits[0]
    return ""


def build_samples(pipeline_id: str, data: dict) -> list:
    """
    Sample discovery shared by every pipeline shaped like MAGMA/SIGMA:
    short_reads_dir/long_reads_dir, one subfolder per sample, read_type
    inferred from which reads were found. The read_type -> assembler mapping
    comes from the manifest's sample_sheet.assembler_for_read_type (each
    pipeline names its own assembler tool_ids/rules differently -- e.g. MAGMA's
    hybrid assembler is "metaspades_hybrid" (SPAdes --meta), SIGMA's is
    "spades_isolate" (SPAdes --isolate)), falling back to MAGMA's original
    names for manifests that don't declare it.
    A pipeline with a genuinely different sample_sheet shape (not this
    short/long-folder convention) still needs its own discovery strategy here.
    """
    manifest = get_pipeline(pipeline_id)
    assembler_for_read_type = manifest.get("sample_sheet", {}).get("assembler_for_read_type") or {
        "short": "megahit", "long": "flye", "hybrid": "metaspades_hybrid",
    }

    short_dir = data.get("short_reads_dir", "")
    long_dir = data.get("long_reads_dir", "")
    # Optional: only SIGMA declares this (reference-guided scaffolding via
    # RagTag) -- a no-op for pipelines whose sample_sheet.columns doesn't
    # include "reference", since _write_tsv/_tsv_to_string only emit columns
    # the manifest actually lists.
    reference_dir = data.get("reference_dir", "")
    # Three-way: "none" (no RagTag scaffolding at all), "single" (one
    # reference fasta applied to every sample -- mass-assembly of one
    # organism across many samples), "per_sample" (reference_dir/<sample>/
    # matching by folder name -- a sample with no
    # matching folder just runs without a reference, unless the Launch
    # screen's validation step recorded a manual pick in reference_overrides).
    reference_mode = data.get("reference_mode", "none")
    reference_file = data.get("reference_file", "")
    reference_overrides = data.get("reference_overrides") or {}

    samples: dict = {}

    # Only folders that actually contain reads become samples. A subfolder
    # with no recognizable reads (wrong naming that still slipped through, or a
    # stray non-sample folder like.ipynb_checkpoints/md5sums left in the reads
    # dir) previously still emitted a row with empty read paths -- which then
    # failed mid-run as a cryptic Snakemake "missing input" far from the real
    # cause. Skipping it here surfaces the problem as "sample missing from the
    # sheet" instead, which points straight at the naming/folder.
    if short_dir and os.path.isdir(short_dir):
        for folder in sorted(os.listdir(short_dir)):
            full = os.path.join(short_dir, folder)
            if os.path.isdir(full):
                r1, r2 = _find_short_reads(full)
                if r1:
                    samples.setdefault(folder, {})["fq1"] = r1
                    samples.setdefault(folder, {})["fq2"] = r2

    if long_dir and os.path.isdir(long_dir):
        for folder in sorted(os.listdir(long_dir)):
            full = os.path.join(long_dir, folder)
            if os.path.isdir(full):
                fl = _find_long_reads(full)
                if fl:
                    samples.setdefault(folder, {})["fq_long"] = fl

    # A reference only attaches to a sample that already has reads -- it never
    # creates a sample on its own (a reference-only folder with no reads is not
    # a runnable sample).
    if reference_mode == "single" and reference_file:
        for name in samples:
            samples[name]["reference"] = reference_file
    elif reference_mode == "per_sample":
        if reference_dir and os.path.isdir(reference_dir):
            for folder in sorted(os.listdir(reference_dir)):
                full = os.path.join(reference_dir, folder)
                if os.path.isdir(full) and folder in samples:
                    ref = _find_reference(full)
                    if ref:
                        samples[folder]["reference"] = ref
        # Manual picks from the Launch screen's per-sample validation step
        # (a sample whose folder name didn't match anything under
        # reference_dir) -- takes precedence over an automatic match, though
        # in practice the two are mutually exclusive per sample.
        for name, path in reference_overrides.items():
            if name in samples and path:
                samples[name]["reference"] = path

    rows = []
    for name, paths in sorted(samples.items()):
        has_short = bool(paths.get("fq1"))
        has_long = bool(paths.get("fq_long"))

        if has_short and has_long:
            read_type = "hybrid"
        elif has_short:
            read_type = "short"
        else:
            read_type = "long"
        assembler = assembler_for_read_type.get(read_type, "")

        rows.append({
            "sample": name,
            "read_type": read_type,
            "fq1": paths.get("fq1", ""),
            "fq2": paths.get("fq2", ""),
            "fq_long": paths.get("fq_long", ""),
            "assembler": assembler,
            "reference": paths.get("reference", ""),
        })

    return rows


def generate_config(pipeline_id: str, data: dict) -> dict:
    manifest = get_pipeline(pipeline_id)
    overrides = manifest.get("special_overrides", {})

    output_dir = data.get("output_dir", "./results")
    config_dir = os.path.join(output_dir, "config")
    os.makedirs(config_dir, exist_ok=True)

    params = dict(manifest.get("defaults", {}))
    user_params = data.get("tool_flags", {})
    for key, val in user_params.items():
        if key not in params:
            continue
        if isinstance(params[key], dict):
            if isinstance(val, dict):
                params[key].update(val)
        else:
            if val != "":  # empty string means "user changed nothing" -> keep default
                params[key] = val

    if data.get("ram_gb"):
        ram = data["ram_gb"]
        for tool_id in overrides.get("ram_gb_targets", []):
            current = params.get(tool_id, "")
            if not isinstance(current, str):
                continue
            # Strip any pre-existing "-m <value>" (the tool's own default, or
            # whatever the user set in the Tools tab) before appending the
            # fresh one -- overwriting the whole string previously discarded
            # any *other* flags the user had customized for this tool (e.g.
            # SIGMA's spades_isolate --isolate flag, or SPAdes' --careful).
            cleaned = re.sub(r"(?:^|\s)-m\s+\S+", "", current).strip()
            if tool_id == "megahit":
                # MEGAHIT's -m/--memory takes a plain float: 0-1 means "fraction
                # of total system RAM", >1 means "absolute byte count" -- it has
                # no unit-suffix syntax, so a GB value must convert to raw bytes
                # rather than being passed through with a "g" suffix appended.
                mem_flag = f"-m {int(ram * 1024 ** 3)}"
            else:
                # SPAdes' -m/--memory is already a plain integer number of GB
                # (it terminates the run if exceeded) -- no fraction/byte
                # conversion needed, unlike MEGAHIT.
                mem_flag = f"-m {ram}"
            params[tool_id] = f"{cleaned} {mem_flag}".strip()

    active_tools = data.get("active_tools", [])
    all_binners = overrides.get("active_binners", [])
    active_binners = [b for b in all_binners if b in active_tools]

    # Per-tool thread overrides (Resources tab): one thread count per tool_id,
    # applied to every Snakemake rule that tool owns. Falls back to the
    # manifest's default_threads for any tool the user didn't override.
    threads = dict(manifest.get("default_threads", {}))
    user_threads = data.get("thread_overrides", {})
    for tool_id, val in user_threads.items():
        if tool_id not in threads:
            continue
        try:
            n = int(val)
        except (TypeError, ValueError):
            continue
        if n > 0:
            threads[tool_id] = n

    # Long-read platform (Nanopore raw/HQ, PacBio raw/HiFi): one run-wide
    # choice. Flye, SPAdes and minimap2 each need a *different flag/preset
    # name* per platform (--nano-hq vs --pacbio-raw; --nanopore vs --pacbio;
    # map-ont vs map-pb vs map-hifi), not just a value, so the manifest
    # declares the mapping and the Snakemake rules read
    # config["long_read_platform"][...] instead of hardcoding one option.
    platform_options = manifest.get("long_read_platforms", [])
    platform_id = data.get("long_read_platform") or manifest.get("default_long_read_platform", "")
    platform = next((p for p in platform_options if p.get("id") == platform_id), None) \
        or (platform_options[0] if platform_options else None)
    long_read_platform = {
        "id": platform.get("id", ""),
        "flye_flag": platform.get("flye_flag", ""),
        "spades_flag": platform.get("spades_flag", ""),
        "minimap2_preset": platform.get("minimap2_preset", "map-ont"),
    } if platform else {"id": "", "flye_flag": "", "spades_flag": "", "minimap2_preset": "map-ont"}

    # Amplicon preset (PRISM): one run-wide choice that carries the marker
    # gene, its reference database, its primer sequences AND its expected
    # amplicon length window together. Exists because those four were
    # previously encoded in three independent places (cutadapt's primer
    # flags, filtlong's length window, and the engines' own --gene) that
    # could silently disagree -- switching --gene alone left 16S primers and
    # a 16S length window in place, so cutadapt's --discard-untrimmed threw
    # away nearly every read and filtlong filtered out the rest, with no
    # error. Same shape/mechanism as long_read_platform above, and like it
    # the rules read config["amplicon_preset"][...] rather than hardcoding.
    # A preset's values are DEFAULTS: a non-empty cutadapt/filtlong flag
    # string set on the Tools tab still wins (see 01_qc/02_primer_trim), so
    # custom primers remain possible -- which is why one preset ("custom")
    # deliberately carries no values at all.
    preset_options = manifest.get("amplicon_presets", [])
    preset_id = data.get("amplicon_preset") or manifest.get("default_amplicon_preset", "")
    preset = next((p for p in preset_options if p.get("id") == preset_id), None) \
        or (preset_options[0] if preset_options else None)
    amplicon_preset = {
        "id": preset.get("id", ""),
        "gene": preset.get("gene", ""),
        "reference_db": preset.get("reference_db", ""),
        "fwd_primers": preset.get("fwd_primers", []),
        "rev_primers": preset.get("rev_primers", []),
        "min_length": preset.get("min_length", 0),
        "max_length": preset.get("max_length", 0),
    } if preset else {"id": "", "gene": "", "reference_db": "", "fwd_primers": [],
                      "rev_primers": [], "min_length": 0, "max_length": 0}

    # Primers typed into the Inputs tab's own fields override whatever the
    # preset carries. Those fields exist because several presets ("18S --
    # supply your primers", "Custom") deliberately carry NO sequence, so
    # without them the UI told the user to supply primers with nowhere to do
    # it; they also let a user swap the primers of a preset that does carry
    # them (different primer sets amplify the same region). Comma-separated
    # so a real primer MIX works -- ONT's own SQK-MAB114.24 kit pools a
    # universal pair with taxon-specific ones.
    def _split_primers(raw):
        return [p.strip().upper() for p in str(raw or "").replace(";", ",").split(",") if p.strip()]

    for field, key in (("amplicon_fwd_primers", "fwd_primers"),
                       ("amplicon_rev_primers", "rev_primers")):
        if field in data:
            typed = _split_primers(data.get(field))
            # An empty box means "fall back to the preset", not "no primers" --
            # otherwise merely opening the tab and saving would silently strip
            # a preset's own sequences.
            if typed:
                amplicon_preset[key] = typed

    # Inject stored database paths: caller only needs to send overrides, not
    # every path it already told us about via /api/databases/set.
    db_status = get_databases_status(pipeline_id)
    databases_block = {}
    for key, info in db_status.items():
        config_key = info.get("config_key")
        if not config_key:
            continue  # a database with no config_key: downloadable/detectable via the
            # Databases tab, but no Snakemake rule reads its path from config.yaml
            # (gunc used to be the only example of this, until its own `gunc run`
            # rule started taking -d explicitly -- see 05_mag_refine.smk)
        setting_key = info["setting_key"]
        databases_block[config_key] = data.get(setting_key) or info.get("path") or ""

    # Non-database sample_sheet inputs that still need to land in config.yaml
    # (unlike the persistent, global databases above, these are per-run
    # values picked on the Launch screen's Inputs tab):
    # - "toggle" (DOGMA's paired MAGMA run): explicitly on/off -- "off"
    # always means empty, even if the caller sent a stale path, so the
    # toggle really does mean "run without this" rather than falling back
    # to whatever was last configured.
    # - "kind": "file" (DEFINE's reference genome): a single required file,
    # no toggle -- always whatever the caller sent.
    for spec in manifest.get("sample_sheet", {}).get("input_dirs", []):
        config_key = spec.get("config_key")
        if not config_key:
            continue
        if spec.get("toggle"):
            enabled = bool(data.get(f"{spec['key']}_enabled"))
            databases_block[config_key] = data.get(spec["key"], "") if enabled else ""
        elif spec.get("kind") == "file":
            databases_block[config_key] = data.get(spec["key"], "")

    config = {
        "samples": data.get("tsv_path", "config/samples.tsv"),
        "active_tools": active_tools,
        "active_binners": active_binners,
        "databases": databases_block,
        "params": params,
        "threads": threads,
        "long_read_platform": long_read_platform,
        "amplicon_preset": amplicon_preset,
    }

    yaml_path = os.path.join(config_dir, "config.yaml")
    with open(yaml_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False, width=4096)

    with open(yaml_path) as f:
        yaml_content = f.read()

    return {"path": yaml_path, "content": yaml_content, "data": config}


def _write_tsv(rows: list, path: str, columns: list = None):
    fieldnames = columns or _SAMPLE_COLUMNS_FALLBACK
    # extrasaction="ignore" -- build_samples always includes "reference" in
    # every row regardless of pipeline (see its docstring), but only SIGMA's
    # manifest lists it as a column; DictWriter's default ("raise") would
    # otherwise error out for every other pipeline over a field it never
    # asked for and doesn't need.
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _tsv_to_string(rows: list, columns: list = None) -> str:
    cols = columns or _SAMPLE_COLUMNS_FALLBACK
    lines = ["\t".join(cols)]
    for r in rows:
        lines.append("\t".join(str(r.get(c, "")) for c in cols))
    return "\n".join(lines)
