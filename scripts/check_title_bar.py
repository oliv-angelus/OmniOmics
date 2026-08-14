#!/usr/bin/env python3
"""Asserts that with_title_bar fits its title on every layout it has to serve.

    .venv/bin/python3 scripts/check_title_bar.py --conda ~/miniforge3/bin/conda

Renders plots/scripts/tests/render_title_bar_cases.R and runs the clipping
check over the result. Exits non-zero if any title is clipped.

Why this exists separately from run_plots_suite.py: with_title_bar is shared by
43 analyses across all five pipelines, but only MAGMA has a demo run to exercise
it against, so the suite can only ever prove the change safe for one pipeline's
figures. The cases here stand in for the rest -- each is a shape of chrome that
changes how much width the bar actually gets (a legend, long y-axis labels, a
facet strip column, a patchwork input with no readable panel at all). They need
no run data, so this is the part of the check that can run anywhere.
"""
import argparse
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# backend/ modules import each other flatly ("import conda_manager"), so the
# package dir itself has to be on the path -- importing them as backend.* fails.
sys.path.insert(0, os.path.join(REPO, "backend"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import plots_engine  # noqa: E402
from check_title_clipping import check  # noqa: E402

CASES_R = os.path.join(REPO, "plots", "scripts", "tests", "render_title_bar_cases.R")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conda", default=None, help="path to the conda binary, to use the r-plots env")
    ap.add_argument("--rscript", default=None, help="Rscript binary to use (overrides --conda)")
    ap.add_argument("--out_dir", default=None, help="keep the rendered figures here")
    args = ap.parse_args()

    # No fallback to whatever Rscript is on PATH, unlike run_plots_suite.py: the
    # whole point of this check is font metrics, and the system R resolves fonts
    # differently from the env the app renders in. A pass there would mean
    # nothing for the app.
    rscript = args.rscript or plots_engine.resolve_rscript(args.conda)
    if not rscript:
        print("No r-plots Rscript found. Pass --conda /path/to/conda (or --rscript).")
        return 2

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="title_bar_cases_")
    print(f"Rscript: {rscript}\nout:     {out_dir}\n")

    result = subprocess.run([rscript, CASES_R, out_dir], capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        print("Rendering the cases failed.")
        return 1

    figures = sorted(f for f in os.listdir(out_dir) if f.endswith(".png"))
    if not figures:
        print("The render produced no figures.")
        return 1

    clipped = 0
    for name in figures:
        ok, message = check(os.path.join(out_dir, name))
        print(f"  [{'ok  ' if ok else 'CLIP'}] {name[:-4]:<20} {message}")
        clipped += 0 if ok else 1

    print(f"\n{clipped} clipped title(s) in {len(figures)} case(s)")
    return 1 if clipped else 0


if __name__ == "__main__":
    sys.exit(main())
