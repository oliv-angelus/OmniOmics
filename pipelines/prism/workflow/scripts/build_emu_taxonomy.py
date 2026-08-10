#!/usr/bin/env python3
"""Converts a DADA2-formatted reference FASTA (header: pure semicolon-joined
lineage, `>Domain;Phylum;Class;Order;Family;Genus;Species` -- confirmed
against a real fragment of Alishum's actual GTDB r220 SSU release fetched
live from Zenodo, there is NO accession/ID token before the
lineage, unlike this script's first version assumed -- into the three files
Emu's real `emu build-database <db_name> --sequences --seq2tax
--taxonomy-list` command needs (confirmed against a real `emu
build-database --help`, Emu 3.6.2): a sequences FASTA re-headered to a bare
numeric tax_id, a seq2tax TSV mapping each tax_id to its own fasta header
(trivial 1:1 here since every reference sequence gets its own unique
tax_id), and a taxonomy TSV mapping that tax_id to its rank columns.
Building all three from the same source release is what keeps the ONT (Emu)
and PacBio (DADA2) paths reporting taxonomy in the same lineage, not two
independently-curated references that could disagree. Works unchanged for
any of PRISM's DADA2-formatted references (GTDB, SILVA SSU/LSU after
convert_silva_headers.py, UNITE) -- they all share this same pure-lineage
header contract.

Usage: build_emu_taxonomy.py --ref reference.fa[.gz] --out_fasta seqs.fa \
    --out_seq2tax seq2tax.tsv --out_taxonomy taxonomy.tsv
"""
import argparse
import gzip

RANK_NAMES = ["domain", "phylum", "class", "order", "family", "genus", "species"]


def open_maybe_gz(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def main():
    ap = argparse.ArgumentParser
    ap.add_argument("--ref", required=True)
    ap.add_argument("--out_fasta", required=True)
    ap.add_argument("--out_seq2tax", required=True)
    ap.add_argument("--out_taxonomy", required=True)
    args = ap.parse_args

    with open_maybe_gz(args.ref) as fin, \
         open(args.out_fasta, "w") as fasta_out, \
         open(args.out_seq2tax, "w") as seq2tax_out, \
         open(args.out_taxonomy, "w") as tax_out:

        tax_out.write("tax_id\t" + "\t".join(RANK_NAMES) + "\n")

        tax_id = 0
        write_seq = False
        for line in fin:
            if line.startswith(">"):
                tax_id += 1
                # Header shape (real, confirmed): pure semicolon-joined
                # lineage, no accession/ID token before it --
                # "Domain;Phylum;Class;Order;Family;Genus;Species".
                lineage = line[1:].strip()
                ranks = lineage.split(";")
                ranks = (ranks + [""] * len(RANK_NAMES))[:len(RANK_NAMES)]
                tax_out.write(f"{tax_id}\t" + "\t".join(ranks) + "\n")
                fasta_out.write(f">{tax_id}\n")
                seq2tax_out.write(f"{tax_id}\t{tax_id}\n")
                write_seq = True
            elif write_seq:
                fasta_out.write(line)

    print(f"build_emu_taxonomy: wrote {tax_id} references to {args.out_fasta} / "
          f"{args.out_seq2tax} / {args.out_taxonomy}")


if __name__ == "__main__":
    main()
