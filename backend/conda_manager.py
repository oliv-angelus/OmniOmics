import subprocess
import shutil
import os

from settings_store import load_settings, save_settings

# Distinct conda distributions users may already have a preference for --
# all three ship a `conda` binary, so check_conda/the rest of the app
# doesn't need to know which one was installed.
CONDA_DISTRIBUTIONS = {
    "miniforge": {
        "name": "Miniforge3",
        "description": {
            "pt": "Instalador mínimo com conda-forge/bioconda como canais padrão (recomendado para este app)",
            "en": "Minimal installer with conda-forge/bioconda as default channels (recommended for this app)",
        },
        "url": "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh",
    },
    "miniconda": {
        "name": "Miniconda3",
        "description": {
            "pt": "Instalador mínimo oficial da Anaconda Inc.",
            "en": "Official minimal installer from Anaconda Inc.",
        },
        "url": "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh",
    },
    "anaconda": {
        "name": "Anaconda3",
        "description": {
            "pt": "Distribuição completa (~3 GB), centenas de pacotes científicos pré-instalados",
            "en": "Full distribution (~3 GB), hundreds of scientific packages pre-installed",
        },
        # Unlike Miniconda/Miniforge, Anaconda's archive has no "-latest-" alias
        # (that URL 404s and returns an HTML error page, which the installer
        # script then chokes on as a syntax error) -- has to be a pinned,
        # periodically-bumped version. Confirmed reachable as of.
        "url": "https://repo.anaconda.com/archive/Anaconda3-2025.12-2-Linux-x86_64.sh",
    },
}


def conda_distribution_list(lang: str = "pt") -> list:
    return [
        {"id": k, "name": v["name"], "description": v["description"].get(lang, v["description"]["pt"]), "url": v["url"]}
        for k, v in CONDA_DISTRIBUTIONS.items
    ]


def check_conda -> dict:
    settings = load_settings
    saved_path = settings.get("conda_path")

    candidates = [saved_path] if saved_path else []
    candidates += [
        shutil.which("conda"),
        os.path.expanduser("~/miniforge3/bin/conda"),
        os.path.expanduser("~/miniconda3/bin/conda"),
        os.path.expanduser("~/anaconda3/bin/conda"),
    ]

    for path in candidates:
        if path and os.path.isfile(path):
            try:
                result = subprocess.run([path, "--version"], capture_output=True, text=True)
                version = result.stdout.strip or result.stderr.strip
                save_settings({"conda_path": path})
                return {"installed": True, "path": path, "version": version}
            except Exception:
                continue

    return {"installed": False, "path": None, "version": None}

async def install_conda(install_path: str, distribution: str = "miniforge") -> dict:
    import httpx
    import asyncio

    distro = CONDA_DISTRIBUTIONS.get(distribution, CONDA_DISTRIBUTIONS["miniforge"])
    url = distro["url"]
    installer = "/tmp/conda_installer.sh"

    async with httpx.AsyncClient(follow_redirects=True, timeout=300) as client:
        resp = await client.get(url)
        with open(installer, "wb") as f:
            f.write(resp.content)

    os.chmod(installer, 0o755)
    proc = await asyncio.create_subprocess_exec(
        "bash", installer, "-b", "-p", install_path,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    await proc.wait

    conda_bin = os.path.join(install_path, "bin", "conda")
    if os.path.isfile(conda_bin):
        subprocess.run([conda_bin, "config", "--add", "channels", "bioconda"], check=False)
        subprocess.run([conda_bin, "config", "--add", "channels", "conda-forge"], check=False)
        save_settings({"conda_path": conda_bin})
        return {"success": True, "path": conda_bin}

    return {"success": False, "error": "Instalação falhou"}
