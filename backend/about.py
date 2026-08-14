"""What the About screen shows: the app's own citation, and the citation index.

The screen used to tell the user to cite the app "using CITATION.cff" and to
consult docs/CITATIONS.md for the tools. Both files exist in the repository and
neither was installed by the .deb, so anyone who had not cloned the repo was
being pointed at files that were not on their machine. build.sh now ships both,
but the better fix is this one: the app already loads every manifest at startup,
and those manifests carry every citation. An index derived from them cannot
drift from what the app can actually run, whereas a hand-maintained markdown
file can and eventually does.
"""
import os
import sys

import yaml

import pipelines
from run_report import ReferenceCollector

_here = os.path.dirname(sys.executable) if getattr(sys, "frozen", False) \
    else os.path.dirname(os.path.abspath(__file__))
CITATION_PATH = os.path.normpath(os.path.join(_here, "..", "CITATION.cff"))

_cache: dict | None = None


def _read_citation_cff() -> dict:
    """The authored citation metadata, or {} if the file is not installed.

    This is the single source for the version string. It used to be a
    `static const version` in about_screen.dart with a comment asking that three
    places be updated together -- and they had already drifted (build.sh said
    0.0.1 while the other two said 0.0.1-alpha).
    """
    try:
        with open(CITATION_PATH) as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {}


def _author_name(cff: dict) -> str:
    authors = cff.get("authors") or []
    if not authors:
        return ""
    first = authors[0]
    given = (first.get("given-names") or "").strip()
    family = (first.get("family-names") or "").strip()
    return f"{family}, {given}".strip(", ")


def _citation_formats(cff: dict) -> dict:
    """BibTeX, APA and CFF, ready to paste.

    Generated here rather than in the interface so the three cannot disagree
    with each other or with the file, and so a user without the repository still
    gets something they can drop straight into a manuscript.
    """
    title = cff.get("title", "OmniOmics")
    version = cff.get("version", "")
    year = str(cff.get("date-released", ""))[:4]
    licence = cff.get("license", "")
    repo = cff.get("repository-code", "")
    authors = cff.get("authors") or [{}]
    given = (authors[0].get("given-names") or "").strip()
    family = (authors[0].get("family-names") or "").strip()
    orcid = authors[0].get("orcid", "")
    initials = " ".join(f"{p[0]}." for p in given.split() if p)

    bibtex = "\n".join([
        "@software{omniomics,",
        f"  author    = {{{family}, {given}}},",
        f"  title     = {{{title}}},",
        f"  year      = {{{year}}},",
        f"  version   = {{{version}}},",
        f"  license   = {{{licence}}},",
        f"  url       = {{{repo}}},",
        f"  orcid     = {{{orcid}}}",
        "}",
    ])
    apa = f"{family}, {initials} ({year}). {title} (Version {version}) [Computer software]. {repo}"

    try:
        with open(CITATION_PATH) as f:
            cff_text = f.read()
    except OSError:
        cff_text = ""

    return {"bibtex": bibtex, "apa": apa, "cff": cff_text}


def _references() -> list:
    """Every citation the app can require, across all installed pipelines.

    Each entry names the tool or database that needs it and the pipelines it
    appears in, so a reader can tell why a paper is on the list. Deduping uses
    the same ReferenceCollector as the per-run report, so the two agree on what
    counts as one reference.
    """
    collector = ReferenceCollector()
    meta: dict = {}  # dedup key -> {"for": set, "pipes": set, "kind": set}

    def record(citation: dict, owner: str, pid: str, kind: str) -> None:
        key = citation.get("doi") or citation.get("text")
        if not key:
            return
        collector.add(citation)
        entry = meta.setdefault(key, {"for": set(), "pipes": set(), "kind": set()})
        entry["for"].add(owner)
        entry["pipes"].add(pid)
        entry["kind"].add(kind)

    for summary in pipelines.list_pipelines():
        pid = summary["id"]
        manifest = pipelines.get_pipeline(pid)
        for tid, tool in (manifest.get("tools") or {}).items():
            for citation in tool.get("citation") or []:
                record(citation, tool.get("name", tid), pid, "tool")
        for dkey, db in (manifest.get("databases") or {}).items():
            citations = list(db.get("citation") or [])
            for by_option in (db.get("citation_by_option") or {}).values():
                citations += by_option or []
            for citation in citations:
                record(citation, db.get("name", dkey), pid, "database")

    out = []
    for i, citation in enumerate(collector.entries, start=1):
        key = citation.get("doi") or citation.get("text")
        info = meta.get(key, {"for": set(), "pipes": set(), "kind": set()})
        out.append({
            "n": i,
            "text": citation.get("text", ""),
            "doi": citation.get("doi"),
            "for": sorted(info["for"]),
            "pipelines": sorted(info["pipes"]),
            "kind": "database" if "database" in info["kind"] else "tool",
        })
    return out


def invalidate_cache() -> None:
    """Drop the cached index. Called by pipelines.reload_registry(), because the
    index is derived from the manifests -- without this, adding or editing a
    pipeline at runtime left /api/about serving the old registry's citations
    until the backend restarted."""
    global _cache
    _cache = None


def about_data() -> dict:
    global _cache
    if _cache is not None:
        return _cache

    cff = _read_citation_cff()
    references = _references()
    _cache = {
        "version": cff.get("version", ""),
        "title": cff.get("title", "OmniOmics"),
        "author": _author_name(cff),
        "license": cff.get("license", ""),
        "repository": cff.get("repository-code", ""),
        "orcid": ((cff.get("authors") or [{}])[0]).get("orcid", ""),
        "citation": _citation_formats(cff),
        "references": references,
        "reference_count": len(references),
        "doi_count": sum(1 for r in references if r["doi"]),
    }
    return _cache
