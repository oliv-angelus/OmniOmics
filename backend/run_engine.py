"""
How a pipeline run is assembled: which Snakemake and conda to use, the
environment the run gets, the Snakemake arguments, and which rules to omit for
the tools the user switched off.

Shared by the GUI (main.py's pipeline_ws) and the command line (cli.py), so a
run started from either one is the same run.
"""
import os
import re
import shutil
import subprocess
import sys

import yaml

from pipelines import get_pipeline
from tools_engine import _tracks_for

# Snakemake 9's --use-conda refuses older conda; the snakemake env installs
# this exact conda alongside Snakemake so the base install's age doesn't matter.
MIN_CONDA_VERSION = (24, 7, 1)
SNAKEMAKE_ENV_CONDA = "26.7.2"

# Conda envs are content-addressed by Snakemake, so one shared prefix lets every
# run (and every pipeline) reuse an env it already built instead of rebuilding
# it under each output_dir -- DEFINE's set alone is ~5.5 GB, which would
# otherwise be paid again for every single run.
CONDA_ENVS_DIR = os.path.expanduser("~/.omniomics/conda_envs")


def conda_version(conda_exe: str | None) -> tuple | None:
    """(major, minor, patch) of `conda --version`, or None if it can't be read."""
    if not conda_exe:
        return None
    try:
        out = subprocess.run([conda_exe, "--version"], capture_output=True, text=True, timeout=30).stdout
        m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", out or "")
        return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)) if m else None
    except Exception:
        return None


def subprocess_env() -> dict:
    """Environment for every subprocess the backend spawns and lets run
    scripts of its own (Snakemake, and the Plots tab's Rscript jobs).

    The backend runs from <repo>/.venv. When the app is launched from a shell
    where that venv is *activated*, its bin/ sits first in PATH and is
    inherited all the way down into each rule's conda environment. Conda
    rewrites most installed scripts' shebangs to an absolute interpreter path,
    but not all of them -- KrakenTools ships extract_kraken_reads.py (DOGMA)
    and kreport2mpa.py (MAGMA) with a plain `#!/usr/bin/env python`, which then
    resolves to the *backend's* interpreter instead of the rule env's and dies
    with "ModuleNotFoundError: No module named 'Bio'" mid-run.

    Stripping our own venv back out lets each conda env's interpreter win.
    Nothing else needs it: the backend talks to its subprocesses over argv,
    not through inherited Python state.

    R_LIBS/R_LIBS_USER/R_LIBS_SITE/RENV_* are the same class of leak, one
    level up the stack: a system or user R installation's own library paths
    must not shadow the r-plots conda env's package versions when spawning
    Rscript for the Plots tab (see plots_engine.resolve_rscript).
    """
    env = os.environ.copy()
    roots = {p for p in (env.pop("VIRTUAL_ENV", None),
                         sys.prefix if sys.prefix != sys.base_prefix else None) if p}
    if roots:
        drop = {os.path.normpath(os.path.join(r, "bin")) for r in roots}
        env["PATH"] = os.pathsep.join(
            p for p in env.get("PATH", "").split(os.pathsep)
            if p and os.path.normpath(p) not in drop
        )
    for var in ("R_LIBS", "R_LIBS_USER", "R_LIBS_SITE"):
        env.pop(var, None)
    for key in list(env):
        if key.startswith("RENV_"):
            env.pop(key, None)
    return env


