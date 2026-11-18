"""
Database download and install (decompress, extract, post command, VIBRANT
setup) for one manifest download option. Used by the Databases screen
(main.py) and by `omniomics db download` (cli.py).
"""
import asyncio
import gzip
import os
import re
import shutil

import aiofiles
import httpx

import pipelines
from conda_manager import check_conda
from databases_engine import get_download_option, save_settings, record_download_choice


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


def _conda_bin_dir() -> str | None:
    """Directory holding the conda executable, or None if conda is not found.

    Resolved once per caller and passed down, never called per tool:
    check_conda() shells out to `conda --version` *and* rewrites the settings
    file (conda_manager.py), so calling it once per lookup turned a single
    /api/setup/status into four subprocesses and four read-modify-write+fsync
    rewrites of ~/.omniomics.json -- widening the window for a lost update
    against any concurrent writer, runs_store.update_run included.
    """
    conda = check_conda()
    if conda["installed"] and conda["path"]:
        return os.path.dirname(conda["path"])
    return None


def _resolve_conda_tool(name: str, bin_dir: str | None) -> str | None:
    """Absolute path of a tool installed by _vibrant_tools_runner, or None.

    Looks inside conda's own bin directory *before* consulting PATH. The install
    runs `conda install` into the base env, so the binaries land next to the
    conda executable itself -- but that directory is only on PATH for a shell
    that ran `conda init`. Launched from the desktop entry the app inherits no
    such PATH, so a PATH-only check reported "not installed" for tools conda had
    just installed successfully, and the VIBRANT database setup then refused to
    run for the same reason.
    """
    if bin_dir:
        candidate = os.path.join(bin_dir, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return shutil.which(name)


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

    async def run_cmd(cmd: str, cwd: str = None, env: dict = None):
        """Run a shell command, streaming cleaned output through `send`."""
        proc = await asyncio.create_subprocess_shell(
            cmd, cwd=cwd, env=env,
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

        # Check dependencies. Resolved against conda's own bin directory rather
        # than PATH -- see _resolve_conda_tool: launched from the desktop entry
        # the backend inherits a PATH without conda on it, which used to make
        # this refuse to run for tools that were in fact installed. One lookup
        # of the bin dir for all three, since finding it is not free.
        conda_bin = _conda_bin_dir()
        for tool in ("wget", "hmmfetch", "hmmpress"):
            if not _resolve_conda_tool(tool, conda_bin):
                raise RuntimeError(f"'{tool}' not found. Install HMMER3 and wget first (e.g. conda install hmmer wget).")

        # VIBRANT_setup.py shells out to wget/hmmfetch/hmmpress by bare name, so
        # resolving them here is not enough -- the child process needs them on
        # its own PATH too.
        vibrant_env = dict(os.environ)
        if conda_bin:
            vibrant_env["PATH"] = conda_bin + os.pathsep + vibrant_env.get("PATH", "")

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
        rc = await run_cmd("python3 VIBRANT_setup.py", cwd=dest_dir, env=vibrant_env)
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
