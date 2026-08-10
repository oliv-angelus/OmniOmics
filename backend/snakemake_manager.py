import subprocess
import shutil
import asyncio

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
