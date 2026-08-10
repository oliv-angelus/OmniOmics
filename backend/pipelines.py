"""
Pipeline registry: discovers pipelines dynamically from pipelines/<id>/pipeline.yaml
manifests. Adding a new pipeline (genomics, transcriptomics,...) means dropping a new
folder under pipelines/ -- no backend or app code changes required.
"""
import os
import sys
import yaml

# PyInstaller freezes __file__ to point inside a temp extraction dir (sys._MEIPASS),
# not the real on-disk location -- pipelines/ ships alongside the binary and must be
# found relative to sys.executable instead when frozen, or dropping a new pipeline
# folder next to a packaged build would silently go undiscovered.
_here = os.path.dirname(sys.executable) if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__))
PIPELINES_DIR = os.path.normpath(os.path.join(_here, "..", "pipelines"))

_cache: dict | None = None


def _load_all() -> dict:
    global _cache
    if _cache is not None:
        return _cache

    registry = {}
    if os.path.isdir(PIPELINES_DIR):
        for entry in sorted(os.listdir(PIPELINES_DIR)):
            manifest_path = os.path.join(PIPELINES_DIR, entry, "pipeline.yaml")
            if not os.path.isfile(manifest_path):
                continue
            with open(manifest_path, encoding="utf-8") as f:
                manifest = yaml.safe_load(f)
            manifest["_dir"] = os.path.join(PIPELINES_DIR, entry)
            registry[manifest["id"]] = manifest

    _cache = registry
    return registry


def reload_registry() :
    """Drop the in-memory cache so the next call re-scans pipelines/ from disk."""
    global _cache
    _cache = None


def list_pipelines() -> list:
    """Summary list for the Hub screen."""
    return [
        {
            "id": pid,
            "name": m.get("name", pid),
            "description": m.get("description", ""),
            "category": m.get("category", ""),
            "icon": m.get("icon", ""),
            "tags": m.get("tags", []),
        }
        for pid, m in _load_all().items()
    ]


def get_pipeline(pipeline_id: str) -> dict:
    registry = _load_all()
    if pipeline_id not in registry:
        raise KeyError(f"Unknown pipeline: {pipeline_id}")
    return registry[pipeline_id]


def pipeline_dir(pipeline_id: str) -> str:
    return get_pipeline(pipeline_id)["_dir"]


def snakefile_path(pipeline_id: str) -> str:
    manifest = get_pipeline(pipeline_id)
    return os.path.join(manifest["_dir"], manifest.get("snakefile", "Snakefile"))