def apply_env(env: dict, overrides: dict | None) -> dict:
    """Merge overrides onto env; a None value removes the variable."""
    for key, value in (overrides or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


def resolve_snakemake(settings: dict) -> tuple[list, str | None, str | None]:
    """(command prefix, snakemake binary or None, conda bin dir to put on PATH or None).

    snakemake: system PATH first, then the conda env's binary directly.
    Deliberately NOT `conda run -n snakemake snakemake` when avoidable --
    conda run doesn't reliably forward SIGTERM to the process it wraps, which
    left a stopped run orphaned and still going. Resolving the env's own
    snakemake binary makes the subprocess the real thing.

    The conda bin dir: `--use-conda` makes Snakemake shell out to `conda` to
    build each rule's environment, which only works if `conda` is on the
    inherited PATH -- not the case when launched from a desktop entry. When
    the snakemake env carries its own recent conda (Snakemake 9 refuses conda
    older than 24.7.1), that one goes first on PATH, whatever the base
    install is.
    """
    snakemake_bin = shutil.which("snakemake")
    conda = None
    if not snakemake_bin:
        conda = settings.get("conda_path") or shutil.which("conda") or "conda"
        if conda and os.path.isfile(conda):
            candidate = os.path.join(os.path.dirname(os.path.dirname(conda)), "envs", "snakemake", "bin", "snakemake")
            if os.path.isfile(candidate):
                snakemake_bin = candidate

    if snakemake_bin:
        cmd = [snakemake_bin]
    else:
        # Last-resort fallback if the env's binary couldn't be located --
        # signal handling isn't guaranteed to work through this path.
        cmd = [conda or "conda", "run", "--no-capture-output", "-n", "snakemake", "snakemake"]

    conda_path_bin_dir = None
    _conda_for_path = conda or settings.get("conda_path")
    if _conda_for_path and os.path.isfile(_conda_for_path):
        conda_path_bin_dir = os.path.dirname(_conda_for_path)
    if snakemake_bin and os.path.isfile(os.path.join(os.path.dirname(snakemake_bin), "conda")):
        conda_path_bin_dir = os.path.dirname(snakemake_bin)
    return cmd, snakemake_bin, conda_path_bin_dir


def conda_too_old(conda_path_bin_dir: str | None) -> str | None:
    """A message if the conda the run will use is older than Snakemake accepts, else None."""
    exe = os.path.join(conda_path_bin_dir, "conda") if conda_path_bin_dir else shutil.which("conda")
    ver = conda_version(exe)
    if ver is not None and ver < MIN_CONDA_VERSION:
        return (f"conda {'.'.join(map(str, ver))} at {exe} is too old: Snakemake needs "
                f"conda {'.'.join(map(str, MIN_CONDA_VERSION))} or later to build the tools' environments. "
                "Reinstall Snakemake from the Settings screen (it now brings its own conda), "
                "or update conda (conda update -n base conda).")
    return None


def run_env_overrides(conda_path_bin_dir: str | None) -> dict:
    """Environment changes for the Snakemake process of a run."""
    overrides: dict = {}
    if not conda_path_bin_dir:
        return overrides
    overrides["PATH"] = f"{conda_path_bin_dir}{os.pathsep}{subprocess_env().get('PATH', '')}"
    # Snakemake runs each rule as `source <conda>/bin/activate <env>`.
    # If the run was started from a shell with a conda env active (typically
    # base), conda treats this as switching envs and swaps that env's bin/ for
    # the rule env's bin/ where it sits in PATH -- behind the directory
    # prepended above, whose python and snakemake then shadow the rule env's
    # own. VirSorter2 (its own inner Snakemake) and ISEScan (a
    # `#!/usr/bin/env python` helper) failed this way. With no env marked
    # active, activation puts the rule env's bin/ first.
    for var in ("CONDA_SHLVL", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "CONDA_PROMPT_MODIFIER"):
        overrides[var] = None
    for var in os.environ:
        if re.fullmatch(r"CONDA_PREFIX_\d+", var):
            overrides[var] = None
    return overrides


def snakemake_args(config_path: str, output_dir: str, cores: int, omit_from: list,
                   conda_prefix: str = CONDA_ENVS_DIR, resources: dict | None = None) -> list:
    """Snakemake arguments shared by every run, GUI or command line.

    resources: global resource limits (e.g. {"mem_mb": 240000}); merged with
    eggnog_dbmem into ONE --resources flag, since Snakemake keeps only the last
    occurrence of a repeated --resources."""
    args = [
        "--use-conda", "--conda-frontend", "conda",
        f"--conda-prefix={conda_prefix}",
        f"--cores={cores}",
        f"--configfile={config_path}",
        f"--directory={output_dir}",
        # A job failing (a missing database, a tool crashing on one sample)
        # must not stop every *independent* branch of the DAG.
        "--keep-going",
    ]
    # Disabled tools: skip their rule(s) and everything downstream of them
    # in Snakemake's own DAG, rather than reimplementing the cascade.
    if omit_from:
        args += ["--omit-from", *omit_from]
    # How many eggNOG-mapper --dbmem instances fit in RAM at once (each holds
    # its own ~44 GB copy of eggnog.db) -- computed by
    # config_engine.generate_config from the RAM budget.
    try:
        with open(config_path) as f:
            slots = int((yaml.safe_load(f) or {}).get("eggnog_dbmem_slots") or 0)
    except Exception:
        slots = 0
    limits = dict(resources or {})
    if slots > 0:
        limits["eggnog_dbmem"] = slots
    if limits:
        args += ["--resources", *(f"{k}={v}" for k, v in limits.items())]
    return args


# --- Tools switched off -> rules to omit -------------------------------------
# Python port of app/lib/logic/tool_dependency_graph.dart (settle and
# omitFromRuleNames), used by the command line. Track-aware: a dual-track tool
# (rules ending in _sample / _mags) that requires another dual-track tool
# depends on it per track.

def _tools(pipeline_id: str) -> dict:
    tools = {}
    for tid, t in (get_pipeline(pipeline_id).get("tools") or {}).items():
        tools[tid] = {
            "rule_names": list(t.get("rule_names") or []),
            "tracks": _tracks_for(t.get("rule_names") or []),
            "requires": [{"tools": list(g.get("tools") or []), "min": int(g.get("min", 1))}
                         for g in (t.get("requires") or [])],
        }
    return tools


def default_active_tools(pipeline_id: str) -> list:
    return [tid for tid, t in (get_pipeline(pipeline_id).get("tools") or {}).items()
            if t.get("active_by_default", True)]


def _group_ok(tools, group, track, active, tracks_on):
    count = 0
    for rid in group["tools"]:
        req = tools.get(rid)
        if req is None or rid not in active:
            continue
        if track is not None and req["tracks"]:
            if track not in tracks_on.get(rid, set(req["tracks"])):
                continue
        count += 1
    return count >= group["min"]


def _satisfied(tools, tid, track, active, tracks_on):
    tool = tools.get(tid)
    if tool is None:
        return True
    without = set(active) - {tid}
    return all(_group_ok(tools, g, track, without, tracks_on) for g in tool["requires"])


def settle(pipeline_id: str, active_tools, active_tracks: dict | None = None) -> tuple[set, dict]:
    """Drop every tool/track whose requirements are not met, until nothing changes."""
    tools = _tools(pipeline_id)
    active = set(active_tools)
    tracks_on = {k: set(v) for k, v in (active_tracks or {}).items()}
    changed = True
    while changed:
        changed = False
        for tid in sorted(active):
            tool = tools.get(tid)
            if tool is None:
                continue
            if not tool["tracks"]:
                if not _satisfied(tools, tid, None, active, tracks_on):
                    active.discard(tid)
                    tracks_on.pop(tid, None)
                    changed = True
                continue
            cur = tracks_on.get(tid, set(tool["tracks"]))
            keep = {t for t in cur if _satisfied(tools, tid, t, active, tracks_on)}
            if keep != cur:
                changed = True
                if not keep:
                    active.discard(tid)
                    tracks_on.pop(tid, None)
                else:
                    tracks_on[tid] = keep
    return active, tracks_on


def omit_from_rules(pipeline_id: str, active_tools, active_tracks: dict | None = None) -> list:
    """Rules not produced by the active tools/tracks. A rule shared by several
    tools is only omitted once every tool referencing it is inactive."""
    tools = _tools(pipeline_id)
    all_rules = {r for t in tools.values() for r in t["rule_names"]}
    keep = set()
    for tid, tool in tools.items():
        if tid not in active_tools:
            continue
        if not tool["tracks"]:
            keep.update(tool["rule_names"])
            continue
        on = (active_tracks or {}).get(tid, set(tool["tracks"]))
        for track, rules in tool["tracks"].items():
            if track in on:
                keep.update(rules)
    return sorted(all_rules - keep)
