import subprocess
import asyncio
import json
import os
import re
import gzip
import shutil
import signal
import sys
import time
import httpx
import aiofiles
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# BackendLauncher.start spawns this as a direct child of the Flutter/GTK
# process and relies on didChangeAppLifecycleState(detached) -> stop to
# kill it back when the app closes. On Linux, closing the window (the X
# button) does not reliably deliver that lifecycle callback -- confirmed by
# closing the window and observing this process survive its parent -- so
# that path alone leaves an orphaned backend running (and holding its port)
# every time. PR_SET_PDEATHSIG asks the kernel to SIGTERM this process the
# moment its *current* parent dies, for any reason (closed window, crash,
# kill -9) -- no cooperation from the parent required, unlike the Dart-side
# path. Best-effort: harmless no-op if libc/prctl isn't available (e.g. when
# this file is imported rather than run standalone) or on a non-Linux OS,
# where the existing Dart-side stop remains the only mechanism.
if sys.platform.startswith("linux"):
    try:
        import ctypes
        _PR_SET_PDEATHSIG = 1
        _libc = ctypes.CDLL("libc.so.6", use_errno=True)
        _libc.prctl(_PR_SET_PDEATHSIG, signal.SIGTERM)
    except OSError:
        pass

# Strip ANSI escape codes and handle \r (conda progress bars)
_ANSI_RE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

def clean_output(raw: bytes) -> str:
    text = raw.decode(errors="replace")
    text = _ANSI_RE.sub('', text)
    result = []
    for line in text.split('\n'):
        # \r used by conda/wget for in-place progress: keep last segment
        segs = [s for s in line.split('\r') if s.strip()]
        if segs:
            result.append(segs[-1])
    return ('\n'.join(result) + '\n') if result else ''

import pipelines
from conda_manager import check_conda, install_conda
from snakemake_manager import check_snakemake, install_snakemake
from system_monitor import get_system_info
from databases_engine import (
    get_databases_status, get_all_databases_status, detect_databases, detect_all_databases,
    validate_database, get_download_option, save_settings, load_settings,
    record_download_choice, clear_download_choice,
)
import config_engine
import tools_engine
import runs_store
import run_report
import plots_engine
import plot_runs_store

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Setup (global, pipeline-agnostic) ---

REQUIRED_PY_PACKAGES = ["fastapi", "uvicorn", "httpx", "aiofiles", "psutil", "yaml"]

def check_python_deps() -> dict:
    """Check that all required Python packages are importable."""
    import importlib
    missing = []
    for pkg in REQUIRED_PY_PACKAGES:
        try:
            importlib.import_module(pkg)
        except ImportError:
            missing.append(pkg)
    return {
        "installed": len(missing) == 0,
        "missing":   missing,
        "packages":  REQUIRED_PY_PACKAGES,
    }

def check_vibrant_tools() -> dict:
    """Check if HMMER3 (hmmfetch, hmmpress) and wget are available."""
    hmmfetch = shutil.which("hmmfetch")
    hmmpress = shutil.which("hmmpress")
    wget     = shutil.which("wget")
    return {
        "installed": bool(hmmfetch and hmmpress and wget),
        "hmmfetch":  bool(hmmfetch),
        "hmmpress":  bool(hmmpress),
        "wget":      bool(wget),
        "path":      hmmfetch or "",
    }

@app.get("/api/setup/status")
def setup_status():
    conda         = check_conda()
    snakemake     = check_snakemake(conda)
    vibrant_tools = check_vibrant_tools()
    python_deps   = check_python_deps()
    return {"conda": conda, "snakemake": snakemake,
            "vibrant_tools": vibrant_tools, "python_deps": python_deps}

