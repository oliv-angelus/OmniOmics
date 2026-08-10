"""
Single shared settings file for the whole app: conda path, snakemake state,
and per-database local paths. Global/shared across all pipelines on purpose --
reference databases (CheckM2, GTDB-Tk, etc.) are plausibly reused by future
pipelines (genomics, transcriptomics,...), so paths are not namespaced by
pipeline id.
"""
import os
import json
import tempfile

SETTINGS_FILE = os.path.expanduser("~/.omniomics.json")


def load_settings -> dict:
    if not os.path.exists(SETTINGS_FILE):
        return {}
    try:
        with open(SETTINGS_FILE) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("settings root is not a JSON object")
        return data
    except (json.JSONDecodeError, ValueError, OSError):
        # This one file holds conda path, every database path, and the whole
        # run history -- basically every screen calls load_settings on open,
        # so a corrupt file (crash/full-disk mid-write, manual edit gone wrong)
        # would otherwise 500 the entire app until someone hunts down and
        # deletes ~/.omniomics.json by hand. Instead, quarantine the bad file
        # (kept for forensics rather than silently overwritten) and start
        # clean, so the app always comes up.
        try:
            os.replace(SETTINGS_FILE, SETTINGS_FILE + ".corrupt")
        except OSError:
            pass
        return {}


def save_settings(updates: dict):
    settings = load_settings
    settings.update(updates)
    # Atomic write: dump to a temp file in the same directory, fsync, then
    # os.replace (atomic on POSIX) over the real file. A crash or full disk
    # mid-write can then only ever leave the *old* intact file or the new one
    # behind -- never a half-written, unparseable file, which would brick
    # load_settings on the next launch and lose the conda path, all database
    # paths, and the entire run history in one shot.
    dir_ = os.path.dirname(SETTINGS_FILE) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".omniomics.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(settings, f, indent=2)
            f.flush
            os.fsync(f.fileno)
        os.replace(tmp, SETTINGS_FILE)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
