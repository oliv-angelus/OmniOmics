"""Consolidates the QC metrics worth alerting on (fastp retention %, Bowtie2
alignment %, featureCounts assigned %, detected strandedness) into one
row-per-sample TSV, instead of leaving them scattered across each tool's own
report and log.

These four are together the earliest reliable signal that a sample went wrong:
a library that lost most of its reads in trimming, mapped poorly, or had few
reads assigned to features will show it here before any downstream result looks
odd.

Invoked as a plain CLI program by 06_merge.smk rather than through
Snakemake's `script:` directive -- see decide_strandedness.py's module
docstring for why.
"""
import argparse
import json
import re

import pandas as pd


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fastp", nargs="+", required=True)
    parser.add_argument("--bowtie2-logs", nargs="+", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--strand-report", required=True)
    parser.add_argument("--samples", nargs="+", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    samples = args.samples

    retention = {}
    for path, sample in zip(args.fastp, samples):
        with open(path) as f:
            data = json.load(f)
        before = data["summary"]["before_filtering"]["total_reads"]
        after = data["summary"]["after_filtering"]["total_reads"]
        retention[sample] = round(100 * after / before, 2) if before else None

    alignment = {}
    for path, sample in zip(args.bowtie2_logs, samples):
        text = open(path).read()
        m = re.search(r"([\d.]+)% overall alignment rate", text)
        alignment[sample] = float(m.group(1)) if m else None

    # featureCounts'.summary columns are the literal BAM paths it was given,
    # in the same order as `samples` (expand preserves list order) -- same
    # convention as merge_annotated_counts.py's count-matrix rename.
    summary = pd.read_csv(args.summary, sep="\t").set_index("Status")
    bam_cols = list(summary.columns)
    totals = summary[bam_cols].sum(axis=0)
    assigned = summary.loc["Assigned", bam_cols]
    assigned_pct = {}
    for col, sample in zip(bam_cols, samples):
        total = totals[col]
        assigned_pct[sample] = round(100 * assigned[col] / total, 2) if total else None

    strand = pd.read_csv(args.strand_report, sep="\t", comment="#")
    strand_by_sample = dict(zip(strand["sample"], strand["call"]))

    rows = [
        {
            "sample": sample,
            "fastp_retention_pct": retention.get(sample),
            "bowtie2_alignment_pct": alignment.get(sample),
            "featurecounts_assigned_pct": assigned_pct.get(sample),
            "strandedness": strand_by_sample.get(sample),
        }
        for sample in samples
    ]

    pd.DataFrame(rows).to_csv(args.out, sep="\t", index=False)
    print(f"wrote {args.out}: {len(rows)} samples")


if __name__ == "__main__":
    main()
