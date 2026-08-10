"""
Persistent run history (across pipelines), backing the Results page's "list of
runs" panel -- similar in spirit to EPI2ME's run list. Stored in the same flat
settings file as everything else (see settings_store.py), under the "runs" key.
"""
import random
import time
import uuid

from settings_store import load_settings, save_settings

_MAX_RUNS = 200

# Docker/W&B-style adjective-noun-number names: distinct enough at a glance in
# a run list without asking the user to type anything up front. The record's
# own "id" (uuid) is always the real identity used internally (deletion,
# lookups,...) -- "name" is a human label only, renameable via
# /api/runs/{id}/rename, never used to match/select runs in backend logic.
_ADJECTIVES = [
    "amber", "bold", "brisk", "cedar", "coral", "dusty", "ember", "faint",
    "gentle", "golden", "hollow", "keen", "lively", "misty", "muted", "quiet",
    "rapid", "rosy", "silent", "solar", "steady", "swift", "tidal", "vivid",
]
_NOUNS = [
    "basin", "birch", "brook", "cove", "delta", "falcon", "fern", "glacier",
    "grove", "harbor", "heron", "lagoon", "meadow", "orbit", "otter", "quartz",
    "reef", "ridge", "summit", "tundra", "valley", "willow",
]


def generate_run_name() -> str:
    return f"{random.choice(_ADJECTIVES)}-{random.choice(_NOUNS)}-{random.randint(100, 999)}"


def add_run(pipeline_id: str, pipeline_name: str, output_dir: str, config_path: str, cores: int) -> dict:
    run = {
        "id": uuid.uuid4().hex[:12],
        "name": generate_run_name(),
        "pipeline_id": pipeline_id,
        "pipeline_name": pipeline_name,
        "output_dir": output_dir,
        "config_path": config_path,
        "cores": cores,
        "started_at": time.time(),
        "finished_at": None,
        "status": "running",  # running | done | error | stopped
        "exit_code": None,
    }
    settings = load_settings()
    runs = settings.get("runs", [])
    runs.insert(0, run)
    save_settings({"runs": runs[:_MAX_RUNS]})
    return run


def update_run(run_id: str, **fields):
    settings = load_settings()
    runs = settings.get("runs", [])
    for r in runs:
        if r["id"] == run_id:
            r.update(fields)
            break
    save_settings({"runs": runs})


def list_runs() -> list:
    return load_settings().get("runs", [])


def remove_runs(run_ids) -> None:
    """Drops the given ids from history -- used by /api/runs/delete after the
    matching output folder(s) were actually removed from disk (or found
    already gone). Does not touch anything on disk itself."""
    run_ids = set(run_ids)
    settings = load_settings()
    runs = [r for r in settings.get("runs", []) if r["id"] not in run_ids]
    save_settings({"runs": runs})
