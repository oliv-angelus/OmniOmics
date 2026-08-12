#!/usr/bin/env python3
"""Runs every Plots-tab analysis of a pipeline against a run folder, offline.

Reproduces exactly what the backend does when the user picks a run and clicks
through each analysis card: build every input shape the pipeline needs into one
shared out_dir (backend/main.py's INPUT_SHAPE_INFO), then invoke each analysis
script with its manifest defaults (plots_engine.build_params_args).

Its point is that an analysis "compiles" only once it RUNS -- the R scripts are
never type-checked, so a renamed column or a stale flag surfaces nowhere until
execution. Running the whole suite after a change is the actual regression test.

    python3 scripts/run_plots_suite.py magma \\
        ~/omniomics_demo_runs/magma_testrun/results \\
        ~/Documentos/omniomics_test_metadata/metadata_magma_testrun.tsv

Choice parameters are exercised across ALL their values, not just the default,
since a toggle's non-default branch is exactly where breakage hides.
"""
import argparse
import itertools
import os
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# backend/ modules import each other flatly ("import conda_manager"), so the
# package dir itself has to be on the path -- importing them as backend.* fails.
sys.path.insert(0, os.path.join(REPO, "backend"))

import plots_engine  # noqa: E402
from main import INPUT_SHAPE_INFO  # noqa: E402

PLOTS_DIR = os.path.join(REPO, "plots")


def run(cmd, cwd=None):
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    return p.returncode, p.stdout + p.stderr, time.time() - t0


def build_shapes(pipeline, results_dir, metadata, out_dir, rscript):
    """One out_dir holding every shape, matching how /api/plots/load caches
    them side by side -- analyses that read a second shape by filename (e.g.
    magma_community_taxonomy reaching for phyloseq_kaiju.rds) depend on this."""
    os.makedirs(out_dir, exist_ok=True)
    ok = True
    for shape in plots_engine.get_input_shapes_for_pipeline(pipeline):
        info = INPUT_SHAPE_INFO[shape]
        cmd = [rscript, os.path.join(PLOTS_DIR, "scripts", info["loader_script"]),
               "--input", results_dir, "--metadata", metadata, "--out_dir", out_dir,
               "--pipeline_id", pipeline]
        cmd += info.get("extra_args", [])
        rc, out, secs = run(cmd)
        print(f"  [{'ok ' if rc == 0 else 'FAIL'}] shape {shape:<18} {secs:5.1f}s")
        if rc != 0:
            ok = False
            print("\n".join("        " + l for l in out.strip().splitlines()[-8:]))
    return ok


