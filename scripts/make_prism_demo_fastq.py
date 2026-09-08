#!/usr/bin/env python3
"""Generates a small, synthetic-COVERAGE-but-real-SEQUENCE 16S amplicon
dataset to run THROUGH the app itself -- unlike make_prism_test_run.py (which
writes post-DADA2 result tables straight into results/ to exercise the Plots
tab), this writes raw per-sample FASTQ files into the long_reads_dir layout
config_engine.py's build_samples() scans (one subfolder per sample, first
*.fastq.gz found becomes that sample's fq_long), so the Inputs tab can pick
it up and the run can go through NanoPlot -> Filtlong -> Cutadapt -> VSEARCH
chimera filtering -> DADA2/Emu for real.

What's real vs. synthetic, and why this changed from the first version:
  * The 6 "species" template sequences are now REAL full-length 16S sequences
    pulled straight out of the user's own downloaded GTDB reference
    (GTDB_bac120_arc53_ssu_r220_fullTaxo.fa), not random ACGT. The first
    version used random sequence -- fine for DADA2 (assignTaxonomy() just
    returns NA for an unclassifiable ASV, no crash), but Emu classifies by
    actually aligning reads to the reference with minimap2: 0% identity
    against random sequence means 0 reads map, and Emu hard-crashes with
    "ValueError: 0 reads mapped" rather than tolerating it (confirmed by
    running it: Unmapped read count == every read, Mapped read count: 0).
    Real reference sequences fix this at the root for both platforms, and as
    a bonus DADA2 now assigns genuine (correct) taxonomy instead of NA.
  * Coverage/abundance/errors are still fully synthetic -- these are 6 real
    species picked for a lake-habitat demo (a nitrifier, a methanogen, a
    gut/soil generalist mix), not what was actually growing anywhere. Per-
    sample relative abundance is an invented gradient (see TEMPLATE_ABUNDANCE),
    not a measurement.
  * Read length window (1300-1700 bp) matches the 16s_27f_1492r amplicon
    preset's own Filtlong window -- all 6 source sequences already fall
    inside it as full-length 16S, no trimming/padding needed.
  * Per-base quality/error simulate real ONT/HiFi-ish reads: quality is
    drawn per base, and whether that base is actually miscalled is then
    sampled from the error probability the drawn Q implies -- so quality and
    error covary the way a real instrument (and DADA2's learnErrors()) does,
    instead of being two independent random fields.
  * Falls back to the OLD random-ACGT behavior (with a clear warning) if no
    GTDB reference is found -- still exercises QC/trim/chimera mechanics
    fine, just can't classify anything real without it.

Files written:
  <OUT>/reads/<sample>/<sample>.fastq.gz   for each of 3 samples
  <OUT>/reads/metadata.tsv                 sample metadata for the Plots tab
  <OUT>/README.txt                         what this is + how to load it
"""
import glob
import gzip
import os
import random
import shutil

random.seed(20260907)

OUT = os.path.join(os.environ.get("OMNIOMICS_DEMO_RUNS",
                                   os.path.expanduser("~/omniomics_demo_runs")),
                    "prism_fastq_demo")

# Where to look for an already-downloaded GTDB SSU reference (same file the
# Databases tab's gtdb_ssu option installs) -- checked in order, first hit
# wins. Override with GTDB_REF_FASTA if it lives somewhere else.
GTDB_SEARCH_PATHS = [
    os.environ.get("GTDB_REF_FASTA", ""),
    os.path.expanduser("~/Documentos/db/GTDB_bac120_arc53_ssu_r220_fullTaxo.fa"),
    os.path.expanduser("~/omniomics_db/GTDB_bac120_arc53_ssu_r220_fullTaxo.fa"),
]

# 6 real species (headers matched by suffix against the GTDB fasta's own
# semicolon-lineage headers), picked for a plausible lake-habitat mix and
# confirmed to fall inside the 1300-1700 bp Filtlong window.
GTDB_TARGETS = [
    "Escherichia_coli_F(RS_GCF_000194175_1",
    "Pseudomonas_aeruginosa(RS_GCF_001457615_1",
    "Bacillus_subtilis(RS_GCF_000009045_1",
    "Bacteroides_fragilis_B(RS_GCF_019583405_1",
    "Nitrosomonas_europaea(RS_GCF_900167395_1",              # ammonia oxidizer -- fits a lake N cycle
    "Methanomethylovorans_hollandica(RS_GCF_000328665_1",    # archaeon, methanogen -- fits lake sediment
]

FWD_PRIMER = "AGRGTTYGATYMTGGCTCAG"   # 16S 27F -- only used by the random-sequence fallback
REV_PRIMER = "AAGTCGTAACAAGGTARCY"    # 16S 1492R
_COMPLEMENT = str.maketrans("ACGTURYSWKMBDHVN", "TGCAAYRSWMKVHDBN")


