#!/usr/bin/env python3
"""Maps vsearch's centroid-level chimera verdict back onto the original
(pre-clustering) member reads, and writes a filtered FASTQ.

vsearch --uchime_denovo only ever sees one representative sequence per
cluster, so its chimera/nonchimera FASTA outputs contain centroid IDs, not
the original read IDs. This reads the --uc mapping (centroid -> every member
read) produced by `vsearch --cluster_size` (95%-identity clustering, not
exact dereplication -- see 03_chimera.smk's note for why exact
dereplication doesn't give the chimera algorithm real abundance to work
with on raw noisy long reads), keeps every read whose centroid was called
nonchimeric, and writes those out of the *original* (pre-clustering) FASTQ
so no read multiplicity/quality info is lost -- vsearch's own chimera-only
outputs give back just the representative sequences, which isn't what
downstream denoising (DADA2/Emu) needs. The.uc format (H/S/C records) is
identical regardless of which vsearch clustering mode produced it, so this
script needed no changes when the upstream rule switched from
`--fastx_uniques` to `--cluster_size`.

Usage: recover_nonchimeric_reads.py --uc clustered.uc --nonchimeras nonchimeric_centroids.fasta \
    --original original.fastq.gz --out nonchimeric.fastq.gz
"""
import argparse
import gzip


def open_maybe_gz(path, mode="rt"):
    return gzip.open(path, mode) if path.endswith(".gz") else open(path, mode)


def parse_uc(uc_path):
    """Returns {read_id: centroid_id} for every H(it)/S(eed) record."""
    member_to_centroid = {}
    with open(uc_path) as fh:
        for line in fh:
            fields = line.rstrip("\n").split("\t")
            record_type = fields[0]
            if record_type not in ("H", "S"):
                continue
            query_id = fields[8].split(";")[0]  # strip vsearch's ";size=N" suffix
            target_id = fields[9].split(";")[0]
            centroid_id = query_id if record_type == "S" else target_id
            member_to_centroid[query_id] = centroid_id
    return member_to_centroid


def parse_fasta_ids(fasta_path):
    ids = set
    with open(fasta_path) as fh:
        for line in fh:
            if line.startswith(">"):
                ids.add(line[1:].split(";")[0].split()[0].strip())
    return ids


def main():
    ap = argparse.ArgumentParser
    ap.add_argument("--uc", required=True)
    ap.add_argument("--nonchimeras", required=True)
    ap.add_argument("--original", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args

    member_to_centroid = parse_uc(args.uc)
    nonchimeric_centroids = parse_fasta_ids(args.nonchimeras)
    keep_ids = {
        read_id for read_id, centroid in member_to_centroid.items()
        if centroid in nonchimeric_centroids
    }

    kept, total = 0, 0
    with open_maybe_gz(args.original) as fin, open_maybe_gz(args.out, "wt") as fout:
        while True:
            header = fin.readline
            if not header:
                break
            seq = fin.readline
            plus = fin.readline
            qual = fin.readline
            total += 1
            read_id = header[1:].split()[0].strip()
            if read_id in keep_ids:
                fout.write(header)
                fout.write(seq)
                fout.write(plus)
                fout.write(qual)
                kept += 1

    print(f"recover_nonchimeric_reads: kept {kept}/{total} reads "
          f"({total - kept} flagged chimeric, {total - len(member_to_centroid)} "
          f"had no cluster mapping)")


if __name__ == "__main__":
    main()
