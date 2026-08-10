"""
Persistent history of Plots-tab analysis runs, kept separate from
runs_store.RunRecord -- a pipeline run's schema (pipeline_id/config_path/cores)
doesn't fit a plot run, which instead reads an existing pipeline run's
output_dir (parent_run_id) and produces its own analysis output under it (see
main.py's plots routes for the output path convention). Stored in the same
flat settings file as everything else (see settings_store.py), under the
"plot_runs" key -- lives in the Plots tab's own history, not the Results tab's
run list.
"""
import time
import uuid

from settings_store import load_settings, save_settings

_MAX_PLOT_RUNS = 200


def add_plot_run(name: str, parent_run_id: str, analysis_id: str) -> dict:
    run = {
        "id": uuid.uuid4.hex[:12],
        "name": name,
        "parent_run_id": parent_run_id,
        "analysis_id": analysis_id,
        "started_at": time.time(),
        "finished_at": None,
        "status": "running",  # running | done | error | stopped
    }
    settings = load_settings()
    runs = settings.get("plot_runs", [])
    runs.insert(0, run)
    save_settings({"plot_runs": runs[:_MAX_PLOT_RUNS]})
    return run


def update_plot_run(run_id: str, **fields):
    settings = load_settings()
    runs = settings.get("plot_runs", [])
    for r in runs:
        if r["id"] == run_id:
            r.update(fields)
            break
    save_settings({"plot_runs": runs})


def list_plot_runs(parent_run_id: str | None = None) -> list:
    runs = load_settings().get("plot_runs", [])
    if parent_run_id is None:
        return runs
    return [r for r in runs if r["parent_run_id"] == parent_run_id]


def get_plot_run(run_id: str) -> dict | None:
    for r in load_settings().get("plot_runs", []):
        if r["id"] == run_id:
            return r
    return None


def remove_plot_runs(run_ids) -> None:
    run_ids = set(run_ids)
    settings = load_settings()
    runs = [r for r in settings.get("plot_runs", []) if r["id"] not in run_ids]
    save_settings({"plot_runs": runs})
