#!/usr/bin/env python3
"""Converts Mitohelper's curated MitoFish 12S TSV release into the
DADA2-formatted FASTA the rest of PRISM already expects
(`>d__Domain;p__Phylum;...;s__Species` directly after the '>').

Real background (see notes/PRISM.md): MitoFish's own download page is a
JS-driven app with no stable direct-file link, so it can't be wired as a
plain `download_options` URL the way GTDB/SILVA/GROND are. Mitohelper (Lim &
Thompson 2021, Environ DNA, 10.1002/edn3.187) solves this for real: a
maintained tool that re-extracts MitoFish into monthly-dated, single-file TSV
releases on Zenodo (stable DOI, real direct download). Confirmed the real
column layout by downloading a live fragment of the Jul2026 release, not
assumed: one row per sequence, sequence AND taxonomy already joined (unlike
GROND's separate fasta+taxonomy files, this needs no join, just a rewrite) --
    Accession  Gene definition  taxid  Superkingdom  Phylum  Class  Order
    Family  Genus  Species  Sequence  OrderID  FamilyID
Also confirmed empirically why this file (not the raw MitoFish dump, and not
a generic universal-primer in-silico-PCR database like rCRUX's Zenodo
"MiFish Universal Reference Database") is the right source: a real check of
that rCRUX alternative found only ~2% of its ~33k entries were actually fish
(Actinopterygii/Chondrichthyes) -- overwhelming non-fish in-silico-PCR noise,
not a usable stand-in for a fish-specific reference. Mitohelper's release is
curated FROM MitoFish (a real fish-only mitogenome database), so every row
here is a real fish (or near-fish, see --min_rank below) record.

Usage:
  convert_mitofish_headers.py --tsv mitofish.12S.Jul2026.tsv \\
      --out mitofish_12s_dada2.fasta
"""
import argparse
import csv
import sys

RANK_COLS = ["Superkingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species"]
RANK_PREFIXES = ["d__", "p__", "c__", "o__", "f__", "g__", "s__"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", required=True, help="Mitohelper mitofish.12S.<date>.tsv")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    csv.field_size_limit(sys.maxsize)

    written = 0
    skipped_no_seq = 0
    with open(args.tsv, newline="") as fin, open(args.out, "w") as fout:
        reader = csv.DictReader(fin, delimiter="\t")
        missing = [c for c in RANK_COLS + ["Sequence", "Accession"] if c not in reader.fieldnames]
        if missing:
            raise SystemExit(
                f"{args.tsv}: missing expected column(s) {missing} -- "
                f"got {reader.fieldnames}. Is this really a Mitohelper mitofish.12S.*.tsv?"
            )
        for row in reader:
            seq = (row.get("Sequence") or "").strip()
            if not seq:
                skipped_no_seq += 1
                continue
            lineage = ";".join(
                f"{prefix}{(row.get(col) or '').strip()}"
                for prefix, col in zip(RANK_PREFIXES, RANK_COLS)
            )
            fout.write(f">{lineage}\n{seq}\n")
            written += 1

    print(f"convert_mitofish_headers: wrote {written} sequences to {args.out}")
    if skipped_no_seq:
        print(f"convert_mitofish_headers: skipped {skipped_no_seq} row(s) with no Sequence value")
    if written == 0:
        raise SystemExit("No sequences were written -- check --tsv is a real Mitohelper mitofish.12S.*.tsv file.")


if __name__ == "__main__":
    main()
