import subprocess
import shutil
import asyncio
import os

def check_snakemake(conda_info: dict) -> dict:
    path = shutil.which("snakemake")
    if path:
        try:
            result = subprocess.run([path, "--version"], capture_output=True, text=True)
            version = result.stdout.strip()
            return {"installed": True, "path": path, "version": version}
        except Exception:
            pass

    if conda_info.get("installed"):
        conda = conda_info["path"]
        try:
            result = subprocess.run(
                [conda, "run", "-n", "snakemake", "snakemake", "--version"],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                version = result.stdout.strip()
                return {"installed": True, "path": "conda:snakemake", "version": version}
        except Exception:
            pass

    return {"installed": False, "path": None, "version": None}

def check_dart_logger_plugin(conda_info: dict) -> dict:
    """Whether `snakemake-logger-plugin-dart` is importable inside the same
    `snakemake` env/binary a real run would use. Cached by the caller, not
    here -- mirrors check_snakemake()'s own "ask the real interpreter, don't
    guess from a version string" approach, since a plugin can be missing even
    when Snakemake itself is a fine, recent version (it's a separate PyPI
    package, not bundled). Feature-gates the `--logger dart` flags in
    pipeline_ws: an unconditional `--logger dart` would make Snakemake itself
    refuse to start ("unrecognized logger") for anyone who hasn't installed
    this plugin yet -- this check is what keeps that path opt-in/additive.
    """
    path = shutil.which("snakemake")
    python_bin = None
    if path:
        python_bin = os.path.join(os.path.dirname(path), "python")
    elif conda_info.get("installed"):
        conda_root = os.path.dirname(os.path.dirname(conda_info["path"]))
        candidate = os.path.join(conda_root, "envs", "snakemake", "bin", "python")
        if os.path.isfile(candidate):
            python_bin = candidate

    if not python_bin or not os.path.isfile(python_bin):
        return {"available": False}

    try:
        result = subprocess.run(
            [python_bin, "-c", "import snakemake_logger_plugin_dart"],
            capture_output=True, text=True,
        )
        return {"available": result.returncode == 0}
    except Exception:
        return {"available": False}


async def install_snakemake() -> dict:
    from settings_store import load_settings
    settings = load_settings()
    conda = settings.get("conda_path", "conda")

    proc = await asyncio.create_subprocess_exec(
        conda, "create", "-n", "snakemake",
        "-c", "conda-forge", "-c", "bioconda",
        "snakemake", "-y",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    await proc.wait()

    if proc.returncode == 0:
        return {"success": True}
    return {"success": False, "error": "Instalação do Snakemake falhou"}
