"""Release notes for the Hub's news panel, read from docs/changelog.yaml.

A file in the repository rather than a remote feed, which was the deliberate
choice: the app has to work on a machine with no internet -- which is most of
the machines it is meant for -- and nothing about a user's install should leave
their computer to fetch news.

Lives in docs/ for one practical reason: build.sh stages docs/, and a data
directory that is not staged works perfectly in development and is simply
absent from the packaged build (see the comment on plots/ in build.sh, which
is the same trap). Same resolution rule as
pipelines.py -- relative to sys.executable when frozen.
"""
import os
import sys

import yaml

_here = os.path.dirname(sys.executable) if getattr(sys, "frozen", False) \
    else os.path.dirname(os.path.abspath(__file__))
CHANGELOG_PATH = os.path.normpath(os.path.join(_here, "..", "docs", "changelog.yaml"))

_cache: list | None = None


def list_entries() -> list:
    """Every release, newest first, as the file already orders them.

    A missing or malformed file yields an empty list rather than an error: the
    news panel is decoration around the real content of the Hub, and a release
    that forgot to ship it should not take the whole screen down with it.
    """
    global _cache
    if _cache is not None:
        return _cache

    try:
        with open(CHANGELOG_PATH) as f:
            data = yaml.safe_load(f) or []
    except (OSError, yaml.YAMLError):
        data = []

    if not isinstance(data, list):
        data = []

    entries = []
    for release in data:
        if not isinstance(release, dict):
            continue
        date = release.get("date")
        entries.append({
            "version": str(release.get("version", "")),
            # Not yet reflected in CITATION.cff, so the app must not present it
            # as its own version -- see the note at the top of changelog.yaml.
            "unreleased": bool(release.get("unreleased", False)),
            # A YAML date parses to datetime.date, which is not JSON-serialisable.
            "date": date.isoformat() if hasattr(date, "isoformat") else (date or ""),
            "entries": [e for e in (release.get("entries") or []) if isinstance(e, dict)],
        })

    _cache = entries
    return _cache
