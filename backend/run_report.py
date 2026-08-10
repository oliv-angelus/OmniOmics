"""
Builds run_report.txt at the end of every run: run metadata, an auto-drafted
Methods paragraph (grouped by tool category, meant to be pasted into a
manuscript and lightly edited -- not final polished prose), a detailed
per-tool parameters/versions table, a reference-databases section with
fingerprints for reproducibility, and a numbered REFERENCES list (DOIs) for
every tool and reference database actually used -- citing the exact database
*version/build* the user configured where that affects which paper applies
(e.g. GUNC's proGenomes vs GTDB options), not just a generic default.

Always written in English regardless of the app's UI language, since that's
what a manuscript Methods section needs almost universally.
"""
import datetime
import os
import time

import yaml

import tool_versions
from pipelines import get_pipeline
from databases_engine import get_or_compute_checksum, get_download_choice

_RULE = "-" * 80


def _fmt_time(ts: float | None) -> str:
    if not ts:
        return "-"
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def _flags_string(params_entry) -> str:
    if isinstance(params_entry, dict):
        return " ".join(f"{k}={v}" for k, v in params_entry.items())
    return (params_entry or "").strip()


def _join_natural(items: list) -> str:
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return items[0] + " and " + items[1]
    return ", ".join(items[:-1]) + ", and " + items[-1]


