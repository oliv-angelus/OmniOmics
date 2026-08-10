#!/usr/bin/env python3
"""Joins per-sample Emu `*_rel-abundance.tsv` outputs into the same wide
"tax;lineage rows x sample columns" shape MAGMA's abundance table already
uses (see dada2_pacbio.R's own header comment for why this shape matters --
it's what the Plots tab's build_phyloseq.R already expects).

Tolerates empty input files (the touch-empty placeholder every inactive-
platform sample produces, same if/else-touch idiom as fastp/filtlong) by
just skipping them -- a run where every sample used the other platform still
produces a valid (header-only) output instead of crashing.

Verified against a real Emu 3.6.2 run -- confirmed the real column names below match Emu's actual
`*_rel-abundance.tsv` header, and found + fixed one real bug: Emu's own
output always appends `unmapped`/`mapped_filtered`/`mapped_unclassified`
summary rows with every rank column blank, which without the `tax_id in
SUMMARY_ROWS` skip below joined into a bogus empty-lineage
("d__;p__;c__;o__;f__;g__;s__") row instead of being dropped.

Reads the "estimated counts" column (real read-count-scaled values,
requires the emu_classify rule's `--keep-counts` flag), not the "abundance"
column (relative, 0-1) -- fix, found while starting the Plots tab
wiring: MAGMA's own abundance table (and PRISM's own PacBio/DADA2 path) is
real read counts, and count-based methods already in the Plots tab
(differential_abundance_deseq2.R) need real counts to be statistically
valid, not fractions. Rounded to the nearest integer -- Emu's EM algorithm
returns floats (e.g. 56.99999999999999) that are conceptually counts. also writes an optional `--out_species` table (real tax_id rows,
not lineage-collapsed) -- needed for the ONT/Emu path's phylogenetic tree
(build_emu_tree.R), which needs to know exactly which reference sequences
(by tax_id) were actually detected across the cohort, the same way
dada2_pacbio.R's ASV-level output feeds the PacBio path's tree. The
lineage-collapsed `--out` table stays the PRIMARY/default output, unchanged.

Usage: join_emu_tables.py --inputs sample1:path1.tsv sample2:path2.tsv... --out joined.tsv [--out_species species.tsv]
"""
import argparse
import csv
from collections import defaultdict

RANK_PREFIXES = [("domain", "d__"), ("phylum", "p__"), ("class", "c__"),
                  ("order", "o__"), ("family", "f__"), ("genus", "g__"),
                  ("species", "s__")]

# Emu's own bookkeeping rows (not real taxa) -- always present, always with
# blank rank columns, must be dropped rather than joined as an empty lineage.
SUMMARY_ROWS = {"unmapped", "mapped_filtered", "mapped_unclassified"}


def lineage_from_row(row):
    return ";".join(f"{prefix}{row.get(rank, '') or ''}" for rank, prefix in RANK_PREFIXES)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inputs", nargs="+", required=True, help="sample_name:path.tsv pairs")
    ap.add_argument("--out", required=True)
    ap.add_argument("--out_species", default="")
    args = ap.parse_args()
    table = defaultdict(dict)          # lineage -> {sample: count}
    species_table = defaultdict(dict)  # tax_id -> {sample: count}
    sample_names = []

    for pair in args.inputs:
        sample, path = pair.split(":", 1)
        sample_names.append(sample)
        try:
            with open(path, newline="") as fh:
                if fh.read(1) == "":
                    continue  # empty placeholder from the inactive-platform branch
                fh.seek(0)
                reader = csv.DictReader(fh, delimiter="\t")
                for row in reader:
                    tax_id = (row.get("tax_id") or "").strip()
                    if tax_id in SUMMARY_ROWS:
                        continue
                    lineage = lineage_from_row(row)
                    count = float(row.get("estimated counts", 0) or 0)
                    table[lineage][sample] = table[lineage].get(sample, 0.0) + count
                    species_table[tax_id][sample] = species_table[tax_id].get(sample, 0.0) + count
        except FileNotFoundError:
            continue

    with open(args.out, "w", newline="") as fout:
        writer = csv.writer(fout, delimiter="\t")
        writer.writerow(["tax"] + sample_names)
        for lineage, values in sorted(table.items()):
            writer.writerow([lineage] + [round(values.get(s, 0.0)) for s in sample_names])

    print(f"join_emu_tables: wrote {len(table)} lineage rows x {len(sample_names)} samples to {args.out}")

    if args.out_species:
        with open(args.out_species, "w", newline="") as fout:
            writer = csv.writer(fout, delimiter="\t")
            writer.writerow(["tax_id"] + sample_names)
            for tax_id, values in sorted(species_table.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit else kv[0]):
                writer.writerow([tax_id] + [round(values.get(s, 0.0)) for s in sample_names])
        print(f"join_emu_tables: wrote {len(species_table)} tax_id rows x {len(sample_names)} samples to {args.out_species}")


if __name__ == "__main__":
    main()
