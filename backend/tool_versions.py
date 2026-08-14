"""
Resolves each tool's actual installed version for the run report, by reading
the *pinned* conda environment specs the pipeline itself declares (e.g.
workflow/envs/prodigal.yaml: "prodigal=2.6.3") rather than inspecting live
installed environments -- this pipeline pins exact versions in every env
file, so the declared pin already *is* the version conda installs; reading it
statically is simpler and doesn't require the run to have actually finished
creating every environment (e.g. a tool whose rule got skipped/cached).
"""
import os
import re
import yaml

import pipelines

_RULE_CONDA_RE = re.compile(r'^rule\s+(\w+)\s*:', re.M)
_CONDA_DIRECTIVE_RE = re.compile(r'conda:\s*"([^"]+)"')

_cache: dict = {}  # pipeline_id -> {rule_name: env_yaml_abspath}


def _rule_env_map(pipeline_id: str) -> dict:
    """rule_name -> absolute path of the envs/*.yaml it declares, built once
    per pipeline by scanning every workflow/rules/*.smk file."""
    if pipeline_id in _cache:
        return _cache[pipeline_id]

    root = pipelines.pipeline_dir(pipeline_id)
    rules_dir = os.path.join(root, "workflow", "rules")
    mapping = {}
    if os.path.isdir(rules_dir):
        for fname in sorted(os.listdir(rules_dir)):
            if not fname.endswith(".smk"):
                continue
            path = os.path.join(rules_dir, fname)
            with open(path) as f:
                text = f.read()
            # Walk rule blocks in order, pairing each with the first `conda:`
            # directive that appears before the next `rule` keyword.
            starts = [(m.start(), m.group(1)) for m in _RULE_CONDA_RE.finditer(text)]
            for i, (pos, rule_name) in enumerate(starts):
                end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
                block = text[pos:end]
                m = _CONDA_DIRECTIVE_RE.search(block)
                if m:
                    env_rel = m.group(1)  # e.g. "../envs/prodigal.yaml"
                    mapping[rule_name] = os.path.normpath(os.path.join(rules_dir, env_rel))

    _cache[pipeline_id] = mapping
    return mapping


def _pinned_packages(env_yaml_path: str) -> list:
    """[(name, version_or_None),...] for every pinned/unpinned dependency in
    one env yaml, skipping pip sub-blocks (those are a different ecosystem)."""
    try:
        with open(env_yaml_path) as f:
            spec = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return []
    packages = []
    for dep in spec.get("dependencies", []):
        if isinstance(dep, str):
            if "=" in dep:
                name, version = dep.split("=", 1)
                packages.append((name.strip(), version.strip().split("=")[0]))
            else:
                packages.append((dep.strip(), None))
    return packages


def tool_env_files(pipeline_id: str, tool_id: str, rule_names: list) -> list:
    """Every distinct env yaml path used by this tool's rule(s)."""
    rule_map = _rule_env_map(pipeline_id)
    seen = []
    for rule in rule_names:
        env_path = rule_map.get(rule)
        if env_path and env_path not in seen:
            seen.append(env_path)
    return seen


def primary_version(tool_id: str, env_paths: list) -> str | None:
    """Best-effort match of `tool_id` against the pinned packages across this
    tool's env file(s) -- e.g. tool_id "amrfinderplus" matching package
    "ncbi-amrfinderplus". Falls back to the first pinned package if nothing
    matches by name (some tools' primary binary has a different package name
    than the tool_id, e.g. "isescan" -> package "isescan" usually matches
    directly, but this covers the exceptions without hardcoding a table)."""
    all_pkgs = []
    for env_path in env_paths:
        all_pkgs.extend(_pinned_packages(env_path))
    if not all_pkgs:
        return None

    needle = tool_id.lower().replace("_", "").replace("-", "")
    for name, version in all_pkgs:
        norm = name.lower().replace("_", "").replace("-", "")
        if norm == needle or needle in norm or norm in needle:
            return version or "(unpinned)"

    first_name, first_version = all_pkgs[0]
    return f"{first_version} (as {first_name})" if first_version else f"(unpinned: {first_name})"


def all_packages(tool_id: str, env_paths: list) -> list:
    """Every pinned package across this tool's env file(s), for the detailed
    appendix table -- not just the guessed "primary" one."""
    all_pkgs = []
    for env_path in env_paths:
        all_pkgs.extend(_pinned_packages(env_path))
    return all_pkgs
