"""
Generic reference-database engine. Replaces the old MAGMA-only database_manager.py:
reads a pipeline's `databases` field from its manifest instead of a hardcoded
Python dict. Download/detect logic itself is unchanged from the prototype.

Settings (resolved local paths) are global/shared across pipelines -- see
settings_store.py for why.
"""
import os
import glob
import hashlib
import time

from pipelines import get_pipeline, list_pipelines
from settings_store import load_settings, save_settings

__all__ = ["load_settings", "save_settings", "get_databases_status", "get_all_databases_status",
           "detect_databases", "detect_all_databases", "validate_database", "get_download_option",
           "get_or_compute_checksum", "record_download_choice", "get_download_choice",
           "clear_download_choice"]


def _databases(pipeline_id: str) -> dict:
    return get_pipeline(pipeline_id).get("databases", {})


def get_all_databases_status() -> list:
    """Hub-level view across every pipeline: databases are stored keyed by
    setting_key in the global settings file regardless of which pipeline
    declared them (see module docstring), so a database two pipelines both
    reference (e.g. CheckM2, GTDB-Tk) is one shared entry here, configured
    once for both. Each entry carries (source_pipeline_id, source_key) -- *some* pipeline that declares it -- so the frontend can route
    set/download requests through the existing per-pipeline endpoints
    without duplicating that logic for a pipeline-agnostic route.
    """
    settings = load_settings()
    by_setting_key: dict = {}
    for summary in list_pipelines():
        pid = summary["id"]
        for key, db in _databases(pid).items():
            setting_key = db["setting_key"]
            entry = by_setting_key.get(setting_key)
            if entry is None:
                saved_path = settings.get(setting_key)
                entry = {
                    **db,
                    "path": saved_path,
                    "configured": bool(saved_path and os.path.exists(saved_path)),
                    "source_pipeline_id": pid,
                    "source_key": key,
                    "used_by": [],
                }
                by_setting_key[setting_key] = entry
            entry["used_by"].append(pid)
    return sorted(by_setting_key.values(), key=lambda e: e["name"].lower())


def get_databases_status(pipeline_id: str) -> dict:
    settings = load_settings()
    result = {}
    for key, db in _databases(pipeline_id).items():
        saved_path = settings.get(db["setting_key"])
        result[key] = {
            **db,
            "path": saved_path,
            "configured": bool(saved_path and os.path.exists(saved_path)),
        }
    return result


def detect_databases(pipeline_id: str, base_dir: str) -> dict:
    """Scans base_dir and its immediate subdirectories for known database fingerprints."""
    results = {}
    if not os.path.isdir(base_dir):
        return results
    for key, db in _databases(pipeline_id).items():
        detect_files = db.get("detect_files", [])
        detect_dirs = db.get("detect_dirs", [])
        if _match_in(base_dir, detect_files, detect_dirs):
            results[key] = base_dir
            continue
        try:
            subdirs = [os.path.join(base_dir, e) for e in os.listdir(base_dir)
                       if os.path.isdir(os.path.join(base_dir, e))]
        except PermissionError:
            continue
        for sub in subdirs:
            if _match_in(sub, detect_files, detect_dirs):
                results[key] = sub
                break
    return results


def detect_all_databases(base_dir: str) -> dict:
    """Hub-level version of detect_databases: scans once, matches against
    every pipeline's fingerprints, and returns one result per unique
    setting_key (first pipeline to match wins) so the frontend can route the
    follow-up 'set' call through that (pipeline_id, key) pair."""
    results = {}
    seen_setting_keys = set
    for summary in list_pipelines():
        pid = summary["id"]
        found = detect_databases(pid, base_dir)
        for key, path in found.items():
            setting_key = _databases(pid)[key]["setting_key"]
            if setting_key in seen_setting_keys:
                continue
            seen_setting_keys.add(setting_key)
            results[setting_key] = {"pipeline_id": pid, "key": key, "path": path}
    return results


