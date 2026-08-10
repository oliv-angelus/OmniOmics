#!/usr/bin/env python3
"""One-time post-download conversion of SILVA's raw SSU/LSU export into the
format DADA2's assignTaxonomy/Emu's build-database actually need. Two
real, confirmed-not-assumed fixes (checked against a real fragment of the
live SILVA_138.2_SSURef_NR99_tax_silva.fasta.gz, fetched via SILVA's own
FTP mirror, ):

1. **Header format**: `>AccessionID.start.stop Domain;Phylum;...;Species`
   is NOT the pure semicolon-lineage format
   (`>Domain;Phylum;...;Species`, no accession token) those tools expect -- same class of fix as build_emu_taxonomy.py's own GTDB header fix, except
   here the accession-prefix assumption is genuinely correct (unlike GTDB's
   release, which has none).
2. **Sequence alphabet**: SILVA stores rRNA sequences in RNA alphabet (U,
   not T) -- e.g. real fetched header/sequence: `>AY846379.1.1791
   Eukaryota;...` / `AACCUGGUUGAUCCUGCCAGUAGUC...`. DADA2's k-mer-based
   naive Bayesian classifier and minimap2 (Emu's aligner) both expect DNA
   (ACGT), so every U needs converting to T or every query k-mer would
   mismatch the entire reference. Silently wrong, not merely suboptimal -- caught by actually reading a real downloaded fragment from
   SILVA's own documentation alone.

Run once per downloaded SILVA file (wired as a `post_cmd` in the database's
download_options in pipeline.yaml), not per pipeline run.

Usage: convert_silva_headers.py --in raw_silva.fasta[.gz] --out dada2_formatted.fasta
"""
import argparse
import gzip

RNA_TO_DNA = str.maketrans("Uu", "Tt")


def open_maybe_gz(path, mode="rt"):
    return gzip.open(path, mode) if path.endswith(".gz") else open(path, mode)


def main():
    ap = argparse.ArgumentParser
    ap.add_argument("--in", dest="in_path", required=True)
    ap.add_argument("--out", dest="out_path", required=True)
    args = ap.parse_args

    n = 0
    with open_maybe_gz(args.in_path) as fin, open(args.out_path, "w") as fout:
        for line in fin:
            if line.startswith(">"):
                n += 1
                header = line[1:].rstrip("\n")
                parts = header.split(None, 1)
                lineage = parts[1] if len(parts) > 1 else ""
                fout.write(f">{lineage}\n")
            else:
                fout.write(line.translate(RNA_TO_DNA))

    print(f"convert_silva_headers: rewrote {n} headers + RNA->DNA sequences from {args.in_path} to {args.out_path}")


if __name__ == "__main__":
    main()
