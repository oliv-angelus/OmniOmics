#!/usr/bin/env python3
"""One-time migration: give every `download_options` entry a `size_gb`.

    .venv/bin/python3 scripts/migrate_option_sizes.py [--dry-run]

Each option's size already exists, but only inside the human label --
`"label": "Standard-8 (5.5 GB)"`. Nothing can sum that, and the spread is not
marginal: Kraken2 declares `size_gb: 16` at the database level while its ten
options run from 5.5 GB to 75 GB, and GTDB-Tk's two releases are 85 and 100 GB.
The Databases screen's disk budget adds up whatever the user selected, so
without a structured field it would be wrong for anyone who picks something
other than the default.

The value is lifted from the label where the label states one, and left absent
otherwise -- the interface falls back to the database's own `size_gb`, so an
option without the field still renders. Only AMRFinderPlus's single option
lacks a size in its label.

The manifests are YAML files written in JSON flow style, and every one of them
is valid JSON (checked before this script was written), so it round-trips
through `json` with `indent=2` -- which reproduces the existing layout exactly
instead of reflowing the file the way a YAML dump would. Key order is preserved
and `size_gb` is inserted immediately after `label`, next to the number it came
from, where a reader can check it.

Idempotent: an option that already has `size_gb` is left alone.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# "(5.5 GB)", "~100 GB", "(~7.4 GB)", "(11 GB)" -- the forms actually in use.
_SIZE = re.compile(r'~?\s*([\d.,]+)\s*(GB|MB|TB)\b', re.I)


def parse_size_gb(label: str) -> float | None:
    m = _SIZE.search(label or '')
    if not m:
        return None
    value = float(m.group(1).replace(',', '.'))
    unit = m.group(2).upper()
    if unit == 'MB':
        return round(value / 1024, 3)
    if unit == 'TB':
        return round(value * 1024, 1)
    return value


def migrate(path: str, dry_run: bool) -> tuple[int, int]:
    with open(path) as f:
        manifest = json.load(f)

    added = skipped = 0
    for db in (manifest.get('databases') or {}).values():
        options = db.get('download_options') or []
        for idx, option in enumerate(options):
            if 'size_gb' in option:
                skipped += 1
                continue
            size = parse_size_gb(option.get('label'))
            if size is None:
                skipped += 1
                continue
            # Rebuild the dict so size_gb lands right after label rather than
            # at the end, keeping every other key in its original order.
            rebuilt = {}
            for key, value in option.items():
                rebuilt[key] = value
                if key == 'label':
                    rebuilt['size_gb'] = size
            options[idx] = rebuilt
            added += 1

    if added and not dry_run:
        with open(path, 'w') as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
            f.write('\n')
    return added, skipped


def main() -> int:
    dry_run = '--dry-run' in sys.argv
    total_added = total_skipped = 0
    for path in sorted(glob.glob(os.path.join(ROOT, 'pipelines', '*', 'pipeline.yaml'))):
        added, skipped = migrate(path, dry_run)
        total_added += added
        total_skipped += skipped
        print(f'  {os.path.basename(os.path.dirname(path)):8} +{added} size_gb, {skipped} skipped')

    print(f'\n{"would add" if dry_run else "added"} {total_added}, skipped {total_skipped}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
