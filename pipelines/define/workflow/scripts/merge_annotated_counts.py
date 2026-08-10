"""Joins the raw featureCounts matrix with the reference's gene/product
table (Bakta) and functional annotation (eggNOG) into one "completona"
table, ready for the user's own downstream differential expression work --
this pipeline stops here on purpose (see the merge_annotated_counts rule's
docstring).

Invoked as a plain CLI program by 06_merge.smk rather than through
Snakemake's `script:` directive -- see decide_strandedness.py's module
docstring for why.
"""
import argparse

import pandas as pd


def read_bakta_tsv(path):
    """Bakta's.tsv starts with a couple of '##' comment lines, then a
    '#Sequence Id\\tType\\t...' header row that IS the real header (not a
    comment to skip)."""
    with open(path) as f:
        lines = f.readlines()
    header_idx = next(
        i for i, l in enumerate(lines)
        if l.startswith("#Locus Tag") or l.startswith("#Sequence Id")
    )
    header = [h.strip() for h in lines[header_idx].lstrip("#").strip().split("\t")]
    data = [l.rstrip("\n").split("\t") for l in lines[header_idx + 1:] if l.strip()]
    return pd.DataFrame(data, columns=header)


def read_eggnog_annotations(path):
    """eggNOG-mapper's.annotations file starts with '##' comment lines, a
    '#query\\t...' header row, data rows, then trailing '##' footer comment
    lines (run stats) to also skip."""
    with open(path) as f:
        lines = f.readlines()
    header_idx = next(i for i, l in enumerate(lines) if l.startswith("#query"))
    header = [h.strip() for h in lines[header_idx].lstrip("#").strip().split("\t")]
    data = [
        l.rstrip("\n").split("\t")
        for l in lines[header_idx + 1:]
        if l.strip() and not l.startswith("#")
    ]
    return pd.DataFrame(data, columns=header)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--counts", required=True)
    parser.add_argument("--bakta-tsv", required=True)
    parser.add_argument("--eggnog", required=True)
    parser.add_argument("--samples", nargs="+", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    # featureCounts' header is preceded by one comment line (its own version +
    # command line), and its sample columns are the literal BAM paths passed as
    # input, in the same order as `samples` (expand preserves list order).
    counts = pd.read_csv(args.counts, sep="\t", skiprows=1)
    sample_cols = list(counts.columns[6:])
    counts = counts.rename(columns=dict(zip(sample_cols, args.samples)))
    counts = counts.rename(columns={"Geneid": "locus_tag"})

    bakta = read_bakta_tsv(args.bakta_tsv)
    bakta = bakta.rename(columns={"Locus Tag": "locus_tag"})
    bakta = bakta[[c for c in ["locus_tag", "Gene", "Product"] if c in bakta.columns]]

    eggnog = read_eggnog_annotations(args.eggnog)
    eggnog = eggnog.rename(columns={"query": "locus_tag"})
    eggnog_keep = [
        "locus_tag", "eggNOG_OGs", "COG_category", "Description",
        "GOs", "EC", "KEGG_ko", "KEGG_Pathway", "PFAMs",
    ]
    eggnog = eggnog[[c for c in eggnog_keep if c in eggnog.columns]]

    merged = counts.merge(bakta, on="locus_tag", how="left").merge(eggnog, on="locus_tag", how="left")
    merged.to_csv(args.out, sep="\t", index=False)

    print(f"wrote {args.out}: {len(merged)} genes x {len(args.samples)} samples")


if __name__ == "__main__":
    main()