def _revcomp(seq):
    return seq.translate(_COMPLEMENT)[::-1]


def _resolve_ambiguous(seq):
    choices = {
        "R": "AG", "Y": "CT", "S": "GC", "W": "AT", "K": "GT", "M": "AC",
        "B": "CGT", "D": "AGT", "H": "ACT", "V": "ACG", "N": "ACGT",
    }
    return "".join(random.choice(choices.get(b, b)) for b in seq)


def _find_gtdb_ref():
    for path in GTDB_SEARCH_PATHS:
        if path and os.path.isfile(path):
            return path
    return None


def _load_real_templates(ref_path):
    """Pulls out just the GTDB_TARGETS sequences by scanning the (large)
    reference fasta once, matching each entry's header by suffix against the
    plain lineage;...;Genus_species(accession header GTDB writes -- see
    build_emu_taxonomy.py's own docstring for that exact header shape."""
    wanted = set(GTDB_TARGETS)
    found = {}
    header = None
    seq_lines = []

    def _flush():
        if header is None:
            return
        seq = "".join(seq_lines)
        for t in wanted:
            if header.endswith(t) and t not in found:
                found[t] = seq

    with open(ref_path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith(">"):
                _flush()
                header = line[1:]
                seq_lines = []
            else:
                seq_lines.append(line)
        _flush()

    missing = wanted - found.keys()
    if missing:
        raise RuntimeError(f"GTDB reference found but missing expected entries: {sorted(missing)}")
    return [found[t] for t in GTDB_TARGETS]


def _random_templates():
    print("WARNING: no GTDB reference found (checked GTDB_REF_FASTA and the usual "
          "download locations) -- falling back to random ACGT templates. QC/trim/"
          "chimera mechanics still work, but DADA2 will assign NA taxonomy and Emu "
          "will fail with 'ValueError: 0 reads mapped' (it classifies by alignment, "
          "which needs real reference-homologous sequence). Download GTDB on the "
          "Databases tab, then rerun this script, to fix both.")
    templates = []
    for _ in range(len(GTDB_TARGETS)):
        length = random.randint(1440, 1480)
        insert = "".join(random.choice("ACGT") for _ in range(length))
        templates.append(_resolve_ambiguous(FWD_PRIMER) + insert + _revcomp(_resolve_ambiguous(REV_PRIMER)))
    return templates


# 3 samples across a mock habitat gradient, small enough to run in seconds.
SAMPLES = ["lake_S1", "lake_W1", "lake_B1"]
READS_PER_SAMPLE = 1000  # 3 samples x 1000 = 3000 reads total

# Per-template (index-aligned with GTDB_TARGETS) base weight + per-sample
# relative-abundance multiplier, so the demo shows real-looking shifts in
# community composition across samples rather than flat noise. Invented, not
# measured -- see module docstring.
TEMPLATE_ABUNDANCE = {
    # base weight,           sample multipliers (lake_S1, lake_W1, lake_B1)
    0: (30, (2.5, 1.0, 0.6)),   # E. coli
    1: (25, (0.8, 2.2, 1.0)),   # P. aeruginosa
    2: (20, (1.0, 1.0, 2.0)),   # B. subtilis
    3: (15, (1.2, 0.9, 1.1)),   # B. fragilis
    4: (7,  (0.2, 1.8, 0.5)),   # N. europaea -- near-exclusive to lake_W1
    5: (3,  (1.0, 1.0, 1.0)),   # M. hollandica -- rare everywhere (singleton-ish)
}

QUAL_MEAN, QUAL_SD, QUAL_MIN, QUAL_MAX = 30, 6, 8, 50  # realistic-ish long-read CCS/CLR blend

# Sample metadata for the Plots tab's grouped analyses (see docs/plot_input_
# formats.md's "The metadata table" section for the exact contract this
# format follows: first column = sample ID matching the abundance table's
# columns exactly, any number of further columns, text = grouping variable,
# numeric = usable as an RDA environmental variable). Invented labels/values
# reading the SAMPLES names as a depth gradient in one lake -- same "made up
# for the demo, not measured" status as TEMPLATE_ABUNDANCE above.
SAMPLE_METADATA = {
    "lake_S1": {"habitat": "surface", "depth_m": 0.5, "pH": 7.8},
    "lake_W1": {"habitat": "water_column", "depth_m": 5.0, "pH": 7.4},
    "lake_B1": {"habitat": "sediment", "depth_m": 15.0, "pH": 6.9},
}


def simulate_read(template):
    """Draw a per-base quality, then decide per-base whether that quality's
    own implied error rate (10^(-Q/10)) actually flips the base -- keeps
    quality and error correlated like a real instrument, not independent."""
    bases = list(template)
    quals = []
    for i, b in enumerate(bases):
        q = max(QUAL_MIN, min(QUAL_MAX, int(round(random.gauss(QUAL_MEAN, QUAL_SD)))))
        quals.append(q)
        if random.random() < 10 ** (-q / 10):
            bases[i] = random.choice([x for x in "ACGT" if x != b])
    seq = "".join(bases)
    qual_str = "".join(chr(q + 33) for q in quals)
    return seq, qual_str


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)

    ref_path = _find_gtdb_ref()
    real = ref_path is not None
    templates = _load_real_templates(ref_path) if real else _random_templates()

    for si, sample in enumerate(SAMPLES):
        weights = [TEMPLATE_ABUNDANCE[t][0] * TEMPLATE_ABUNDANCE[t][1][si] for t in range(len(templates))]
        sample_dir = os.path.join(OUT, "reads", sample)
        os.makedirs(sample_dir, exist_ok=True)
        path = os.path.join(sample_dir, f"{sample}.fastq.gz")
        with gzip.open(path, "wt") as f:
            for i in range(READS_PER_SAMPLE):
                t = random.choices(range(len(templates)), weights=weights, k=1)[0]
                seq, qual = simulate_read(templates[t])
                f.write(f"@{sample}_{i:05d}/ccs\n{seq}\n+\n{qual}\n")

    meta_cols = ["habitat", "depth_m", "pH"]
    with open(os.path.join(OUT, "reads", "metadata.tsv"), "w", encoding="utf-8") as f:
        f.write("SampleID\t" + "\t".join(meta_cols) + "\n")
        for sample in SAMPLES:
            row = SAMPLE_METADATA[sample]
            f.write(sample + "\t" + "\t".join(str(row[c]) for c in meta_cols) + "\n")

    species_line = ("Escherichia coli, Pseudomonas aeruginosa, Bacillus subtilis, "
                     "Bacteroides fragilis, Nitrosomonas europaea, Methanomethylovorans hollandica"
                     if real else "6 random-sequence templates (no taxonomic identity)")

    readme = f"""PRISM demo FASTQ ({'real GTDB sequences, synthetic coverage' if real else 'fully synthetic -- see warning below'})
{'=' * 70}
3 samples, {READS_PER_SAMPLE} long-read-style 16S amplicon reads each
({READS_PER_SAMPLE * len(SAMPLES)} reads total), in the folder layout the
app's Inputs tab scans:

  {OUT}/reads/
    lake_S1/lake_S1.fastq.gz
    lake_W1/lake_W1.fastq.gz
    lake_B1/lake_B1.fastq.gz
    metadata.tsv

Species ({'real GTDB 16S sequences' if real else 'no real identity'}, invented per-sample abundances): {species_line}

Metadata (invented, not measured -- reads the 3 sample names as a depth
gradient in one lake): habitat (surface/water_column/sediment), depth_m,
pH -- see {os.path.join(OUT, "reads", "metadata.tsv")}. Pick this file when
the Plots tab asks for a metadata table; habitat/depth_m/pH all become usable
group_var / RDA environmental-variable choices.

How to use it:
  1. Inputs tab -> PRISM -> point "long_reads_dir" at:
       {os.path.join(OUT, "reads")}
  2. Amplicon preset: "16S completo -- 27F/1492R (universal)" (the default).
  3. Long-read platform: either PacBio (HiFi/CCS) -> DADA2, or Nanopore (ONT)
     -> Emu -- both now classify against real sequence, so either path works
     end to end (quality/error here is a rough long-read approximation, not
     tuned specifically to one platform's real error profile).
  4. NanoPlot, Filtlong, Cutadapt, VSEARCH chimera filtering, and the
     DADA2/Emu classification step all run with no extra setup, AS LONG AS
     the GTDB reference is downloaded on the Databases tab first (it must be,
     for this script to have found real sequences to begin with).
  5. PICRUSt2 (functional inference) only runs on the PacBio/DADA2 path.
  6. Plots tab -> pick this run -> when asked for a metadata table, point it
     at {os.path.join(OUT, "reads", "metadata.tsv")}.

Regenerate with: python3 scripts/make_prism_demo_fastq.py
(seeded -- reruns are byte-identical unless the script or the GTDB file changes)
"""
    with open(os.path.join(OUT, "README.txt"), "w", encoding="utf-8") as f:
        f.write(readme)

    total = READS_PER_SAMPLE * len(SAMPLES)
    print(f"reads dir: {os.path.join(OUT, 'reads')}")
    print(f"samples:   {', '.join(SAMPLES)}")
    print(f"reads:     {total} total ({READS_PER_SAMPLE}/sample)")
    print(f"templates: {len(templates)} {'real GTDB' if real else 'RANDOM (fallback)'} species")
    print(f"metadata:  {os.path.join(OUT, 'reads', 'metadata.tsv')}")
    print(f"readme:    {os.path.join(OUT, 'README.txt')}")


if __name__ == "__main__":
    main()
