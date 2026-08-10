"""
Generic tool-definitions engine. Replaces the old MAGMA-only tool_definitions.py:
reads a pipeline's `tools`/`categories` fields from its manifest instead of a
hardcoded Python dict, so the same code serves any pipeline in the registry.
"""
from pipelines import get_pipeline


def _tracks_for(rule_names: list) -> dict:
    """Splits a tool's rule_names into tracks by naming convention: rules ending
    in _sample run on per-sample contigs, rules ending in _mags run on
    dereplicated MAGs (see workflow/rules/07_annotation_mobilome.smk's own
    "two independent tracks" comment -- this mirrors that split). Tools like
    tiara (['tiara', 'filter_prokaryotes']) or bowtie2 (['bowtie2_index',
    'map_reads']) are multi-rule *chains* within a single track, not multiple
    tracks, so they correctly produce no tracks split here (both/neither
    suffix matches) and keep the single on/off toggle.
    """
    tracks: dict[str, list] = {}
    for rule in rule_names:
        if rule.endswith("_sample"):
            tracks.setdefault("sample", []).append(rule)
        elif rule.endswith("_mags"):
            tracks.setdefault("mags", []).append(rule)
    return tracks if len(tracks) >= 2 else {}


def get_tool_list(pipeline_id: str) -> list:
    """Returns tool definitions grouped by category, in the manifest's declared order."""
    manifest = get_pipeline(pipeline_id)
    tools = manifest.get("tools", {})
    categories = manifest.get("categories", [])

    grouped: dict[str, list] = {}
    for tool_id, tool in tools.items:
        cat = tool.get("category", "Other")
        grouped.setdefault(cat, []).append({
            "id": tool_id,
            **tool,
            "tracks": _tracks_for(tool.get("rule_names", [])),
        })

    result = []
    for cat in categories:
        if cat in grouped:
            result.append({"category": cat, "tools": grouped.pop(cat)})
    # Any category the manifest forgot to list still shows up, appended at the end.
    for cat, cat_tools in grouped.items:
        result.append({"category": cat, "tools": cat_tools})
    return result


def build_params_string(pipeline_id: str, tool_id: str, flag_states: list) -> str:
    """Assembles the CLI params string from a list of flag states."""
    manifest = get_pipeline(pipeline_id)
    tool = manifest.get("tools", {}).get(tool_id, {})
    flag_defs = {f["flag"]: f for f in tool.get("flags", [])}

    parts = []
    for state in flag_states:
        if not state.get("enabled"):
            continue
        flag = state["flag"]
        fdef = flag_defs.get(flag, {})
        ftype = fdef.get("type", "str")

        if ftype == "bool":
            parts.append(flag)
        else:
            val = state.get("value", "")
            if val == "" or val is None:
                val = fdef.get("default", "")
            if val != "" and val is not None:
                parts.append(f"{flag} {val}")

    return " ".join(parts)