def validate_database(pipeline_id: str, db_key: str, path: str) -> dict:
    """Checks a manually-picked folder against one specific database's
    fingerprint. Used when the user already has a database on disk and points
    the app straight at it instead of downloading -- distinct from
    detect_databases, which sweeps every key in a base_dir's immediate
    subdirectories and is meant for the general "scan this folder" flow.
    Here the user has already named the exact tool, so a fingerprint match at
    `path` itself or one level below (databases are sometimes nested inside
    an extra wrapper directory) is accepted."""
    db = _databases(pipeline_id).get(db_key)
    if db is None or not path or not os.path.isdir(path):
        return {"valid": False, "path": None}
    detect_files = db.get("detect_files", [])
    detect_dirs = db.get("detect_dirs", [])
    if not detect_files and not detect_dirs:
        # No fingerprint declared for this database -- any existing directory is accepted.
        return {"valid": True, "path": path}
    if _match_in(path, detect_files, detect_dirs):
        return {"valid": True, "path": path}
    try:
        entries = [os.path.join(path, e) for e in os.listdir(path)]
    except PermissionError:
        entries = []
    for sub in entries:
        if os.path.isdir(sub) and _match_in(sub, detect_files, detect_dirs):
            return {"valid": True, "path": sub}
    return {"valid": False, "path": None}


def _match_in(directory: str, detect_files: list, detect_dirs: list) -> bool:
    for p in detect_files:
        if glob.glob(os.path.join(directory, p)):
            return True
    for p in detect_dirs:
        for e in glob.glob(os.path.join(directory, p)):
            if os.path.isdir(e):
                return True
    return False


def get_download_option(pipeline_id: str, db_key: str, option_id: str) -> dict | None:
    for opt in _databases(pipeline_id).get(db_key, {}).get("download_options", []):
        if opt["id"] == option_id:
            return opt
    return None


# Two different users can pick two different download_options for the same
# database (e.g. Kraken2's PlusPF-16 vs Standard-8), and each option can be a
# genuinely different citable resource (e.g. GUNC's proGenomes vs GTDB
# variants) -- the run report needs to know exactly which one is configured
# to cite it correctly, not just guess. Keyed by setting_key (paths are
# global/shared across pipelines -- see module docstring), same as the paths
# themselves.
def record_download_choice(setting_key: str, option_id: str):
    settings = load_settings()
    choices = settings.get("db_download_choices", {})
    choices[setting_key] = option_id
    save_settings({"db_download_choices": choices})


def get_download_choice(setting_key: str) -> str | None:
    return load_settings().get("db_download_choices", {}).get(setting_key)


def clear_download_choice(setting_key: str):
    """Called whenever a path is assigned some other way than a tracked
    download (manually picked, or auto-detected) -- any previously recorded
    option_id no longer describes what's actually at that path, so a stale
    one would misattribute the report's citation."""
    settings = load_settings()
    choices = settings.get("db_download_choices", {})
    if setting_key in choices:
        del choices[setting_key]
        save_settings({"db_download_choices": choices})


def _hash_file(path: str, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _hash_dir_manifest(path: str) -> str:
    """Reference databases here run tens to hundreds of GB across thousands of
    files -- hashing actual file *contents* for a whole directory isn't
    practical for a report generated at the end of every run. Hashing a sorted
    (relative path, size) manifest instead is fast (pure stat calls) and
    still changes if anything is added, removed, or resized, which covers the
    practical "is this the same database as before" question."""
    entries = []
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for fname in sorted(files):
            fpath = os.path.join(root, fname)
            try:
                size = os.path.getsize(fpath)
            except OSError:
                continue
            entries.append(f"{os.path.relpath(fpath, path)}\t{size}")
    entries.sort()
    h = hashlib.sha256()
    h.update("\n".join(entries).encode("utf-8", errors="replace"))
    return h.hexdigest()


def compute_checksum(path: str) -> dict:
    """A real SHA-256 content hash for a single-file database, or a manifest
    hash (see _hash_dir_manifest) for a directory-shaped one."""
    if os.path.isfile(path):
        return {"algo": "sha256", "value": _hash_file(path)}
    return {"algo": "sha256-manifest", "value": _hash_dir_manifest(path)}


def get_or_compute_checksum(path: str) -> dict | None:
    """Cached by absolute path (settings key "db_checksums") -- these
    databases are large enough that recomputing on every single run report
    would be wasteful; only the first run touching a given path pays the
    cost, later ones reuse the cached fingerprint."""
    if not path or not os.path.exists(path):
        return None
    abs_path = os.path.abspath(path)
    settings = load_settings()
    cache = settings.get("db_checksums", {})
    cached = cache.get(abs_path)
    if cached:
        return cached
    result = compute_checksum(abs_path)
    result["computed_at"] = time.time()
    cache[abs_path] = result
    save_settings({"db_checksums": cache})
    return result
