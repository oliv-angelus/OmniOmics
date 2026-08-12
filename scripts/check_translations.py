#!/usr/bin/env python3
"""Checks the app's translation table for the three ways it can go wrong.

Run it before a release, or after touching anything user-facing:

    python3 scripts/check_translations.py

Exits non-zero if anything is wrong, so it can gate a build.

It exists because none of these failures announce themselves. `translate()`
falls back to returning the key itself when it is missing, so a forgotten
string shows up as a button labelled `confirm` in both languages -- which looks
deliberate enough that it survived several passes over the interface before a
mechanical check found it.

Three checks:

1. **Used but not defined.** A `ref.t('x')` with no 'x' in the table. This is
   the one that silently prints the key to the user.
2. **Defined in one language only.** English falls back to the Portuguese map
   for a missing key, so a half-translated string shows Portuguese text inside
   an otherwise English interface.
3. **Defined but never used.** Not an error -- some keys are held for screens
   under construction -- so it is reported, not failed on.

What it cannot check: strings written directly into a widget without going
through `ref.t()` at all. Those are found by reading, not by grepping, since a
literal in a Text() is indistinguishable from any other string. The known and
accepted exceptions are the pre-locale splash screen (deliberately bilingual in
one line), format names like FASTA and TIFF, and example sequences.
"""
import glob
import os
import re
import sys

APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app")
STRINGS = os.path.join(APP, "lib", "l10n", "app_strings.dart")


def defined_keys(text: str) -> set:
    return set(re.findall(r"^\s*'([a-zA-Z0-9_]+)':", text, re.M))


def main() -> int:
    src = open(STRINGS, encoding="utf-8").read()
    split = src.index("const _en")
    pt, en = defined_keys(src[:split]), defined_keys(src[split:])

    used = {}
    for path in glob.glob(os.path.join(APP, "lib", "**", "*.dart"), recursive=True):
        if path.endswith("app_strings.dart"):
            continue
        body = open(path, encoding="utf-8").read()
        for key in re.findall(r"\.t\(\s*'([a-zA-Z0-9_]+)'", body):
            used.setdefault(key, set()).add(os.path.relpath(path, APP))

    problems = 0

    missing = sorted(set(used) - pt)
    if missing:
        problems += len(missing)
        print(f"\n{len(missing)} key(s) used in the interface but not defined "
              f"-- these print the raw key to the user:")
        for k in missing:
            print(f"  {k:34} used in {', '.join(sorted(used[k]))}")

    only_pt, only_en = sorted(pt - en), sorted(en - pt)
    if only_pt or only_en:
        problems += len(only_pt) + len(only_en)
        print(f"\n{len(only_pt) + len(only_en)} key(s) defined in one language only:")
        for k in only_pt:
            print(f"  {k:34} missing from English (falls back to Portuguese text)")
        for k in only_en:
            print(f"  {k:34} missing from Portuguese")

    unused = sorted(pt - set(used))
    if unused:
        print(f"\n{len(unused)} key(s) defined but never used (not an error):")
        print("  " + ", ".join(unused))

    print(f"\npt: {len(pt)} keys | en: {len(en)} keys | used in UI: {len(used)}")
    if problems:
        print(f"FAIL: {problems} problem(s)")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
