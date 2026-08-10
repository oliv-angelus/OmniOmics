"""Parses RSeQC's infer_experiment.py output for every sample and picks
featureCounts' -s value automatically: if one strand pattern dominates
(>=90%) the library is stranded (forward or reverse, whichever fraction
wins); if the two patterns are close to 50/50, it's unstranded. See
PIPELINE_SPEC.md [6] -- this is what makes that "totally automatable" claim
concrete and auditable (every sample's numbers land in the report, not just
the final choice).

Invoked as a plain CLI program by 04_strandedness.smk rather than through
Snakemake's `script:` directive: that directive injects the Snakemake
environment's own site-packages into PYTHONPATH, which shadows the rule
conda environment's interpreter and breaks compiled dependencies whenever
the two environments' Python versions differ.
"""
import argparse
import re

# featureCounts -s 1 (forward) / -s 2 (reverse) pattern strings, exactly as
# RSeQC's infer_experiment.py prints them for paired-end data.
FWD_PATTERN = "1++,1--,2+-,2-+"
REV_PATTERN = "1+-,1-+,2++,2--"


def parse_report(path):
    text = open(path).read()
    fwd = re.search(r'"' + re.escape(FWD_PATTERN) + r'":\s*([\d.]+)', text)
    rev = re.search(r'"' + re.escape(REV_PATTERN) + r'":\s*([\d.]+)', text)
    undetermined = re.search(r"Fraction of reads failed to determine:\s*([\d.]+)", text)
    return {
        "fwd": float(fwd.group(1)) if fwd else 0.0,
        "rev": float(rev.group(1)) if rev else 0.0,
        "undetermined": float(undetermined.group(1)) if undetermined else 0.0,
    }


def main() :
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports", nargs="+", required=True)
    parser.add_argument("--samples", nargs="+", required=True)
    parser.add_argument("--out-value", required=True)
    parser.add_argument("--out-report", required=True)
    args = parser.parse_args

    rows = []
    for sample, report_path in zip(args.samples, args.reports):
        frac = parse_report(report_path)
        if frac["fwd"] >= 0.9:
            call = "forward"
        elif frac["rev"] >= 0.9:
            call = "reverse"
        else:
            call = "unstranded"
        rows.append((sample, frac["fwd"], frac["rev"], frac["undetermined"], call))

    calls = [r[4] for r in rows]
    majority_call = max(set(calls), key=calls.count)
    strand_value = {"forward": "1", "reverse": "2", "unstranded": "0"}[majority_call]

    if len(set(calls)) > 1:
        counts = {c: calls.count(c) for c in set(calls)}
        print(
            f"WARNING: samples disagree on strandedness ({counts}); "
            f"using the majority call ({majority_call}) for all samples."
        )

    with open(args.out_value, "w") as f:
        f.write(strand_value)

    with open(args.out_report, "w") as f:
        f.write("sample\tfwd_fraction\trev_fraction\tundetermined_fraction\tcall\n")
        for sample, fwd, rev, undet, call in rows:
            f.write(f"{sample}\t{fwd}\t{rev}\t{undet}\t{call}\n")
        f.write(
            f"# featureCounts -s value used: {strand_value} "
            f"({majority_call}, majority across {len(rows)} sample(s))\n"
        )

    print(f"strandedness: {majority_call} (featureCounts -s {strand_value})")


if __name__ == "__main__":
    main
