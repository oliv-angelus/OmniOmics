"""
Plots tab analysis engine: reads plots/manifest.yaml (same tools/flags-style
schema pipeline.yaml's tool definitions already use, see tools_engine.py) and
resolves the shared `r-plots` conda env's Rscript binary. Mirrors
pipelines.py's manifest-loading pattern and snakemake_manager.py's
env-resolution pattern -- there is exactly one R analysis engine shared by
every pipeline's output, not one per pipeline, so this lives at the repo root
next to (not inside) pipelines/.
"""
import os
import sys
import subprocess
import asyncio
import yaml

# See pipelines.PIPELINES_DIR's comment: PyInstaller freezes __file__ to a temp
# extraction dir, so a frozen build must resolve plots/ relative to the real
# executable location instead.
_here = os.path.dirname(sys.executable) if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__))
PLOTS_DIR = os.path.normpath(os.path.join(_here, "..", "plots"))
MANIFEST_PATH = os.path.join(PLOTS_DIR, "manifest.yaml")
R_ENV_SPEC = os.path.join(PLOTS_DIR, "r_env", "plots.yaml")
R_ENV_NAME = "r-plots"

_cache: dict | None = None


def _load_manifest() -> dict:
    global _cache
    if _cache is not None:
        return _cache
    with open(MANIFEST_PATH, encoding="utf-8") as f:
        _cache = yaml.safe_load(f) or {"analyses": []}
    return _cache


def reload_manifest() :
    """Drop the in-memory cache so the next call re-reads manifest.yaml from disk."""
    global _cache
    _cache = None


def get_analysis_list(pipeline_id: str | None = None) -> list:
    """All analyses, or only those whose applies_to includes pipeline_id."""
    analyses = _load_manifest().get("analyses", [])
    if pipeline_id is None:
        return analyses
    return [a for a in analyses if pipeline_id in a.get("applies_to", [])]


def get_analysis(analysis_id: str) -> dict:
    for a in _load_manifest().get("analyses", []):
        if a["id"] == analysis_id:
            return a
    raise KeyError(f"Unknown analysis: {analysis_id}")


def get_input_shape_for_pipeline(pipeline_id: str) -> str:
    """The "load" step (POST /api/plots/load) runs once, right after a run
    is picked -- BEFORE any specific analysis is chosen -- so it can't ask a
    single analysis what input_shape it wants; every analysis a pipeline's
    runs can use is expected to share one shape (phyloseq or count_matrix),
    by manifest design (see plots/manifest.yaml's header comment). Looks at
    the real analyses declared for this pipeline rather than hardcoding a
    pipeline_id -> shape table, so a future pipeline just needs its
    manifest.yaml entries' applies_to/input_shape set correctly -- nothing
    to update here. Defaults to "phyloseq" (MAGMA, the original/only shape
    before DEFINE's count_matrix support existed) if a pipeline has no
    analyses at all yet, so an unconfigured pipeline fails at "no compatible
    analyses" rather than here.
    """
    shapes = {a.get("input_shape", "phyloseq") for a in get_analysis_list(pipeline_id)}
    if len(shapes) > 1:
        raise ValueError(f"Pipeline '{pipeline_id}' has analyses with mixed input_shape values: {shapes} -- not supported.")
    return next(iter(shapes), "phyloseq")


def build_params_args(analysis_id: str, param_states: list) -> list:
    """Assembles the Rscript CLI args from a list of param states -- same
    enabled/type/default resolution as tools_engine.build_params_string, but
    returns an argv list (['--flag', 'value',...]) instead of a shell string
    since this is exec'd directly (see resolve_rscript), not through a shell.
    """
    analysis = get_analysis(analysis_id)
    param_defs = {p["flag"]: p for p in analysis.get("parameters", [])}

    args = []
    for state in param_states:
        if not state.get("enabled"):
            continue
        flag = state["flag"]
        pdef = param_defs.get(flag, {})
        ptype = pdef.get("type", "str")

        if ptype == "bool":
            args.append(flag)
        else:
            val = state.get("value", "")
            if val == "" or val is None:
                val = pdef.get("default", "")
            if val != "" and val is not None:
                args += [flag, str(val)]

    return args


def _subprocess_env() -> dict:
    """Same PATH-stripping as main._subprocess_env (see its docstring) -- duplicated here rather than imported so plots_engine has no dependency on
    main.py, matching the rest of this module's standalone engine files."""
    env = os.environ.copy()
    roots = {p for p in (env.pop("VIRTUAL_ENV", None),
                         sys.prefix if sys.prefix != sys.base_prefix else None) if p}
    if roots:
        drop = {os.path.normpath(os.path.join(r, "bin")) for r in roots}
        env["PATH"] = os.pathsep.join(
            p for p in env.get("PATH", "").split(os.pathsep)
            if p and os.path.normpath(p) not in drop
        )
    # R-specific leak: a system/user R installation's own libs must not shadow
    # the r-plots conda env's package versions -- same class of bug as the
    # KrakenTools PATH leak (see main._subprocess_env).
    for var in ("R_LIBS", "R_LIBS_USER", "R_LIBS_SITE"):
        env.pop(var, None)
    for key in list(env):
        if key.startswith("RENV_"):
            env.pop(key, None)
    return env


def resolve_rscript(conda_path: str | None) -> str | None:
    """Resolves the r-plots env's own Rscript binary directly -- deliberately
    NOT `conda run -n r-plots Rscript`, for the same reason pipeline_ws
    resolves snakemake's binary directly instead of going through `conda run`:
    conda run doesn't reliably forward SIGTERM to the wrapped process, which
    would leave an R analysis running after the user cancels it.
    """
    if conda_path and os.path.isfile(conda_path):
        candidate = os.path.join(
            os.path.dirname(os.path.dirname(conda_path)), "envs", R_ENV_NAME, "bin", "Rscript"
        )
        if os.path.isfile(candidate):
            return candidate
    return None


def check_r_env(conda_path: str | None) -> dict:
    rscript = resolve_rscript(conda_path)
    if not rscript:
        return {"installed": False, "path": None, "version": None}
    try:
        result = subprocess.run([rscript, "--version"], capture_output=True, text=True, env=_subprocess_env)
        version = (result.stdout or result.stderr).strip()
        return {"installed": True, "path": rscript, "version": version}
    except Exception:
        return {"installed": False, "path": None, "version": None}


async def install_r_env(conda_path: str) -> dict:
    """Builds the shared r-plots env, same on-demand-install pattern as
    snakemake_manager.install_snakemake. `conda env create -f` (not
    `conda create -n... <pkgs>`) since plots/r_env/plots.yaml already
    declares its own `name:`/`channels:`/`dependencies:` like a full
    environment.yml, matching how Snakemake's own --use-conda envs are
    built from *.yaml files elsewhere in this repo.
    """
    proc = await asyncio.create_subprocess_exec(
        conda_path, "env", "create", "-f", R_ENV_SPEC,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env=_subprocess_env,
    )
    await proc.wait()

    if proc.returncode == 0:
        return {"success": True}
    return {"success": False, "error": "Instalação do ambiente R (r-plots) falhou"}


def script_path(analysis_id: str) -> str:
    analysis = get_analysis(analysis_id)
    return os.path.join(PLOTS_DIR, "scripts", analysis["script"])
