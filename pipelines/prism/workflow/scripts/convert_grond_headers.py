#!/usr/bin/env python3
"""Converts GROND's real two-file layout (sequences and taxonomy shipped
SEPARATELY) into the single DADA2-formatted FASTA the rest of PRISM already
expects (`>d__Domain;p__Phylum;...;s__Species` directly after the '>', no
accession prefix -- the exact shape assignTaxonomy and
build_emu_taxonomy.py both read).

Three real, confirmed-by-inspection differences from every other reference
PRISM supports (checked by downloading real fragments of the
actual Zenodo files from the dataset description):

1. GROND's FASTA headers carry NO taxonomy at all -- just an opaque cluster
   id (`>C_00000001`). The lineage lives in a separate 2-column TSV
   (`gtdb207nr_taxRep.tsv`), keyed by that same id. So this is a real join,
   not a header-rewrite like convert_silva_headers.py does.
2. That TSV has NO header row -- the first line is already data.
3. GROND separates ranks with PIPES (`d__Bacteria|p__Proteobacteria|...`),
   while GTDB/SILVA/UNITE and every downstream PRISM consumer use
   SEMICOLONS. Converted here.

Sequences themselves need no alphabet conversion (already DNA, unlike
SILVA's RNA -- confirmed on the real fragment).

Usage:
  convert_grond_headers.py --fasta gtdb207nr_nrRep.fna.gz \\
      --taxonomy gtdb207nr_taxRep.tsv --out grond_rrn_dada2.fasta
"""
import argparse
import gzip
import os
import sys


def _open_maybe_gzip(path):
    """GROND ships the FASTA gzipped and the TSV plain, but accept either
    for both -- costs nothing and avoids a confusing failure if a future
    release changes which is compressed."""
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def load_taxonomy(path):
    """cluster_id -> ';'-separated lineage. Real format is 2 tab-separated
    columns, no header, pipe-separated ranks."""
    tax = {}
    with _open_maybe_gzip(path) as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise SystemExit(
                    f"{path}:{line_no}: expected 2 tab-separated columns "
                    f"(cluster_id, lineage), got {len(parts)} -- is this really GROND's taxonomy TSV?"
                )
            tax[parts[0]] = parts[1].replace("|", ";")
    return tax


def main():
    ap = argparse.ArgumentParser
    ap.add_argument("--fasta", required=True, help="GROND *_nrRep.fna.gz (or *_full.fna.gz)")
    ap.add_argument("--taxonomy", required=True, help="matching GROND *_taxRep.tsv (or *_taxFull.tsv)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args

    tax = load_taxonomy(args.taxonomy)
    print(f"convert_grond_headers: loaded {len(tax)} taxonomy entries from {args.taxonomy}")

    written = 0
    skipped = 0
    with _open_maybe_gzip(args.fasta) as fin, open(args.out, "w") as fout:
        keep = False
        for line in fin:
            if line.startswith(">"):
                # FASTA id is the whole header token (no description field in
                # GROND's real output, but split defensively anyway).
                cluster_id = line[1:].split()[0].strip()
                lineage = tax.get(cluster_id)
                if lineage is None:
                    # A sequence with no taxonomy row can't be classified
                    # against -- dropped rather than written with an empty
                    # lineage, which would silently create a bogus
                    # "unclassified" taxon downstream (the same real bug
                    # class already fixed in join_emu_tables.py, where Emu's
                    # own summary rows joined as an empty-lineage taxon).
                    keep = False
                    skipped += 1
                    continue
                keep = True
                written += 1
                fout.write(f">{lineage}\n")
            elif keep:
                fout.write(line)

    print(f"convert_grond_headers: wrote {written} sequences to {args.out}")
    if skipped:
        print(f"convert_grond_headers: skipped {skipped} sequence(s) with no matching taxonomy row")
    if written == 0:
        raise SystemExit(
            "No sequences were written -- every FASTA id failed to match a taxonomy row. "
            "Are --fasta and --taxonomy from the same GROND variant? "
            "(nrRep pairs with taxRep; full pairs with taxFull.)"
        )


if __name__ == "__main__":
    main()