def param_matrix(analysis, overrides):
    """Every combination of the analysis's choice parameters, other params at
    their manifest default. Non-choice params are left to the script's own
    defaults so this stays a smoke test, not a search over the whole space.

    `overrides` fills in the parameter types the app resolves from the loaded
    run rather than from the manifest -- the metadata column for --group_var,
    the MAG list for --mags. Without them those analyses stop at their own
    "is required" check and nothing downstream is tested."""
    params = analysis.get("parameters", [])
    choices = [(p["flag"], p["choices"]) for p in params
               if p.get("type") == "choice" and p.get("enabled") and p.get("choices")]
    flags = [c[0] for c in choices]
    combos = list(itertools.product(*[c[1] for c in choices])) if choices else [()]

    out = []
    for combo in combos:
        chosen = dict(zip(flags, combo))
        # visible_when mirrors the app: a parameter hidden by the current
        # choice is not sent. Without this the suite would test combinations
        # the UI cannot produce (e.g. --mags alongside --level sample) and
        # count the script's own correct refusal of them as a failure.
        args = []
        for p in params:
            if p.get("type") == "choice":
                continue
            cond = p.get("visible_when") or {}
            if any(chosen.get(k) != v for k, v in cond.items()):
                continue
            if p["flag"] in overrides:
                args += [p["flag"], overrides[p["flag"]]]
        out.append(args + [a for f in flags for a in (f, str(chosen[f]))])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pipeline")
    ap.add_argument("results_dir")
    ap.add_argument("metadata")
    ap.add_argument("--out_dir", default=None)
    ap.add_argument("--only", default=None, help="run just this analysis id")
    ap.add_argument("--skip_load", action="store_true", help="reuse an existing cache dir")
    ap.add_argument("--conda", default=None, help="path to the conda binary, to use the r-plots env")
    ap.add_argument("--set", action="append", default=[], metavar="FLAG=VALUE",
                    help="value for a parameter the UI would supply (repeatable), "
                         "e.g. --set --group_var=condition")
    ap.add_argument("--rscript", default=None, help="Rscript binary to use (overrides --conda)")
    args = ap.parse_args()

    # The app always runs analyses inside the r-plots conda env; falling back
    # to whatever Rscript is on PATH is fine for a smoke test but means a
    # missing package here is not necessarily missing for the app, and vice
    # versa. Pass --conda to test the env the app really uses.
    rscript = args.rscript or plots_engine.resolve_rscript(args.conda) or shutil.which("Rscript")
    if not rscript:
        sys.exit("No Rscript found -- is the plots R environment installed?")

    out_root = args.out_dir or os.path.join("/tmp", f"plots_suite_{args.pipeline}")
    cache = os.path.join(out_root, "_cache")
    print(f"Rscript: {rscript}\nout:     {out_root}\n")

    if not args.skip_load:
        print("Loading input shapes")
        if not build_shapes(args.pipeline, args.results_dir, args.metadata, cache, rscript):
            sys.exit("\nA loader failed -- no analysis can run without its shape.")
        print()
    else:
        # --skip_load against an out_dir that was never loaded gives every
        # analysis the same unreadable "cannot open the connection" from
        # readRDS, one per parameter combination. Say it once, up front.
        missing = [s for s in plots_engine.get_input_shapes_for_pipeline(args.pipeline)
                   if not os.path.exists(os.path.join(cache, INPUT_SHAPE_INFO[s]["rds_filename"]))]
        if missing:
            sys.exit(f"--skip_load, but {cache} has no cache for: {', '.join(missing)}. "
                     f"Drop --skip_load, or point --out_dir at a directory a previous run loaded.")

    overrides = dict(kv.split("=", 1) for kv in args.set)

    analyses = plots_engine.get_analysis_list(args.pipeline)
    if args.only:
        analyses = [a for a in analyses if a["id"] == args.only]
    print(f"Running {len(analyses)} analyses for {args.pipeline}")

    failures = []
    empty = 0
    for a in analyses:
        info = INPUT_SHAPE_INFO[a["input_shape"]]
        rds = os.path.join(cache, info["rds_filename"])
        for i, extra in enumerate(param_matrix(a, overrides)):
            label = a["id"] + (f" [{' '.join(extra)}]" if extra else "")
            odir = os.path.join(out_root, f"{a['id']}_{i}")
            os.makedirs(odir, exist_ok=True)
            cmd = [rscript, plots_engine.script_path(a["id"]),
                   info["rds_flag"], rds, "--out_dir", odir] + extra
            rc, out, secs = run(cmd)
            preview = os.path.join(odir, "preview.png")
            has_png = os.path.exists(preview) and os.path.getsize(preview) > 0
            # An analysis that exits 0 with no figure is not a failure: some
            # legitimately have nothing to draw (no gene family passed the
            # significance cut, say) and say so in data.json rather than
            # inventing a plot. Only a non-zero exit is a real break.
            if rc != 0:
                status = "FAIL"
            elif has_png:
                status = "ok  "
            else:
                status = "----"
                empty += 1
            print(f"  [{status}] {label:<70} {secs:5.1f}s")
            if status == "FAIL":
                failures.append((label, out))

    print(f"\n{len(failures)} failure(s), {empty} empty result(s) (ran fine, nothing to plot)")
    for label, out in failures:
        print(f"\n--- {label} ---")
        print("\n".join(out.strip().splitlines()[-12:]))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