def generate_report(pid: str, run: dict, config_path: str) -> str:
    manifest = get_pipeline(pid)
    tools = manifest.get("tools", {})
    categories_order = manifest.get("categories", [])
    databases_manifest = manifest.get("databases", {})

    try:
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        config = {}

    active_tools = [t for t in config.get("active_tools", []) if t in tools]
    params = config.get("params", {})
    databases_block = config.get("databases", {})

    by_category: dict[str, list[str]] = {}
    for tid in active_tools:
        cat = tools[tid].get("category", "Other")
        by_category.setdefault(cat, []).append(tid)

    # ---- Methods paragraph (draft) --------------------------------------
    methods_paragraphs = []
    detail_rows = []  # (tool name, version, category, parameters)
    # Citations for every active tool that has one, deduped and in the same
    # category/tool order as detail_rows -- e.g. jgi_summarize and metabat2
    # cite the same MetaBAT2 paper, and would otherwise show up twice.
    reference_entries = [
        {"text": "Mölder F, Jablonski KP, Letcher B, et al. Sustainable data analysis with "
                  "Snakemake. F1000Research. 2021;10:33.", "doi": "10.12688/f1000research.29032.2"},
    ]
    _seen_refs = {"10.12688/f1000research.29032.2"}
    for cat in categories_order:
        tids = by_category.get(cat)
        if not tids:
            continue
        phrases = []
        for tid in tids:
            tool = tools[tid]
            env_paths = tool_versions.tool_env_files(pid, tid, tool.get("rule_names", []))
            version = tool_versions.primary_version(tid, env_paths)
            flags = _flags_string(params.get(tid))
            name = tool.get("name", tid)
            version_part = f" v{version}" if version else ""
            phrase = f"{name}{version_part}"
            if flags:
                phrase += f" ({flags})"
            phrases.append(phrase)
            detail_rows.append((name, version or "-", cat, flags or "-"))
            for citation in tool.get("citation", []):
                dedup_key = citation.get("doi") or citation.get("text")
                if dedup_key in _seen_refs:
                    continue
                _seen_refs.add(dedup_key)
                reference_entries.append(citation)
        methods_paragraphs.append(f"For {cat.lower()}, we used {_join_natural(phrases)}.")

    if not active_tools:
        methods_paragraphs.append("No tools were active for this run.")

    # ---- Reference databases ----------------------------------------------- # A database is only listed if its key plausibly belongs to one of *this
    # run's* active tools (fuzzy substring match, e.g. "amrfinder" database <->
    # "amrfinderplus" tool) -- config.yaml's databases block otherwise carries
    # every database the app knows about globally, active or not, which would
    # misreport databases the run never touched as having been used.
    active_norms = [t.lower().replace("_", "").replace("-", "") for t in active_tools]

    def _db_relevant(db_key: str) -> bool:
        norm_db = db_key.lower().replace("_", "").replace("-", "")
        return any(norm_db == t or norm_db in t or t in norm_db for t in active_norms)

    # A database can have several download_options (e.g. Kraken2's PlusPF-16
    # vs Standard-8, GUNC's proGenomes vs GTDB variants) that are genuinely
    # different citable resources -- two users running the same tool may have
    # downloaded different ones. get_download_choice recovers exactly which
    # option produced the currently-configured path (recorded at download
    # time; cleared if the path was later set/detected manually), so the
    # report cites the database actually used, not just a generic default.
    db_rows = []
    for key, info in databases_manifest.items():
        if not _db_relevant(key):
            continue
        path = databases_block.get(info.get("config_key")) if info.get("config_key") else None
        if not path:
            continue
        checksum = get_or_compute_checksum(path)
        checksum_str = f"{checksum['algo']}:{checksum['value'][:16]}…" if checksum else "not available"

        option_id = get_download_choice(info.get("setting_key", ""))
        option_label = None
        if option_id:
            for opt in info.get("download_options", []):
                if opt["id"] == option_id:
                    option_label = opt.get("label")
                    break

        version_known = option_id is not None
        citations = info.get("citation_by_option", {}).get(option_id) if option_id else None
        if citations is None:
            citations = info.get("citation", [])

        db_rows.append((info.get("name", key), path, checksum_str, option_label, version_known, citations))
        for citation in citations:
            dedup_key = citation.get("doi") or citation.get("text")
            if dedup_key in _seen_refs:
                continue
            _seen_refs.add(dedup_key)
            reference_entries.append(citation)

    # ---- Assemble ----------------------------------------------------------
    lines = []
    lines.append("=" * 80)
    lines.append("OmniOmics -- Run Report")
    lines.append("=" * 80)
    lines.append(f"Pipeline:          {manifest.get('name', pid)}")
    lines.append(f"Run name:          {run.get('name', '-')}")
    lines.append(f"Run id:            {run.get('id', '-')}")
    lines.append(f"Started:           {_fmt_time(run.get('started_at'))}")
    lines.append(f"Finished:          {_fmt_time(run.get('finished_at') or time.time())}")
    lines.append(f"Status:            {run.get('status', '-')}  (exit code {run.get('exit_code')})")
    lines.append(f"Cores:             {run.get('cores', '-')}")
    lines.append(f"Output directory:  {run.get('output_dir', '-')}")
    lines.append(f"Config file:       {config_path}")
    lines.append("")
    lines.append(_RULE)
    lines.append("METHODS (auto-drafted -- review and edit before submission)")
    lines.append(_RULE)
    lines.append(
        f"Data were processed with the {manifest.get('name', pid)} pipeline, implemented in "
        "OmniOmics and orchestrated with Snakemake (Molder et al. 2021, "
        "https://doi.org/10.12688/f1000research.29032.2)."
    )
    lines.append("")
    for p in methods_paragraphs:
        lines.append(p)
        lines.append("")

    lines.append(_RULE)
    lines.append("TOOLS & PARAMETERS")
    lines.append(_RULE)
    if detail_rows:
        # +2 columns of padding beyond whichever is wider: the data or the
        # header label itself (e.g. "Version" is 7 chars -- wider than most
        # actual version strings -- so sizing off the data alone left the
        # header's own words running into each other with no gap).
        name_w = max([len(r[0]) for r in detail_rows] + [len("Tool")]) + 2
        ver_w = max([len(r[1]) for r in detail_rows] + [len("Version")]) + 2
        cat_w = max([len(r[2]) for r in detail_rows] + [len("Category")]) + 2
        header = f"{'Tool'.ljust(name_w)}{'Version'.ljust(ver_w)}{'Category'.ljust(cat_w)}Parameters"
        lines.append(header)
        lines.append("-" * len(header))
        for name, version, cat, flags in detail_rows:
            lines.append(f"{name.ljust(name_w)}{version.ljust(ver_w)}{cat.ljust(cat_w)}{flags}")
    else:
        lines.append("(no active tools)")
    lines.append("")

    lines.append(_RULE)
    lines.append("REFERENCES")
    lines.append(_RULE)
    lines.append(
        "Cite these alongside the pipeline itself when reporting results -- one entry per "
        "tool and reference database actually used in this run (deduped where two share a "
        "paper, e.g. a helper script bundled with another tool, or a database whose citation "
        "is the same as its tool's)."
    )
    lines.append("")
    for i, ref in enumerate(reference_entries, start=1):
        doi = ref.get("doi")
        suffix = f" https://doi.org/{doi}" if doi else ""
        lines.append(f"[{i}] {ref['text']}{suffix}")
    lines.append("")

    lines.append(_RULE)
    lines.append("REFERENCE DATABASES")
    lines.append(_RULE)
    if db_rows:
        lines.append(
            "Fingerprints below are SHA-256 hashes: a real content hash for single-file "
            "databases, or a hash of the (relative path, size) manifest for directory-shaped "
            "ones (hashing the full byte content of multi-hundred-GB databases on every run "
            "isn't practical) -- either way, an unchanged fingerprint across runs confirms the "
            "same database was used."
        )
        lines.append("")
        for name, path, checksum_str, option_label, version_known, citations in db_rows:
            lines.append(f"{name}")
            lines.append(f"  path:     {path}")
            if option_label:
                lines.append(f"  version:  {option_label}")
            elif not version_known and citations:
                lines.append("  version:  not tracked (path set manually, or predates version tracking) --")
                lines.append("            citation below is this database's default; verify it matches what")
                lines.append("            was actually downloaded before citing.")
            for citation in citations:
                doi = citation.get("doi")
                suffix = f" https://doi.org/{doi}" if doi else ""
                lines.append(f"  citation: {citation['text']}{suffix}")
    else:
        lines.append("(no databases configured for the active tools)")
    lines.append("")

    lines.append(_RULE)
    lines.append(f"Generated automatically by OmniOmics on {_fmt_time(time.time())}.")
    lines.append(_RULE)

    return "\n".join(lines) + "\n"


def write_report(pid: str, run: dict, config_path: str, output_dir: str) -> str:
    text = generate_report(pid, run, config_path)
    report_path = os.path.join(output_dir, "run_report.txt")
    try:
        with open(report_path, "w") as f:
            f.write(text)
        return report_path
    except OSError:
        return ""