@app.websocket("/ws/install/python-deps")
async def install_python_deps_ws(websocket: WebSocket):
    """Install missing Python backend packages via pip."""
    await websocket.accept()
    proc = None
    try:
        deps = check_python_deps()
        if deps["installed"]:
            await websocket.send_json({"type": "done", "status": deps})
            return

        pkgs = deps["missing"]
        await websocket.send_json({"type": "log",
            "text": f"Instalando: {', '.join(pkgs)}\n"})

        proc = await asyncio.create_subprocess_exec(
            "python3", "-m", "pip", "install", "--upgrade", *pkgs,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        async for line in proc.stdout:
            text = clean_output(line)
            if text:
                await websocket.send_json({"type": "log", "text": text})
        rc = await proc.wait()

        if rc == 0:
            await websocket.send_json({"type": "done", "status": check_python_deps()})
        else:
            await websocket.send_json({"type": "error",
                "text": "pip install falhou. Tente: pip install -r backend/requirements.txt"})
    except WebSocketDisconnect:
        if proc and proc.returncode is None:
            proc.terminate()
    except Exception as e:
        try:
            await websocket.send_json({"type": "error", "text": str(e)})
        except Exception:
            pass

@app.post("/api/setup/install-conda")
async def install_conda_route(path: str = "/home/" + os.environ.get("USER", "user") + "/miniforge3"):
    result = await install_conda(path)
    return result

@app.post("/api/setup/install-snakemake")
async def install_snakemake_route():
    result = await install_snakemake()
    return result

@app.get("/api/setup/conda-distributions")
def conda_distributions(lang: str = "pt"):
    from conda_manager import conda_distribution_list
    return conda_distribution_list(lang)

@app.websocket("/ws/install/conda")
async def install_conda_ws(websocket: WebSocket):
    """Download and install the chosen conda distribution, streaming progress."""
    from conda_manager import CONDA_DISTRIBUTIONS
    await websocket.accept()
    proc = None
    try:
        msg = await websocket.receive_json()
        install_path = os.path.expanduser(msg.get("install_path", "~/miniforge3"))
        distro_id = msg.get("distribution", "miniforge")
        distro = CONDA_DISTRIBUTIONS.get(distro_id, CONDA_DISTRIBUTIONS["miniforge"])

        await websocket.send_json({"type": "log", "text": f"Destino: {install_path}\n"})
        await websocket.send_json({"type": "log", "text": f"Baixando {distro['name']}...\n"})

        url = distro["url"]
        installer = "/tmp/conda_installer.sh"

        async with httpx.AsyncClient(follow_redirects=True, timeout=600) as client:
            async with client.stream("GET", url) as resp:
                total = int(resp.headers.get("content-length", 0))
                downloaded = 0
                with open(installer, "wb") as f:
                    async for chunk in resp.aiter_bytes(65536):
                        f.write(chunk)
                        downloaded += len(chunk)
                        if total:
                            pct = int(downloaded / total * 100)
                            mb = downloaded // 1024 // 1024
                            total_mb = total // 1024 // 1024
                            await websocket.send_json({"type": "progress", "pct": pct,
                                "text": f"Download: {pct}% ({mb}/{total_mb} MB)\n"})

        # A broken/dead download URL often 404s with an HTML error page instead
        # of raising -- that then hits bash as a "syntax error near unexpected
        # token" a minute later, which is a confusing way to learn the real
        # problem was upstream. Catch it here with a clear message instead.
        with open(installer, "rb") as f:
            head = f.read(64)
        if not head.lstrip().startswith(b"#!"):
            await websocket.send_json({"type": "error",
                "text": f"Download inválido: {installer} não parece ser um instalador shell "
                        f"(a URL pode estar fora do ar ou ter mudado). Início do arquivo: {head[:40]!r}\n"})
            return

        os.chmod(installer, 0o755)
        await websocket.send_json({"type": "log", "text": f"\nInstalando em {install_path}...\n"})

        proc = await asyncio.create_subprocess_exec(
            "bash", installer, "-b", "-p", install_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        async for line in proc.stdout:
            text = clean_output(line)
            if text:
                await websocket.send_json({"type": "log", "text": text})
        await proc.wait()

        conda_bin = os.path.join(install_path, "bin", "conda")
        if proc.returncode == 0 and os.path.isfile(conda_bin):
            await websocket.send_json({"type": "log", "text": "Configurando canais conda (bioconda, conda-forge)...\n"})
            subprocess.run([conda_bin, "config", "--add", "channels", "bioconda"], check=False)
            subprocess.run([conda_bin, "config", "--add", "channels", "conda-forge"], check=False)
            subprocess.run([conda_bin, "config", "--set", "channel_priority", "strict"], check=False)
            save_settings({"conda_path": conda_bin})
            await websocket.send_json({"type": "done", "path": conda_bin})
        else:
            await websocket.send_json({"type": "error", "text": "Instalação falhou.\n"})

    except WebSocketDisconnect:
        if proc and proc.returncode is None:
            proc.terminate()
    except Exception as e:
        try:
            await websocket.send_json({"type": "error", "text": str(e)})
        except Exception:
            pass

@app.websocket("/ws/install/snakemake")
async def install_snakemake_ws(websocket: WebSocket):
    """Create the 'snakemake' conda environment, streaming progress."""
    await websocket.accept()
    proc = None
    try:
        from settings_store import load_settings
        settings = load_settings()
        conda = settings.get("conda_path") or shutil.which("conda") or "conda"

        await websocket.send_json({"type": "log", "text": f"Usando conda: {conda}\n"})
        await websocket.send_json({"type": "log", "text": "Criando ambiente 'snakemake'...\n"})

        proc = await asyncio.create_subprocess_exec(
            conda, "create", "-n", "snakemake",
            "-c", "conda-forge", "-c", "bioconda",
            "snakemake", "-y",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        async for line in proc.stdout:
            text = clean_output(line)
            if text:
                await websocket.send_json({"type": "log", "text": text})
        await proc.wait()

        if proc.returncode == 0:
            await websocket.send_json({"type": "done"})
        else:
            await websocket.send_json({"type": "error", "text": "Instalação do Snakemake falhou.\n"})

    except WebSocketDisconnect:
        if proc and proc.returncode is None:
            proc.terminate()
    except Exception as e:
        try:
            await websocket.send_json({"type": "error", "text": str(e)})
        except Exception:
            pass

@app.websocket("/ws/install/vibrant-tools")
async def install_vibrant_tools_ws(websocket: WebSocket):
    """Install HMMER3 + wget via conda, streaming output."""
    await websocket.accept()
    proc = None
    try:
        conda = check_conda()
        if not conda["installed"]:
            await websocket.send_json({"type": "error",
                "text": "Conda not found. Install conda first."})
            return

        conda_bin = conda["path"]
        await websocket.send_json({"type": "log",
            "text": f"Conda: {conda_bin}\n"
                    f"Instalando HMMER3 e wget via conda-forge / bioconda…\n"})

        proc = await asyncio.create_subprocess_exec(
            conda_bin, "install", "-y",
            "-c", "conda-forge", "-c", "bioconda",
            "hmmer", "wget",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        async for line in proc.stdout:
            text = clean_output(line)
            if text:
                await websocket.send_json({"type": "log", "text": text})
        rc = await proc.wait()

        if rc == 0:
            status = check_vibrant_tools()
            await websocket.send_json({"type": "done", "status": status})
        else:
            await websocket.send_json({"type": "error",
                "text": "conda install exited with errors."})
    except WebSocketDisconnect:
        if proc and proc.returncode is None:
            proc.terminate()
    except Exception as e:
        try:
            await websocket.send_json({"type": "error", "text": str(e)})
        except Exception:
            pass

# --- Sistema (global) ---

@app.get("/api/system/info")
def system_info():
    return get_system_info()

@app.websocket("/ws/system")
async def system_monitor_ws(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            data = get_system_info()
            await websocket.send_json(data)
            await asyncio.sleep(2)
    except WebSocketDisconnect:
        pass

# --- Pipeline registry (Hub) ---

@app.get("/api/pipelines")
def pipelines_list():
    return pipelines.list_pipelines()

@app.get("/api/pipelines/running")
def pipelines_running():
    """Pipeline ids with a run currently in progress -- lets the UI offer a
    'back to monitor' affordance after navigating away, or on app restart.
    Registered before /api/pipelines/{pid} so "running" isn't swallowed as a pid.
    """
    return {"running": [pid for pid, p in pipeline_processes.items() if p.returncode is None]}

@app.get("/api/pipelines/{pid}")
def pipelines_get(pid: str):
    try:
        manifest = dict(pipelines.get_pipeline(pid))
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown pipeline: {pid}")
    manifest.pop("_dir", None)
    return manifest

# --- Tools (per pipeline) ---

@app.get("/api/pipelines/{pid}/tools")
def tools_definitions(pid: str):
    return tools_engine.get_tool_list(pid)

@app.post("/api/pipelines/{pid}/tools/params-string")
def tools_params_string(pid: str, data: dict):
    tool_id = data.get("tool_id")
    flags   = data.get("flags", [])
    return {"params": tools_engine.build_params_string(pid, tool_id, flags)}

# --- Databases (per pipeline) ---

@app.get("/api/databases")
def all_databases_status():
    """Hub-level, cross-pipeline database list -- lets the user configure a
    database (e.g. CheckM2, shared by MAGMA and SIGMA) once, before picking a
    pipeline. Each entry names a (source_pipeline_id, source_key) pair the
    frontend uses to route set/download actions through the existing
    per-pipeline endpoints below, since the underlying setting is global."""
    return get_all_databases_status()

@app.post("/api/databases/detect")
def all_databases_detect(data: dict):
    base_dir = data.get("base_dir", "")
    return {"found": detect_all_databases(base_dir)}

@app.get("/api/pipelines/{pid}/databases")
def databases_status(pid: str):
    return get_databases_status(pid)

@app.post("/api/pipelines/{pid}/databases/set")
def databases_set(pid: str, data: dict):
    key  = data.get("key")
    path = data.get("path")
    databases = pipelines.get_pipeline(pid).get("databases", {})
    if key in databases:
        setting_key = databases[key]["setting_key"]
        save_settings({setting_key: path})
        # Manually picked/detected path -- any previously recorded download
        # option no longer describes what's actually here (see run_report.py,
        # which cites the exact option only when it's confidently known).
        clear_download_choice(setting_key)
    return {"ok": True}

@app.post("/api/pipelines/{pid}/databases/{key}/validate")
def databases_validate(pid: str, key: str, data: dict):
    """Checks a manually-picked folder against this database's fingerprint
    before accepting it, instead of trusting any existing directory the user
    happens to point at (which is all databases_set does on its own)."""
    path = data.get("path", "")
    return validate_database(pid, key, path)

@app.post("/api/pipelines/{pid}/databases/set-base-dir")
def databases_set_base_dir(pid: str, data: dict):
    base_dir = data.get("base_dir", "")
    save_settings({"db_base_dir": base_dir})
    return {"ok": True}

@app.get("/api/pipelines/{pid}/databases/base-dir")
def databases_get_base_dir(pid: str):
    """Last folder used for downloads/detection -- lets the UI pre-fill the
    'download all missing' dialog with wherever the user already keeps databases."""
    return {"base_dir": load_settings().get("db_base_dir", "")}

@app.post("/api/pipelines/{pid}/databases/detect")
def databases_detect(pid: str, data: dict):
    base_dir = data.get("base_dir", "")
    found = detect_databases(pid, base_dir)
    return {"found": found}

async def _download_database(pid: str, db_key: str, opt_id: str, dest_dir: str, send) -> str:
    """Downloads + installs (decompress/extract/post_cmd) one database option into
    dest_dir, reporting progress through `send(event: dict)`. Shared by the
    single-database download route and the "download all missing" bulk route.
    Returns dest_dir on success; raises on failure (caller decides how to report it).
    """
    opt = get_download_option(pid, db_key, opt_id)
    if not opt:
        raise ValueError("Unknown database option.")

    # Track exactly what this download writes into dest_dir so a cancel or an
    # error can remove only *its own* partial files, never anything that was
    # already in the folder (dest_dir can be a pre-existing directory the user
    # keeps other databases in). See _cleanup_partial below.
    created_paths: list = []
    dest_dir_preexisted = os.path.isdir(dest_dir)
    os.makedirs(dest_dir, exist_ok=True)

    def _cleanup_partial():
        for p in created_paths:
            try:
                if os.path.isdir(p) and not os.path.islink(p):
                    shutil.rmtree(p, ignore_errors=True)
                elif os.path.lexists(p):
                    os.remove(p)
            except OSError:
                pass
        # If we created dest_dir ourselves and nothing else landed in it, drop
        # the now-empty folder too (rmdir only succeeds when empty, so a folder
        # that already held other content is left untouched).
        if not dest_dir_preexisted:
            try:
                os.rmdir(dest_dir)
            except OSError:
                pass

    async def stream_url(url: str, fallback_name: str = "") -> str:
        async with httpx.AsyncClient(follow_redirects=True, timeout=None) as client:
            async with client.stream("GET", url) as resp:
                resp.raise_for_status()
                # Determine filename: explicit fallback → URL path → Content-Disposition
                if fallback_name:
                    filename = fallback_name
                else:
                    filename = url.split("?")[0].rstrip("/").split("/")[-1]
                if not filename:
                    cd = resp.headers.get("content-disposition", "")
                    m = re.search(r'filename\*?=(?:UTF-8\'\')?["\']?([^\"\';]+)', cd, re.I)
                    filename = m.group(1).strip() if m else "download"
                dest_file = os.path.join(dest_dir, filename)
                if dest_file not in created_paths:
                    created_paths.append(dest_file)
                await send({"type": "log", "text": f"→ {filename}\n"})
                total      = int(resp.headers.get("content-length", 0))
                downloaded = 0
                async with aiofiles.open(dest_file, "wb") as f:
                    async for chunk in resp.aiter_bytes(chunk_size=1024 * 1024):
                        await f.write(chunk)
                        downloaded += len(chunk)
                        dl_mb  = downloaded / 1024 / 1024
                        if total:
                            pct    = downloaded / total * 100
                            tot_mb = total / 1024 / 1024
                            unit   = "GB" if tot_mb > 1024 else "MB"
                            div    = 1024 if unit == "GB" else 1
                            await send({
                                "type":    "progress",
                                "percent": round(pct, 1),
                                "done":    f"{dl_mb/div:.2f}",
                                "total":   f"{tot_mb/div:.2f}",
                                "unit":    unit,
                            })
                        else:
                            # No Content-Length — send bytes downloaded as log-style progress
                            unit = "GB" if dl_mb > 1024 else "MB"
                            div  = 1024 if unit == "GB" else 1
                            await send({
                                "type":    "progress",
                                "percent": 0,
                                "done":    f"{dl_mb/div:.2f}",
                                "total":   "?",
                                "unit":    unit,
                            })
        return dest_file

    async def process_file(path: str, force_gunzip: bool = False, force_extract: bool = False):
        """Decompress/extract a file.
        Auto-detects.tar.gz/.tgz/.tar.xz (extract) and.gz (gunzip) by extension.
        force_gunzip / force_extract override when extension alone isn't enough.
        """
        fname = os.path.basename(path)
        is_tar = fname.endswith(".tar.gz") or fname.endswith(".tgz") or fname.endswith(".tar.xz")
        is_gz  = fname.endswith(".gz") and not is_tar

        if force_gunzip or is_gz:
            out = path[:-3]
            await send({"type": "log", "text": f"Decompressing {fname}…\n"})
            loop = asyncio.get_event_loop()
            def _gunzip():
                with gzip.open(path, "rb") as fi, open(out, "wb") as fo:
                    shutil.copyfileobj(fi, fo)
                os.remove(path)
            await loop.run_in_executor(None, _gunzip)
            # The.gz is gone; track its decompressed output as ours instead.
            if path in created_paths:
                created_paths.remove(path)
            if out not in created_paths:
                created_paths.append(out)
            return out

        if force_extract or is_tar:
            await send({"type": "log", "text": f"Extracting {fname}…\n"})
            # -a auto-detects the compression codec (gzip, xz,...) from the
            # filename instead of hardcoding gzip -- Bakta's DB ships as.tar.xz,
            # unlike every other database here which is.tar.gz.
            before = set(os.listdir(dest_dir))
            proc = await asyncio.create_subprocess_exec(
                "tar", "-xaf", path, "-C", dest_dir,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            async for line in proc.stdout:
                text = clean_output(line)
                if text:
                    await send({"type": "log", "text": text})
            await proc.wait()
            # Track every top-level entry the archive added (diffing the dir is
            # simpler and more robust than parsing tar's member list), then drop
            # the archive itself from tracking since it's about to be removed.
            for name in set(os.listdir(dest_dir)) - before:
                p = os.path.join(dest_dir, name)
                if p not in created_paths:
                    created_paths.append(p)
            os.remove(path)
            if path in created_paths:
                created_paths.remove(path)

        return path

    async def run_cmd(cmd: str, cwd: str = None):
        """Run a shell command, streaming cleaned output through `send`."""
        proc = await asyncio.create_subprocess_shell(
            cmd, cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        async for line in proc.stdout:
            text = clean_output(line)
            if text:
                await send({"type": "log", "text": text})
        return await proc.wait()

    # ── VIBRANT special setup ─────────────────────────────────────────────
    if opt.get("vibrant_setup"):
        await send({"type": "log", "text": "Starting VIBRANT database setup…\n"})

        # Check dependencies (silently)
        async def tool_exists(name: str) -> bool:
            proc = await asyncio.create_subprocess_shell(
                f"which {name}",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            return (await proc.wait()) == 0

        for tool in ("wget", "hmmfetch", "hmmpress"):
            if not await tool_exists(tool):
                raise RuntimeError(f"'{tool}' not found. Install HMMER3 and wget first (e.g. conda install hmmer wget).")

        # (1) Download profile name lists from GitHub
        pn_dir = os.path.join(dest_dir, "profile_names")
        os.makedirs(pn_dir, exist_ok=True)
        await send({"type": "log", "text": "Downloading VIBRANT profile name lists…\n"})
        for pn_file in ("VIBRANT_kegg_profiles.txt", "VIBRANT_vog_profiles.txt"):
            url_pn = f"https://raw.githubusercontent.com/AnantharamanLab/VIBRANT/master/databases/profile_names/{pn_file}"
            async with httpx.AsyncClient(follow_redirects=True, timeout=60) as client:
                r = await client.get(url_pn)
                r.raise_for_status()
                with open(os.path.join(pn_dir, pn_file), "w") as f:
                    f.write(r.text)
            await send({"type": "log", "text": f"  ✓ {pn_file}\n"})

        # (2) Download the VIBRANT_setup.py script from GitHub
        setup_py = os.path.join(dest_dir, "VIBRANT_setup.py")
        await send({"type": "log", "text": "Downloading VIBRANT_setup.py…\n"})
        async with httpx.AsyncClient(follow_redirects=True, timeout=60) as client:
            r = await client.get(
                "https://raw.githubusercontent.com/AnantharamanLab/VIBRANT/master/databases/VIBRANT_setup.py")
            r.raise_for_status()
            with open(setup_py, "w") as f:
                f.write(r.text)
        await send({"type": "log", "text": "✓ VIBRANT_setup.py ready\n"})

        # (3) Run the setup script (it handles all downloads via wget internally)
        await send({"type": "log",
            "text": f"Running VIBRANT_setup.py in {dest_dir} — this may take a long time…\n"})
        rc = await run_cmd("python3 VIBRANT_setup.py", cwd=dest_dir)
        if rc != 0:
            raise RuntimeError("VIBRANT_setup.py exited with errors. Check the log above.")

        databases = pipelines.get_pipeline(pid).get("databases", {})
        db = databases.get(db_key, {})
        if db.get("setting_key"):
            save_settings({db["setting_key"]: dest_dir})
            record_download_choice(db["setting_key"], opt_id)
        return dest_dir

    # ── Standard download flow ────────────────────────────────────────────
    # Any abnormal exit (explicit cancel -> CancelledError, client disconnect
    # -> WebSocketDisconnect via send, or a network/IO error) removes this
    # download's own partial files before propagating, so a cancelled or failed
    # download doesn't leave half-written/corrupt files behind. BaseException
    # (not Exception) so CancelledError is covered too.
    try:
        dest_file = await stream_url(opt["url"], fallback_name=opt.get("filename", ""))
        dest_file = await process_file(dest_file,
                                       force_gunzip=opt.get("gunzip", False),
                                       force_extract=opt.get("extract", False))

        # Download extra files — auto-detect extraction by extension
        for extra_url in opt.get("extra_files", []):
            extra_file = await stream_url(extra_url)
            await process_file(extra_file)

        # Optional post-command (e.g. hmmpress for Pfam). {pipeline_dir} lets a
        # post_cmd call a script that ships with the pipeline itself (e.g.
        # PRISM's convert_silva_headers.py) without hardcoding an absolute,
        # install-specific path in the manifest -- pipelines.get_pipeline
        # already stamps "_dir" onto every loaded manifest at discovery time.
        pipeline_dir = pipelines.get_pipeline(pid).get("_dir", "")
        post_cmd = (opt.get("post_cmd", "").replace("{dest_dir}", dest_dir).replace("{pipeline_dir}", pipeline_dir))
        if post_cmd:
            await send({"type": "log", "text": f"Running: {post_cmd}\n"})
            await run_cmd(post_cmd)
    except BaseException:
        _cleanup_partial()
        raise

    # Save path
    databases = pipelines.get_pipeline(pid).get("databases", {})
    db = databases.get(db_key, {})
    if db.get("setting_key"):
        save_settings({db["setting_key"]: dest_dir})
        record_download_choice(db["setting_key"], opt_id)

    return dest_dir


# A database download's lifetime is owned by its background task, not by any
# particular websocket connection -- navigating away from the Databases screen
# (or losing the connection) must not interrupt the download. Progress/log
# events aren't logged to disk like pipeline runs (a big database emits one
# "progress" event per megabyte, which would make a full on-disk replay huge)
# -- instead only the latest progress snapshot plus the (few, milestone-level)
# log lines are kept in memory, which is enough for a (re)connecting socket to
# catch up. Keyed by "<pid>:<db_key>" since the same db_key can in principle
# belong to more than one pipeline.
download_tasks: dict = {}        # key -> asyncio.Task running _download_task
download_subscribers: dict = {}  # key -> list[asyncio.Queue] of attached viewers
download_log: dict = {}          # key -> list of non-progress events so far (log/done/error)
download_progress: dict = {}     # key -> latest "progress" event, if any
download_status: dict = {}       # key -> "running" | "done" | "error"


async def _emit_download(key: str, event: dict):
    if event.get("type") == "progress":
        download_progress[key] = event
    else:
        download_log.setdefault(key, []).append(event)
    for q in list(download_subscribers.get(key, [])):
        q.put_nowait(event)


async def _download_task(key: str, pid: str, db_key: str, opt_id: str, dest_dir: str):
    async def send(event: dict):
        await _emit_download(key, event)

    try:
        path = await _download_database(pid, db_key, opt_id, dest_dir, send)
        download_status[key] = "done"
        await _emit_download(key, {"type": "done", "path": path})
    except asyncio.CancelledError:
        # Explicit /cancel -- that route already set status/emitted "cancelled"
        # and popped download_tasks before calling task.cancel(), so there's
        # nothing left to report here. Must not fall into `except Exception`
        # below (CancelledError doesn't inherit from it on py>=3.8 anyway, but
        # spelled out since silently swallowing it would also stop it from
        # actually propagating and ending the task).
        raise
    except Exception as e:
        download_status[key] = "error"
        await _emit_download(key, {"type": "error", "text": str(e)})
    finally:
        download_tasks.pop(key, None)


async def _cancel_download(key: str) -> bool:
    """Actually stops a download, as opposed to a client merely closing its
    websocket -- since the task's lifetime is intentionally independent of
    any one connection (see database_download_ws), closing the socket alone
    (what the old Cancelar button did before this existed) does NOT stop it;
    the task keeps running, and can then get silently latched onto by a
    *later* download attempt for the same db (whatever option/dest_dir that
    later attempt asked for is ignored, since database_download_ws only
    starts a fresh task when none is already running for the key) -- from
    the user's side that looks like clicking Cancelar did nothing, then
    picking a different option and downloading again mysteriously fetches
    the wrong one. Any partial file already on disk is left as-is, same as
    an interrupted/failed download already did before this existed.
    """
    task = download_tasks.pop(key, None)
    if task and not task.done():
        task.cancel()
    was_running = download_status.get(key) == "running"
    download_status[key] = "cancelled"
    await _emit_download(key, {"type": "cancelled"})
    return was_running


@app.post("/api/pipelines/{pid}/databases/{db_key}/download/cancel")
async def cancel_database_download(pid: str, db_key: str):
    key = f"{pid}:{db_key}"
    cancelled = await _cancel_download(key)
    return {"cancelled": cancelled}


@app.websocket("/ws/pipelines/{pid}/databases/download")
async def database_download_ws(websocket: WebSocket, pid: str):
    await websocket.accept()
    try:
        msg = await websocket.receive_json()
    except WebSocketDisconnect:
        return

    db_key = msg.get("db_key")
    key = f"{pid}:{db_key}"

    # A fresh "start" message always wins over whatever's already running for
    # this key (if anything) -- the frontend only ever sends one when the user
    # explicitly picks an option and presses Baixar, never as a passive
    # "just reconnect me to watch" (that happens for free: navigating back to
    # the Databases screen re-reads accumulated state from the app's
    # in-memory provider, no new socket involved). So a task already present
    # here means a previous attempt was never properly cancelled -- honor the
    # new option_id/dest_dir instead of silently reattaching to the stale one.
    if key in download_tasks:
        await _cancel_download(key)

    opt_id   = msg.get("option_id")
    dest_dir = msg.get("dest_dir", "")
    download_log[key] = [{"type": "log", "text": "Connected.\n"}]
    download_progress.pop(key, None)
    download_status[key] = "running"
    download_tasks[key] = asyncio.create_task(_download_task(key, pid, db_key, opt_id, dest_dir))

    # Snapshot the backlog (events so far + latest progress) and subscribe to
    # live events in the same breath -- no `await` in between the two, so
    # nothing the task emits can fall in a gap between "what we're about to
    # replay" and "what our queue starts collecting". Matters here more than
    # it would look: create_task above only *schedules* the download, it
    # doesn't run any of it until this coroutine's next await -- so on a
    # fresh start, snapshotting-then-replaying-then-subscribing (the naive
    # order) would race the task's very first emitted log line into replaying
    # nothing and the queue catching it late, dropping it outright.
    backlog = list(download_log.get(key, []))
    progress = download_progress.get(key)
    status = download_status.get(key)
    q: asyncio.Queue = asyncio.Queue()
    download_subscribers.setdefault(key, []).append(q)

    try:
        for event in backlog:
            await websocket.send_json(event)
        if progress and status == "running":
            await websocket.send_json(progress)
    except WebSocketDisconnect:
        download_subscribers.get(key, []).remove(q)
        return

    if status != "running":
        download_subscribers.get(key, []).remove(q)
        return

    # Stream live events until the download finishes or this socket
    # disconnects -- disconnecting here (navigating away) only drops this
    # viewer, the task above keeps running regardless (see _download_task).
    try:
        while True:
            event = await q.get()
            await websocket.send_json(event)
            if event.get("type") in ("done", "error", "cancelled"):
                break
    except WebSocketDisconnect:
        pass
    finally:
        download_subscribers.get(key, []).remove(q)


# "Download all missing databases" is a batch, but it gets the same detached
# lifetime as a single download (see _download_task): the loop is owned by a
# background task keyed by pipeline id, not by the websocket that started it, so
# closing the progress dialog / a transient socket drop / navigating away no
# longer aborts the remaining downloads. A (re)connecting socket replays the
# milestone-level log + per-db progress snapshot then streams live, exactly like
# database_download_ws. Only one batch per pipeline runs at a time.
download_all_tasks: dict = {}        # pid -> asyncio.Task running _download_all_task
download_all_subscribers: dict = {}  # pid -> list[asyncio.Queue] of attached viewers
download_all_log: dict = {}          # pid -> list of non-progress events (log/db_*/done/error)
download_all_progress: dict = {}     # pid -> {db_key: latest "progress" event}
download_all_status: dict = {}       # pid -> "running" | "done" | "error" | "cancelled"


async def _emit_download_all(pid: str, event: dict):
    if event.get("type") == "progress":
        download_all_progress.setdefault(pid, {})[event.get("db_key", "")] = event
    else:
        download_all_log.setdefault(pid, []).append(event)
    for q in list(download_all_subscribers.get(pid, [])):
        q.put_nowait(event)


async def _download_all_task(batch_id: str, base_dir: str, chosen_options: dict, selected=None):
    """Downloads + installs databases not yet detected/configured, one after
    another, into '<base_dir>/<source_key>'. Works at the Hub level: it iterates
    the cross-pipeline, setting_key-deduped list (get_all_databases_status) and
    routes each database's download through *its own* source pipeline, so one
    batch can cover databases declared by different pipelines (the Databases
    screen is Hub-level too). `batch_id` keys the in-memory task/subscriber
    state only -- it is NOT a pipeline id. `chosen_options` maps source_key ->
    chosen option_id (falls back to the first option). `selected`, if given,
    restricts the batch to just those source_keys (the user picked a subset);
    None/empty means every not-yet-configured database. Databases with no
    automatic download option are skipped ('db_skipped')."""
    async def send(event: dict):
        await _emit_download_all(batch_id, event)

    try:
        os.makedirs(base_dir, exist_ok=True)
        save_settings({"db_base_dir": base_dir})

        candidates = [d for d in get_all_databases_status() if not d["configured"]]
        if selected:
            selected_set = set(selected)
            candidates = [d for d in candidates if d["source_key"] in selected_set]

        if not candidates:
            download_all_status[batch_id] = "done"
            await send({"type": "done", "downloaded": [], "skipped": []})
            return

        downloaded, skipped = [], []
        for db in candidates:
            key = db["source_key"]
            src_pid = db["source_pipeline_id"]
            name = db.get("name", key)
            opts = db.get("download_options", [])
            if not opts:
                await send({"type": "log", "text": f"⚠ {name}: sem opção de download automática, pulando.\n"})
                await send({"type": "db_skipped", "key": key, "name": name})
                skipped.append(key)
                continue

            opt_ids = {o["id"] for o in opts}
            opt_id = chosen_options.get(key)
            if opt_id not in opt_ids:
                opt_id = opts[0]["id"]

            dest_dir = os.path.join(base_dir, key)
            await send({"type": "log", "text": f"\n=== {name} ({opt_id}) ===\n"})
            await send({"type": "db_start", "key": key, "name": name})

            async def per_db_send(event: dict, key=key):
                await send({**event, "db_key": key})

            try:
                await _download_database(src_pid, key, opt_id, dest_dir, per_db_send)
                downloaded.append(key)
                await send({"type": "db_done", "key": key, "name": name})
            except asyncio.CancelledError:
                # Whole batch cancelled -- _download_database already cleaned up
                # this db's partial files on the way out; propagate so the task
                # ends instead of being reported as a per-db error and moving on.
                raise
            except Exception as e:
                await send({"type": "db_error", "key": key, "name": name, "text": str(e)})
                skipped.append(key)

        download_all_status[batch_id] = "done"
        await send({"type": "done", "downloaded": downloaded, "skipped": skipped})
    except asyncio.CancelledError:
        raise
    except Exception as e:
        download_all_status[batch_id] = "error"
        await send({"type": "error", "text": str(e)})
    finally:
        download_all_tasks.pop(batch_id, None)


async def _cancel_download_all(pid: str) -> bool:
    task = download_all_tasks.pop(pid, None)
    if task and not task.done():
        task.cancel()
    was_running = download_all_status.get(pid) == "running"
    download_all_status[pid] = "cancelled"
    await _emit_download_all(pid, {"type": "cancelled"})
    return was_running


@app.post("/api/pipelines/{pid}/databases/download-all/cancel")
async def cancel_database_download_all(pid: str):
    return {"cancelled": await _cancel_download_all(pid)}


@app.websocket("/ws/pipelines/{pid}/databases/download-all")
async def database_download_all_ws(websocket: WebSocket, pid: str):
    await websocket.accept()
    try:
        msg = await websocket.receive_json()
    except WebSocketDisconnect:
        return

    # A message carrying base_dir is a fresh start (cancels any batch already
    # running for this pipeline, same "fresh start wins" rule as single
    # downloads); a message without it is a passive reconnect that just
    # reattaches to whatever's already running/finished.
    base_dir = msg.get("base_dir", "")
    if base_dir:
        if pid in download_all_tasks:
            await _cancel_download_all(pid)
        download_all_log[pid] = [{"type": "log", "text": "Connected.\n"}]
        download_all_progress.pop(pid, None)
        download_all_status[pid] = "running"
        download_all_tasks[pid] = asyncio.create_task(
            _download_all_task(pid, base_dir, msg.get("options", {}), msg.get("selected")))

    # Snapshot backlog + subscribe with no await in between (see the same note
    # in database_download_ws for why the ordering matters on a fresh start).
    backlog = list(download_all_log.get(pid, []))
    progress_snapshot = list(download_all_progress.get(pid, {}).values())
    status = download_all_status.get(pid)
    q: asyncio.Queue = asyncio.Queue()
    download_all_subscribers.setdefault(pid, []).append(q)

    try:
        for event in backlog:
            await websocket.send_json(event)
        if status == "running":
            for ev in progress_snapshot:
                await websocket.send_json(ev)
    except WebSocketDisconnect:
        download_all_subscribers.get(pid, []).remove(q)
        return

    if status != "running":
        download_all_subscribers.get(pid, []).remove(q)
        return

    try:
        while True:
            event = await q.get()
            await websocket.send_json(event)
            if event.get("type") in ("done", "error", "cancelled"):
                break
    except WebSocketDisconnect:
        pass
    finally:
        download_all_subscribers.get(pid, []).remove(q)

# --- Samples & Config (per pipeline) ---

@app.get("/api/pipelines/{pid}/draft")
def get_launch_draft(pid: str):
    """Returns the last-saved Launch screen state (input dirs, output dir, RAM/cores,
    active tools, per-tool flag overrides) for this pipeline, or {} if none yet.
    Separate from config.yaml on purpose: config.yaml only exists once an output
    folder is chosen and Salvar/Iniciar was pressed, and doesn't round-trip cleanly
    back into per-tool UI state -- this is the raw form data instead."""
    return load_settings().get("launch_drafts", {}).get(pid, {})

@app.post("/api/pipelines/{pid}/draft")
def save_launch_draft(pid: str, data: dict):
    settings = load_settings()
    drafts = settings.get("launch_drafts", {})
    drafts[pid] = data
    save_settings({"launch_drafts": drafts})
    return {"ok": True}

@app.post("/api/pipelines/{pid}/samples/generate")
def samples_generate(pid: str, data: dict):
    # Same try/except-with-detail as config/generate below -- an unhandled
    # exception here previously surfaced as a bare "500 Internal Server Error"
    # with no message, which is how a real bug (build_samples always adding
    # a "reference" field that only SIGMA's manifest declares as a column)
    # went undiagnosed longer than it should have.
    try:
        output_dir = data.get("output_dir", "./results")
        config_dir = os.path.join(output_dir, "config")
        os.makedirs(config_dir, exist_ok=True)
        rows = config_engine.build_samples(pid, data)
        columns = pipelines.get_pipeline(pid).get("sample_sheet", {}).get("columns")
        tsv_path = os.path.join(config_dir, "samples.tsv")
        config_engine._write_tsv(rows, tsv_path, columns)
        return {"tsv_path": tsv_path, "tsv_content": config_engine._tsv_to_string(rows, columns), "samples": rows}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.post("/api/pipelines/{pid}/samples/preview")
def samples_preview(pid: str, data: dict):
    """Dry-run of build_samples -- no tsv/config written. Used by the Launch
    screen's per-sample reference validation to find samples that have reads
    but no matching reference file, without disturbing whatever's already
    saved on disk."""
    try:
        return {"samples": config_engine.build_samples(pid, data)}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.post("/api/pipelines/{pid}/config/generate")
def config_generate(pid: str, data: dict):
    try:
        return config_engine.generate_config(pid, data)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

# --- Pipeline execution (per pipeline) ---
# A run's lifetime is owned by its background task, not by any particular
# websocket connection -- navigating away from the Monitor screen (or losing
# the connection) must not kill the pipeline. Every /ws/pipelines/{pid}/run
# connection just replays this run's event log from disk (see
# pipeline_log_paths) then subscribes to live events; if nothing is running
# yet for that pid, it starts the background task first.
pipeline_processes: dict = {}    # pid -> asyncio.subprocess.Process (present while running)
pipeline_tasks: dict = {}        # pid -> asyncio.Task running _run_pipeline_task (keeps it alive)
pipeline_log_paths: dict = {}    # pid -> current/last run's event-log file path (JSONL), for replay
pipeline_subscribers: dict = {}  # pid -> list[asyncio.Queue] of currently-attached viewers
pipeline_finished: dict = {}     # pid -> bool
pipeline_stop_requested: dict = {}  # pid -> True if /stop landed before a process existed to kill
pipeline_current_run: dict = {}  # pid -> runs_store run id, for /stop and the Results page


def _kill_process_group(proc):
    """Terminates the whole process tree, not just the top-level PID -- snakemake
    (and `conda run` wrapping it) spawn further worker subprocesses that a plain
    proc.terminate() wouldn't reach, leaving them running after 'stop'."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        pass


def _subprocess_env() -> dict:
    """Environment for every subprocess this backend spawns and lets run
    scripts of its own (Snakemake, and now the Plots tab's Rscript jobs) -- generic despite the historical name, kept as one shared helper rather than
    per-subsystem copies.

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


# Conda envs are content-addressed by Snakemake, so one shared prefix lets every
# run (and every pipeline) reuse an env it already built instead of rebuilding
# it under each output_dir -- DEFINE's set alone is ~5.5 GB, which would
# otherwise be paid again for every single run.
CONDA_ENVS_DIR = os.path.expanduser("~/.omniomics/conda_envs")


def _parse_snk_line(text: str, state: dict) -> list:
    """
    Parse one line of Snakemake stdout and return any structured events.
    state is a mutable dict shared across calls (accumulates rule block fields).
    """
    events = []
    s = text.rstrip()

    # Any non-indented, non-empty line flushes a pending block
    if s and not s[0].isspace:
        blk = state.get("blk")
        if blk and blk.get("jobid") is not None:
            events.append({
                "type": "job_error" if blk["kind"] == "error" else "job_start",
                "jobid": blk["jobid"],
                "rule":  blk["rule"],
                "sample": blk.get("sample"),
            })
        state["blk"] = None

    # New rule block
    m = re.match(r'^(?:local)?rule (\w+):', s)
    if m:
        state["blk"] = {"kind": "rule", "rule": m.group(1), "sample": None, "jobid": None}
        return events

    # Error block
    m = re.match(r'^Error in rule (\w+):', s)
    if m:
        state["blk"] = {"kind": "error", "rule": m.group(1), "sample": None, "jobid": None}
        return events

    # Fields inside a block
    blk = state.get("blk")
    if blk:
        m = re.match(r'\s+jobid:\s*(\d+)', s)
        if m:
            blk["jobid"] = int(m.group(1))
        m = re.match(r'\s+wildcards:\s*(.+)', s)
        if m:
            for part in m.group(1).split(','):
                part = part.strip()
                if '=' in part:
                    k, v = part.split('=', 1)
                    if k.strip() == 'sample':
                        blk['sample'] = v.strip()

    # Finished job
    m = re.match(r'Finished job (\d+)\.', s)
    if m:
        events.append({"type": "job_done", "jobid": int(m.group(1))})

    # Overall progress
    m = re.match(r'(\d+) of (\d+) steps \((\d+)%\) done', s)
    if m:
        events.append({
            "type": "progress",
            "done": int(m.group(1)),
            "total": int(m.group(2)),
            "pct": int(m.group(3)),
        })

    return events


async def _emit(pid: str, event: dict):
    """Broadcasts to live viewers and appends to this run's on-disk event log
    (JSON Lines) -- events used to also pile up in an in-memory list for
    replay-on-reconnect, kept for as long as the process stayed up regardless
    of how many runs happened in the meantime. Disk is the source of truth
    now (see pipeline_log_paths); nothing is retained in memory past the
    currently-attached subscriber queues."""
    log_path = pipeline_log_paths.get(pid)
    if log_path:
        try:
            async with aiofiles.open(log_path, "a") as f:
                await f.write(json.dumps(event) + "\n")
        except OSError:
            pass  # a run's own log is best-effort -- must never block live streaming
    for q in list(pipeline_subscribers.get(pid, [])):
        q.put_nowait(event)


async def _run_pipeline_task(pid: str, cmd: list, pipeline_root: str, run_id: str):
    """Owns the subprocess for a run's whole lifetime, independent of any
    websocket. Keeps draining stdout (so the child never blocks on a full pipe)
    and broadcasting events even while zero viewers are attached.

    cwd stays the pipeline's own installed directory -- Snakemake auto-discovers
    the Snakefile from cwd (or workflow/Snakefile under it) with no override, so
    changing this breaks the run entirely ("No Snakefile found"). Where
    "results/..." and "logs/..." actually land is controlled separately, via
    `--directory=<output_dir>` in cmd (see pipeline_ws) -- Snakemake's own flag
    for "resolve relative output paths against this instead of cwd".
    """
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=pipeline_root,
        env=_subprocess_env(),  # keep the backend's own venv out of the rules' PATH
        start_new_session=True,  # own process group -> stop/shutdown can kill the whole tree
        limit=1024 * 1024 * 16,  # conda/mamba progress bars redraw via \r with no \n for a
                                  # long time during downloads/extraction -- asyncio treats
                                  # that whole stretch as one "line", and the default 64KB
                                  # StreamReader limit was small enough to blow past during a
                                  # real run, raising LimitOverrunError with nothing catching
                                  # it below (see the except clause: that used to kill this
                                  # task silently -- the process would die from /stop but the
                                  # "done" event never went out, so the Monitor screen hung on
                                  # "Interrompendo..." forever).
    )
    pipeline_processes[pid] = proc
    exit_code = None
    try:
        parser_state = {}
        async for raw_line in proc.stdout:
            text = clean_output(raw_line)
            if not text:
                continue
            await _emit(pid, {"type": "log", "text": text})
            for event in _parse_snk_line(text, parser_state):
                await _emit(pid, event)
        await proc.wait()
        exit_code = proc.returncode
    except Exception as e:
        # Whatever went wrong reading the process's output, the run itself may
        # still be alive -- make sure it isn't left behind, and always fall
        # through to emitting "done" so any attached viewer doesn't hang forever.
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        await proc.wait()
        exit_code = proc.returncode
        await _emit(pid, {"type": "log", "text": f"[erro interno monitorando a execução: {e}]\n"})
    finally:
        pipeline_finished[pid] = True
        # Don't clobber a status /stop already set to "stopped" -- SIGTERM makes
        # the exit code negative, which would otherwise read as "error" here.
        current = next((r for r in runs_store.list_runs() if r["id"] == run_id), None)
        if not current or current.get("status") != "stopped":
            runs_store.update_run(run_id, status="done" if exit_code == 0 else "error",
                                   exit_code=exit_code, finished_at=time.time())
            current = next((r for r in runs_store.list_runs() if r["id"] == run_id), None)

        # Provenance/reproducibility report -- written even for a stopped/failed
        # run, since knowing exactly what *was* configured is still useful.
        # Emitted before "done" (not after) so a live viewer still sees the log
        # line -- the subscriber loop below stops reading as soon as "done"
        # arrives, so anything emitted afterward would only reach a *future*
        # reconnect via replay, not whoever's watching right now.
        if current:
            try:
                report_path = run_report.write_report(pid, current, current["config_path"], current["output_dir"])
                if report_path:
                    runs_store.update_run(run_id, report_path=report_path)
                    await _emit(pid, {"type": "log", "text": f"Run report written to {report_path}\n"})
            except Exception as e:
                await _emit(pid, {"type": "log", "text": f"[could not write run report: {e}]\n"})

        await _emit(pid, {"type": "done", "code": exit_code})

        pipeline_processes.pop(pid, None)
        pipeline_tasks.pop(pid, None)
        pipeline_current_run.pop(pid, None)


@app.websocket("/ws/pipelines/{pid}/run")
async def pipeline_ws(websocket: WebSocket, pid: str):
    await websocket.accept()
    try:
        msg = await websocket.receive_json()
    except WebSocketDisconnect:
        return

    already_running = pid in pipeline_processes and pipeline_processes[pid].returncode is None
    if not already_running:
        # Clear any stop request left over from an earlier, unrelated click --
        # see the check right before the real run launches below, and
        # stop_pipeline's comment for why this flag exists at all.
        pipeline_stop_requested[pid] = False

        config_path   = msg.get("config_path")
        cores         = msg.get("cores", 4)
        omit_from     = msg.get("omit_from", [])
        pipeline_name = msg.get("pipeline_name", pid)
        pipeline_root = pipelines.pipeline_dir(pid)
        # config_path is always "<output_dir>/config/config.yaml" (see
        # config_engine.generate_config) -- two dirnames up recovers the
        # output folder the user actually picked, which results/logs should
        # be written into (via --directory below) and what the Results page
        # points its file browser at.
        output_dir = os.path.dirname(os.path.dirname(config_path))

        # Resolve snakemake: system PATH first, then the conda env's binary directly.
        # Deliberately NOT `conda run -n snakemake snakemake` here -- conda run
        # doesn't reliably forward SIGTERM to the process it wraps, which meant
        # /stop (and _kill_process_group) only killed the `conda run` shell and
        # left the actual Snakemake run orphaned and still going. Resolving the
        # env's own snakemake binary makes our subprocess the real thing, so
        # process-group kill actually reaches it and everything it spawns.
        snakemake_bin = shutil.which("snakemake")
        conda = None
        if not snakemake_bin:
            from settings_store import load_settings
            settings = load_settings()
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

        os.makedirs(CONDA_ENVS_DIR, exist_ok=True)
        cmd += [
            "--use-conda", "--conda-frontend", "conda",
            f"--conda-prefix={CONDA_ENVS_DIR}",
            f"--cores={cores}",
            f"--configfile={config_path}",
            f"--directory={output_dir}",
        ]
        # Disabled tools: skip their rule(s) and everything downstream of them
        # in Snakemake's own DAG, rather than us reimplementing the cascade.
        if omit_from:
            cmd += ["--omit-from", *omit_from]

        # A run interrupted before Snakemake could clean up after itself (via
        # /stop, a crash, or the app closing mid-run) leaves a stale lock in
        # <output_dir>/.snakemake/locks/, which fails the *next* run with
        # "Directory cannot be locked" until someone runs --unlock manually.
        # Do it preemptively every time -- instant and harmless when nothing
        # is actually locked.
        if snakemake_bin:
            unlock_proc = await asyncio.create_subprocess_exec(
                snakemake_bin, "--unlock", f"--directory={output_dir}", f"--configfile={config_path}",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=pipeline_root,
                env=_subprocess_env(),
            )
            try:
                await asyncio.wait_for(unlock_proc.communicate(), timeout=30)
            except asyncio.TimeoutError:
                unlock_proc.kill()

        # Parar clicked before the real process even existed (still resolving
        # the binary / running --unlock above) -- pipeline_processes has
        # nothing to kill at that point, so stop_pipeline could only record
        # the request, not act on it. Honor it now instead of launching the
        # run anyway, which otherwise left the Monitor screen stuck forever on
        # "Interrompendo..." (it already knows the user asked to stop, but
        # never gets a 'done' because the run just... starts and keeps going).
        if pipeline_stop_requested.get(pid):
            pipeline_stop_requested.pop(pid, None)
            await websocket.send_json({"type": "log", "text": "Interrompido antes de iniciar (solicitado pelo usuário).\n"})
            await websocket.send_json({"type": "done", "code": -15})
            return

        # Event log lives next to the run's own results/logs, not in memory --
        # see _emit and pipeline_log_paths. A fresh file per run (not
        # appended-to across runs) so replay-on-connect for *this* run never
        # shows a previous run's tail.
        log_dir = os.path.join(output_dir, "logs")
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(log_dir, "omniomics_events.jsonl")
        open(log_path, "w").close()
        pipeline_log_paths[pid] = log_path

        pipeline_finished[pid] = False
        pipeline_subscribers.setdefault(pid, [])
        run = runs_store.add_run(pid, pipeline_name, output_dir, config_path, cores)
        pipeline_current_run[pid] = run["id"]
        await _emit(pid, {"type": "log", "text": f"Comando: {' '.join(cmd)}\n\n"})
        # Tells the client which runs_store history entry this live session
        # corresponds to, so e.g. deleting it from the Results page can clear
        # the "last run" banner instead of leaving it pointing at nothing.
        await _emit(pid, {"type": "run_id", "id": run["id"]})
        pipeline_tasks[pid] = asyncio.create_task(_run_pipeline_task(pid, cmd, pipeline_root, run["id"]))

    # Attach as a viewer: replay everything so far from this run's on-disk
    # event log, then stream live events until the run finishes or this
    # particular socket disconnects. Disconnecting here (e.g. the user
    # navigates back) only drops this viewer -- see _run_pipeline_task.
    log_path = pipeline_log_paths.get(pid)
    if log_path and os.path.isfile(log_path):
        async with aiofiles.open(log_path, "r") as f:
            async for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                try:
                    await websocket.send_json(event)
                except WebSocketDisconnect:
                    return
    if pipeline_finished.get(pid):
        return

    q: asyncio.Queue = asyncio.Queue()
    pipeline_subscribers.setdefault(pid, []).append(q)
    try:
        while True:
            event = await q.get()
            await websocket.send_json(event)
            if event.get("type") == "done":
                break
    except WebSocketDisconnect:
        pass
    finally:
        pipeline_subscribers.get(pid, []).remove(q)

@app.post("/api/pipelines/{pid}/stop")
async def stop_pipeline(pid: str):
    proc = pipeline_processes.get(pid)
    if proc and proc.returncode is None:
        run_id = pipeline_current_run.get(pid)
        if run_id:
            runs_store.update_run(run_id, status="stopped", finished_at=time.time())
        _kill_process_group(proc)
        return {"stopped": True}
    # Nothing to kill yet -- most likely the request landed while still
    # resolving the snakemake binary or running the pre-flight --unlock, i.e.
    # before _run_pipeline_task ever got to set pipeline_processes[pid]. Record
    # it so pipeline_ws's startup sequence aborts instead of launching the run
    # anyway once it gets past that point (see the check there). Harmless if
    # nothing is actually starting -- the flag is cleared at the top of every
    # new start attempt regardless.
    pipeline_stop_requested[pid] = True
    return {"stopped": True}

@app.get("/api/runs")
def api_list_runs():
    """Backs the Results page's run list -- every run ever started, most recent
    first, across all pipelines. File browsing itself happens client-side
    (dart:io) directly against each run's output_dir, no endpoint needed for that."""
    return runs_store.list_runs()


# Never delete these, no matter what a run record's output_dir claims -- a
# corrupted/edited settings file or a future bug that lets output_dir end up
# empty/root should not turn into `rm -rf` on something real.
_UNDELETABLE_DIRS = {
    "/", "/root", "/home", "/etc", "/usr", "/bin", "/boot", "/var", "/opt", "/tmp",
    os.path.realpath(os.path.expanduser("~")),
}


def _safe_to_delete(path: str) -> bool:
    if not path:
        return False
    resolved = os.path.realpath(path)
    if resolved in _UNDELETABLE_DIRS:
        return False
    # Require some real depth under the filesystem root -- rejects things
    # like "/home" or "/mnt" that survived the explicit blocklist above.
    if len([p for p in resolved.split(os.sep) if p]) < 2:
        return False
    return True


@app.post("/api/runs/delete")
def delete_runs(data: dict):
    """Deletes the given runs' history entries, and their output folders on
    disk *only* when safe to do so:
      - a run still in progress is never touched (stop it first)
      - the target path goes through _safe_to_delete's guardrails
      - users commonly re-run into the same output_dir repeatedly (e.g. always
        "run01"), so several history records can point at one folder. Deleting
        some but not all of those records must NOT delete the shared folder -- that would silently break the history entries left behind, which is
        exactly what happened before this comment existed (see: "apagar uma
        run apagou todas"). The folder is only actually removed once *every*
        record referencing it is included in this same request.
    The frontend is expected to have already confirmed this with the user.
    """
    requested_ids = set(data.get("run_ids", []))
    if not requested_ids:
        return {"deleted": [], "blocked_active": [], "failed_dirs": []}

    all_runs = runs_store.list_runs()
    by_id = {r["id"]: r for r in all_runs}

    active_run_ids = set(pipeline_current_run.values())
    blocked_active = sorted(requested_ids & active_run_ids)
    requested_ids = {rid for rid in requested_ids if rid in by_id and rid not in active_run_ids}

    # Every run (not just the requested ones) grouped by output_dir, so we can
    # tell whether a folder still has other history entries pointing at it.
    refs_by_dir: dict[str, set] = {}
    for r in all_runs:
        d = r.get("output_dir")
        if d:
            refs_by_dir.setdefault(d, set).add(r["id"])

    ids_removed = set()
    dirs_to_delete = set()
    for rid in requested_ids:
        d = by_id[rid].get("output_dir")
        if not d:
            ids_removed.add(rid)  # nothing on disk tied to this record
        elif refs_by_dir[d] <= requested_ids:
            dirs_to_delete.add(d)  # this request covers *every* reference -- safe to remove
        else:
            ids_removed.add(rid)  # another surviving record still needs this folder

    deleted_dirs, failed_dirs = [], []
    for d in dirs_to_delete:
        if not _safe_to_delete(d):
            failed_dirs.append(d)
            continue
        try:
            if os.path.isdir(d):
                shutil.rmtree(d)
            deleted_dirs.append(d)
        except Exception:
            failed_dirs.append(d)

    for d in deleted_dirs:
        ids_removed |= refs_by_dir[d]

    runs_store.remove_runs(ids_removed)
    return {"deleted": sorted(ids_removed), "blocked_active": blocked_active, "failed_dirs": failed_dirs}


@app.post("/api/runs/{run_id}/rename")
def rename_run(run_id: str, data: dict):
    """The auto-generated name (see runs_store.generate_run_name) is only ever
    a display label -- deletion and every other lookup key off the run's own
    id, so renaming (including to something duplicated) can't cause a run to
    be confused with another one."""
    name = (data.get("name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="Name cannot be empty.")
    runs_store.update_run(run_id, name=name)
    return {"ok": True}

# --- Plots tab ---
#
# One R subprocess job type, reused for both "run an analysis" and "export the
# final file" (see _run_plot_task) -- unlike pipeline runs there's no DAG to
# parse, just a log stream and a done/error outcome, so this is much closer to
# _download_task's shape than pipeline_ws's. Keyed by the plot run's own id
# (fresh per POST /run, unlike pipeline_processes which is keyed by pipeline
# id and reused across runs) since a user can have several analyses running
# at once across different runs/pipelines.

plot_processes: dict = {}    # run_id -> asyncio.subprocess.Process (present while running)
plot_tasks: dict = {}        # run_id -> asyncio.Task running _run_plot_task (keeps it alive)
plot_log_paths: dict = {}    # run_id -> event-log file path (JSONL), for replay
plot_subscribers: dict = {}  # run_id -> list[asyncio.Queue] of currently-attached viewers
plot_finished: dict = {}     # run_id -> bool

# One entry per real input_shape value a plots/manifest.yaml analysis can
# declare -- generalized from a two-way phyloseq/count_matrix ternary
# so a future shape
# (e.g. SIGMA's isolate-summary one) is a new dict entry, not another
# branch to remember to update in two places. loader_script/rds_filename
# are used by /api/plots/load (builds the cached object once); rds_flag is
# used by /api/plots/{analysis_id}/run (tells each analysis script which
# CLI flag name to expect the cached object's path under -- matches
# whatever that script's own parse_cli_args reads).
INPUT_SHAPE_INFO = {
    "phyloseq": {"loader_script": "load_phyloseq.R", "rds_filename": "phyloseq.rds", "rds_flag": "--phyloseq_rds"},
    "count_matrix": {"loader_script": "load_count_matrix.R", "rds_filename": "count_matrix.rds", "rds_flag": "--count_matrix_rds"},
    "dogma_annotated": {"loader_script": "load_dogma_table.R", "rds_filename": "dogma_table.rds", "rds_flag": "--dogma_table_rds"},
    "sigma_genomes": {"loader_script": "load_sigma_table.R", "rds_filename": "sigma_table.rds", "rds_flag": "--sigma_table_rds"},
}


@app.get("/api/plots/analyses")
def api_list_analyses(pipeline_id: str | None = None):
    """All analyses, or (with ?pipeline_id=...) only those whose applies_to
    covers the pipeline that produced the run the user picked."""
    return plots_engine.get_analysis_list(pipeline_id)


@app.post("/api/plots/load")
async def load_plot_data(data: dict):
    """Builds the cached data object for a run ONCE, right after the user
    picks a run + metadata table -- every analysis against that run then
    reads the cached.rds this writes instead of re-parsing the raw tables
    per run. Which loader script actually runs depends on the parent run's
    pipeline (see INPUT_SHAPE_INFO / plots_engine.get_input_shape_for_pipeline):
    MAGMA-family (input_shape "phyloseq") builds a phyloseq object via
    load_phyloseq.R; DEFINE (input_shape "count_matrix") builds a plain
    counts+annotation+coldata bundle via load_count_matrix.R; DOGMA
    (input_shape "dogma_annotated") merges its ~10 separate per-tool tables
    into one long per-ORF table via load_dogma_table.R (see that script and
    plots/scripts/lib/build_dogma_table.R for why DOGMA needed a third
    shape -- its per-sample de novo assemblies share no gene-ID space
    across samples the way MAGMA's/DEFINE's references do). Also reports
    the metadata's
    real column names + each column's detected values either way, so the
    app can render group_var/reference_group as real dropdowns (see
    plots/manifest.yaml's "column"/"level" parameter types) instead of
    free-text boxes.

    Deliberately synchronous (unlike /run, which streams a log over a
    websocket) -- this is just TSV parsing, not a long-running statistical
    computation, so a plain awaited subprocess with a generous timeout is
    simpler than standing up the job/log-streaming machinery for it.
    """
    parent_run_id = data.get("parent_run_id")
    metadata_path = data.get("metadata_path")
    if not metadata_path:
        raise HTTPException(status_code=400, detail="metadata_path is required.")
    parent_run = next((r for r in runs_store.list_runs() if r["id"] == parent_run_id), None)
    if not parent_run:
        raise HTTPException(status_code=404, detail="Parent run not found.")

    settings = load_settings()
    rscript = plots_engine.resolve_rscript(settings.get("conda_path"))
    if not rscript:
        raise HTTPException(status_code=400, detail="Ambiente R (r-plots) não está instalado.")

    try:
        input_shape = plots_engine.get_input_shape_for_pipeline(parent_run["pipeline_id"])
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    shape_info = INPUT_SHAPE_INFO.get(input_shape, INPUT_SHAPE_INFO["phyloseq"])
    loader_script = shape_info["loader_script"]
    rds_filename = shape_info["rds_filename"]

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    out_dir = os.path.join(parent_run["output_dir"], "plots", "_loaded", timestamp)
    os.makedirs(out_dir, exist_ok=True)

    cmd = [rscript, os.path.join(plots_engine.PLOTS_DIR, "scripts", loader_script),
           "--input", os.path.join(parent_run["output_dir"], "results"),
           "--metadata", metadata_path,
           "--out_dir", out_dir,
           "--pipeline_id", parent_run["pipeline_id"]]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env=_subprocess_env(),
    )
    try:
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=120)
    except asyncio.TimeoutError:
        proc.kill()
        raise HTTPException(status_code=504, detail="Carregamento demorou demais (timeout).")

    if proc.returncode != 0:
        raise HTTPException(status_code=400, detail=clean_output(stdout))

    columns_path = os.path.join(out_dir, "metadata_columns.json")
    with open(columns_path, encoding="utf-8") as f:
        columns_data = json.load(f)

    return {
        "data_rds": os.path.join(out_dir, rds_filename),
        "columns": columns_data["columns"],
        "column_levels": columns_data["column_levels"],
        "tax_ranks": columns_data.get("tax_ranks", []),
        # DOGMA-only, not read by anything yet -- same "report it now, wire
        # a dynamic dropdown later if wanted" forward-compat pattern as
        # PRISM's has_tree; --annotation_column ships with a static choices
        # list in the manifest for this first pass instead (see
        # plots/manifest.yaml's dogma_functional_* entries).
        "annotation_columns": columns_data.get("annotation_columns", []),
        # SIGMA-only: real per-genome identifiers this run has, feeding
        # PlotParam's "sample" type (a real Flutter dropdown, not a
        # workaround) so a per-genome analysis can ask "which genome?" --
        # see plot_loaded_data.dart's own docstring for why this needed a
        # distinct mechanism from "column"/"level" (no metadata column to
        # depend on; the sample identity is a fixed fact about the run).
        "samples": columns_data.get("samples", []),
    }


async def _emit_plot(run_id: str, event: dict):
    log_path = plot_log_paths.get(run_id)
    if log_path:
        try:
            async with aiofiles.open(log_path, "a") as f:
                await f.write(json.dumps(event) + "\n")
        except OSError:
            pass  # a run's own log is best-effort -- must never block live streaming
    for q in list(plot_subscribers.get(run_id, [])):
        q.put_nowait(event)


async def _run_plot_task(run_id: str, cmd: list, cwd: str, plot_run_id: str | None = None):
    """Owns an R subprocess (compute or export step) for its whole lifetime,
    independent of any websocket -- same shape as _run_pipeline_task, minus
    the Snakemake-specific log parsing (an R script's stdout is just streamed
    as plain log lines). plot_run_id, when given, is the plot_runs_store
    record to update on completion -- absent for a one-off export job, which
    doesn't get its own history entry (see /api/plots/{run_id}/export)."""
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=cwd,
        env=_subprocess_env(),
        start_new_session=True,
    )
    plot_processes[run_id] = proc
    exit_code = None
    try:
        async for raw_line in proc.stdout:
            text = clean_output(raw_line)
            if not text:
                continue
            await _emit_plot(run_id, {"type": "log", "text": text})
        await proc.wait()
        exit_code = proc.returncode
    except Exception as e:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        await proc.wait()
        exit_code = proc.returncode
        await _emit_plot(run_id, {"type": "log", "text": f"[erro interno monitorando a execução: {e}]\n"})
    finally:
        plot_finished[run_id] = True
        if plot_run_id:
            plot_runs_store.update_plot_run(
                plot_run_id, status="done" if exit_code == 0 else "error", finished_at=time.time()
            )
        await _emit_plot(run_id, {"type": "done", "code": exit_code})
        plot_processes.pop(run_id, None)
        plot_tasks.pop(run_id, None)


@app.post("/api/plots/{analysis_id}/run")
async def run_plot_analysis(analysis_id: str, data: dict):
    """Starts an analysis's R compute step against a finished pipeline run's
    output. Writes data.json()/default_style.json()/<analysis>.rds under
    <parent_run.output_dir>/plots/<analysis_id>_<timestamp>/ -- lands inside
    the parent run's own folder so it shows up in the Results tab's existing
    file tree for free (see the Plots-tab architecture note in
    notes/Known Issues and Next Steps.md)."""
    try:
        plots_engine.get_analysis(analysis_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown analysis: {analysis_id}")

    parent_run_id = data.get("parent_run_id")
    parent_run = next((r for r in runs_store.list_runs() if r["id"] == parent_run_id), None)
    if not parent_run:
        raise HTTPException(status_code=404, detail="Parent run not found.")

    settings = load_settings()
    rscript = plots_engine.resolve_rscript(settings.get("conda_path"))
    if not rscript:
        raise HTTPException(status_code=400, detail="Ambiente R (r-plots) não está instalado.")

    data_rds = data.get("data_rds")
    if not data_rds:
        raise HTTPException(status_code=400, detail="data_rds is required -- call /api/plots/load first.")
    param_states = data.get("parameters", [])
    # Optional: the Plots tab's "Personalizar" panel writes its current
    # background/font/palette edits to a JSON file (own path, own lifetime --
    # not inside this run's own out_dir, since that doesn't exist yet at the
    # point the frontend needs to write it) and passes the path straight
    # through here. The R script reads it directly by absolute path, so no
    # copying/relocating is needed on the backend's side.
    style_json = data.get("style_json")

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    out_dir = os.path.join(parent_run["output_dir"], "plots", f"{analysis_id}_{timestamp}")
    os.makedirs(out_dir, exist_ok=True)

    run = plot_runs_store.add_plot_run(f"{analysis_id}_{timestamp}", parent_run_id, analysis_id)
    run_id = run["id"]

    # Every analysis reads the cached data object /api/plots/load already
    # built once for this run + metadata combination, instead of each one
    # re-parsing the raw tables itself. The CLI flag name matches what each
    # analysis script actually expects -- phyloseq-shaped analyses (MAGMA)
    # take --phyloseq_rds, count-matrix-shaped ones (DEFINE) take
    # --count_matrix_rds -- both scripts are handed the exact same file path
    # from the /load step either way, just under the name that reads right
    # for what the object actually is in each script.
    analysis_def = plots_engine.get_analysis(analysis_id)
    rds_flag = INPUT_SHAPE_INFO.get(analysis_def.get("input_shape", "phyloseq"), INPUT_SHAPE_INFO["phyloseq"])["rds_flag"]
    cmd = [rscript, plots_engine.script_path(analysis_id),
           rds_flag, data_rds,
           "--out_dir", out_dir]
    if style_json:
        cmd += ["--style_json", style_json]
    cmd += plots_engine.build_params_args(analysis_id, param_states)

    log_path = os.path.join(out_dir, "run_events.jsonl")
    open(log_path, "w").close()
    plot_log_paths[run_id] = log_path
    plot_finished[run_id] = False
    plot_subscribers.setdefault(run_id, [])

    await _emit_plot(run_id, {"type": "log", "text": f"Comando: {' '.join(cmd)}\n\n"})
    plot_tasks[run_id] = asyncio.create_task(_run_plot_task(run_id, cmd, out_dir, plot_run_id=run_id))
    return {"run_id": run_id, "out_dir": out_dir}


@app.websocket("/ws/plots/{run_id}")
async def plots_ws(websocket: WebSocket, run_id: str):
    """Replay-then-subscribe over a plot run's own event log, same pattern as
    pipeline_ws/database_download_ws -- reconnecting (e.g. navigating back to
    the Plots tab) always catches up from disk first, then streams live."""
    await websocket.accept()
    log_path = plot_log_paths.get(run_id)
    if log_path and os.path.isfile(log_path):
        async with aiofiles.open(log_path, "r") as f:
            async for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                try:
                    await websocket.send_json(event)
                except WebSocketDisconnect:
                    return
    if plot_finished.get(run_id):
        return

    q: asyncio.Queue = asyncio.Queue()
    plot_subscribers.setdefault(run_id, []).append(q)
    try:
        while True:
            event = await q.get()
            await websocket.send_json(event)
            if event.get("type") == "done":
                break
    except WebSocketDisconnect:
        pass
    finally:
        plot_subscribers.get(run_id, []).remove(q)


@app.post("/api/plots/{run_id}/export")
async def export_plot(run_id: str, data: dict):
    """Re-renders an already-computed analysis at publication quality via
    export/render_final.R: it reads the ggplot object the analysis saved next
    to its preview (plot_final.rds) and writes it again at the caller's chosen
    format, DPI and size. No statistics are recomputed. Styling is baked in at
    compute time (see plots/scripts/lib/style_io.R), so changing a palette
    means re-running the analysis, not re-exporting."""
    run = plot_runs_store.get_plot_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Plot run not found.")

    settings = load_settings()
    rscript = plots_engine.resolve_rscript(settings.get("conda_path"))
    if not rscript:
        raise HTTPException(status_code=400, detail="Ambiente R (r-plots) não está instalado.")

    run_dir = data.get("run_dir")
    if not run_dir or not os.path.isdir(run_dir):
        raise HTTPException(status_code=400, detail="run_dir inválido.")
    fmt = data.get("format", "tiff")
    dpi = data.get("dpi", 600)

    cmd = [rscript, os.path.join(plots_engine.PLOTS_DIR, "scripts", "export", "render_final.R"),
           "--run_dir", run_dir, "--format", fmt, "--dpi", str(dpi)]
    if data.get("width"):
        cmd += ["--width", str(data["width"])]
    if data.get("height"):
        cmd += ["--height", str(data["height"])]

    export_run_id = f"{run_id}_export_{int(time.time())}"
    log_path = os.path.join(run_dir, "export_events.jsonl")
    open(log_path, "w").close()
    plot_log_paths[export_run_id] = log_path
    plot_finished[export_run_id] = False
    plot_subscribers.setdefault(export_run_id, [])
    plot_tasks[export_run_id] = asyncio.create_task(_run_plot_task(export_run_id, cmd, run_dir))
    return {"run_id": export_run_id}


@app.get("/api/plots/runs")
def api_list_plot_runs(parent_run_id: str | None = None):
    return plot_runs_store.list_plot_runs(parent_run_id)


@app.get("/api/plots/r-env/status")
def api_r_env_status():
    settings = load_settings()
    return plots_engine.check_r_env(settings.get("conda_path"))


@app.post("/api/plots/r-env/install")
async def api_install_r_env():
    settings = load_settings()
    conda = settings.get("conda_path") or shutil.which("conda") or "conda"
    return await plots_engine.install_r_env(conda)


@app.on_event("shutdown")
async def _stop_all_pipelines_on_exit():
    """Only real app shutdown reaches here (see BackendLauncher / didChangeAppLifecycleState
    on the Flutter side) -- navigating within the app never triggers this."""
    for proc in pipeline_processes.values():
        if proc.returncode is None:
            _kill_process_group(proc)
    for proc in plot_processes.values():
        if proc.returncode is None:
            _kill_process_group(proc)
    if _dev_reload_observer is not None:
        _dev_reload_observer.stop()

# Dev-only: while actively editing pipeline.yaml manifests, re-scanning pipelines/
# on every change (instead of requiring a full app close/reopen) saves a lot of
# round-trips. Opt-in via OMNIOMICS_DEV_RELOAD so a packaged/production build
# (build.sh's PyInstaller bundle never sets this) behaves exactly as before --
# no watcher thread, no extra dependency surface, nothing to strip before release.
_dev_reload_observer = None
if os.environ.get("OMNIOMICS_DEV_RELOAD"):
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler

    class _ManifestReloadHandler(FileSystemEventHandler):
        def on_any_event(self, event):
            if event.src_path.endswith("pipeline.yaml"):
                pipelines.reload_registry()

    _dev_reload_observer = Observer()
    _dev_reload_observer.schedule(_ManifestReloadHandler(), pipelines.PIPELINES_DIR, recursive=True)
    _dev_reload_observer.start()

if __name__ == "__main__":
    # Port is chosen by the launcher (BackendLauncher) and passed in, so it can
    # fall back to a free port when 8765 is already taken (e.g. an orphaned
    # backend from a previous crash, or a second OmniOmics instance). Defaults
    # to 8765 when run standalone, so `python backend/main.py` + curl still works.
    port = int(os.environ.get("OMNIOMICS_PORT", "8765"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
