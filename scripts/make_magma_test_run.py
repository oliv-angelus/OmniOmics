#!/usr/bin/env python3
"""Generates a synthetic but structurally faithful MAGMA run for exercising the
Plots tab end to end.

Everything written here matches the real column layouts MAGMA's own rules
produce (see pipelines/magma/workflow/rules/*.smk), so the loaders and analyses
are tested against the shapes they will actually meet -- but the numbers are
generated, not measured. This is a fixture for checking that every analysis
runs, renders and reacts to its parameters; it is not a substitute for running
the pipeline on real data.

Design choices that matter for what the fixture can test:

* 18 samples in 3 groups of 6. Six replicates is set by the strictest consumer:
  cooccurrence_network needs MORE than 4 samples per group to compute
  correlations at all, and four replicates made it skip every group. Six also
  gives DESeq2 comfortable dispersion estimates and PERMANOVA enough
  permutations, while three groups mean UpSet/Venn have more than a pairwise
  comparison to draw and reference_group has real alternatives to choose from.
* Continuous metadata (pH, temperature, organic matter, heavy metals) laid out
  along the contamination gradient, so RDA has real structure to find instead
  of noise.
* 9 MAGs deliberately spanning every MIMAG branch, including the two cases that
  are easy to get wrong: high completeness/contamination that still fails on
  rRNA, and the same failing on tRNA count.
"""
import json
import os
import random
import shutil

random.seed(20260810)

# Written under the current user's home by default; set OMNIOMICS_DEMO_RUNS
# and OMNIOMICS_TEST_METADATA to put them elsewhere.
OUT = os.path.join(os.environ.get("OMNIOMICS_DEMO_RUNS",
                                  os.path.expanduser("~/omniomics_demo_runs")),
                   "magma_testrun")
METADATA_DIR = os.environ.get(
    "OMNIOMICS_TEST_METADATA",
    os.path.expanduser("~/Documentos/omniomics_test_metadata"))
METADATA_FILE = os.path.join(METADATA_DIR, "metadata_magma_testrun.tsv")

GROUPS = {
    "control":  [f"soil_C{i}" for i in range(1, 7)],
    "moderate": [f"soil_M{i}" for i in range(1, 7)],
    "polluted": [f"soil_P{i}" for i in range(1, 7)],
}
SAMPLES = [s for g in GROUPS.values() for s in g]
GROUP_OF = {s: g for g, ss in GROUPS.items() for s in ss}

# Continuous variables follow the gradient so RDA/envfit have signal: pH drops
# and metals rise with contamination, organic matter falls, temperature is
# deliberately uninformative (a negative control for the ordination).
ENV = {
    "control":  dict(pH=7.2, temperature_C=18.0, organic_matter_pct=6.4, heavy_metal_ppm=12),
    "moderate": dict(pH=6.3, temperature_C=18.4, organic_matter_pct=4.1, heavy_metal_ppm=180),
    "polluted": dict(pH=5.1, temperature_C=18.2, organic_matter_pct=2.2, heavy_metal_ppm=940),
}

# Taxa carry a per-group multiplier so differential abundance, indicator
# species and the ordinations all have something real to separate.
TAXA = [
    # (lineage, base_reads, {group: multiplier})
    ("d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Enterobacterales;f__Enterobacteriaceae;g__Escherichia;s__Escherichia coli",
     42000, dict(control=1.0, moderate=1.1, polluted=1.2)),
    ("d__Bacteria;p__Bacillota;c__Bacilli;o__Bacillales;f__Bacillaceae;g__Bacillus;s__Bacillus subtilis",
     68000, dict(control=1.6, moderate=1.0, polluted=0.35)),
    ("d__Bacteria;p__Actinomycetota;c__Actinomycetia;o__Streptomycetales;f__Streptomycetaceae;g__Streptomyces;s__Streptomyces coelicolor",
     51000, dict(control=1.4, moderate=1.1, polluted=0.5)),
    ("d__Bacteria;p__Pseudomonadota;c__Alphaproteobacteria;o__Rhizobiales;f__Rhizobiaceae;g__Rhizobium;s__Rhizobium leguminosarum",
     37000, dict(control=1.9, moderate=0.9, polluted=0.2)),
    ("d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Pseudomonadales;f__Pseudomonadaceae;g__Pseudomonas;s__Pseudomonas putida",
     45000, dict(control=0.4, moderate=1.2, polluted=2.3)),
    ("d__Bacteria;p__Actinomycetota;c__Actinomycetia;o__Mycobacteriales;f__Mycobacteriaceae;g__Mycobacterium;s__Mycobacterium gilvum",
     22000, dict(control=0.3, moderate=1.0, polluted=2.8)),
    ("d__Bacteria;p__Bacteroidota;c__Bacteroidia;o__Bacteroidales;f__Bacteroidaceae;g__Bacteroides;s__Bacteroides fragilis",
     18000, dict(control=1.1, moderate=1.0, polluted=0.9)),
    ("d__Bacteria;p__Acidobacteriota;c__Acidobacteriae;o__Acidobacteriales;f__Acidobacteriaceae;g__Acidobacterium;s__Acidobacterium capsulatum",
     29000, dict(control=0.6, moderate=1.3, polluted=2.0)),
    ("d__Bacteria;p__Chloroflexota;c__Chloroflexia;o__Chloroflexales;f__Chloroflexaceae;g__Chloroflexus;s__Chloroflexus aurantiacus",
     15000, dict(control=1.2, moderate=1.0, polluted=0.8)),
    ("d__Bacteria;p__Verrucomicrobiota;c__Verrucomicrobiae;o__Verrucomicrobiales;f__Verrucomicrobiaceae;g__Akkermansia;s__Akkermansia muciniphila",
     11000, dict(control=1.5, moderate=0.8, polluted=0.3)),
    ("d__Bacteria;p__Cyanobacteriota;c__Cyanophyceae;o__Synechococcales;f__Synechococcaceae;g__Synechococcus;s__Synechococcus elongatus",
     9000, dict(control=1.3, moderate=1.0, polluted=0.6)),
    ("d__Archaea;p__Thermoproteota;c__Nitrososphaeria;o__Nitrososphaerales;f__Nitrososphaeraceae;g__Nitrososphaera;s__Nitrososphaera viennensis",
     14000, dict(control=1.7, moderate=1.0, polluted=0.4)),
    # Present only in polluted soils -- gives indicator_species and the Venn/
    # UpSet set logic a genuinely group-exclusive taxon to find.
    ("d__Bacteria;p__Pseudomonadota;c__Betaproteobacteria;o__Burkholderiales;f__Comamonadaceae;g__Comamonas;s__Comamonas testosteroni",
     16000, dict(control=0.0, moderate=0.15, polluted=2.4)),
    # Present only in controls -- the mirror case.
    ("d__Bacteria;p__Bacillota;c__Clostridia;o__Eubacteriales;f__Clostridiaceae;g__Clostridium;s__Clostridium botulinum",
     8000, dict(control=1.8, moderate=0.1, polluted=0.0)),
    # Rare everywhere: exercises Good's coverage / rarefaction singleton logic.
    ("d__Bacteria;p__Deinococcota;c__Deinococci;o__Deinococcales;f__Deinococcaceae;g__Deinococcus;s__Deinococcus radiodurans",
     600, dict(control=1.0, moderate=1.0, polluted=1.0)),
]

# Nine MAGs covering every MIMAG branch. `rrna` is (5S, 16S, 23S) counts and
# `trna` the number of distinct amino-acid types; `None` means the annotation
# file is not written at all, which is what produces the "High (C/C only)"
# label rather than an unqualified high-quality claim.
MAGS = [
    # id suffix, source sample, completeness, contamination, size, rrna, trna, derep, lineage
    ("bin.1", "soil_C1", 98.4, 0.6, 4_910_000, (1, 2, 2), 21, True,
     "d__Bacteria;p__Bacillota;c__Bacilli;o__Bacillales;f__Bacillaceae;g__Bacillus;s__Bacillus subtilis"),
    ("bin.2", "soil_C3", 94.1, 2.2, 3_640_000, (1, 1, 1), 19, True,
     "d__Bacteria;p__Pseudomonadota;c__Alphaproteobacteria;o__Rhizobiales;f__Rhizobiaceae;g__Rhizobium;s__Rhizobium leguminosarum"),
    # High C/C but NO 23S -> must fall to Medium, not High.
    ("bin.3", "soil_M1", 96.8, 1.4, 5_120_000, (1, 1, 0), 20, True,
     "d__Bacteria;p__Actinomycetota;c__Actinomycetia;o__Streptomycetales;f__Streptomycetaceae;g__Streptomyces;s__Streptomyces coelicolor"),
    # High C/C but only 11 tRNA types -> Medium.
    ("bin.4", "soil_M2", 93.2, 3.1, 4_270_000, (1, 1, 1), 11, True,
     "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Pseudomonadales;f__Pseudomonadaceae;g__Pseudomonas;s__Pseudomonas putida"),
    # No rRNA/tRNA annotation at all -> "High (C/C only)".
    ("bin.5", "soil_P1", 95.5, 1.9, 3_980_000, None, None, True,
     "d__Bacteria;p__Actinomycetota;c__Actinomycetia;o__Mycobacteriales;f__Mycobacteriaceae;g__Mycobacterium;s__Mycobacterium gilvum"),
    ("bin.6", "soil_P2", 72.6, 4.4, 2_880_000, (1, 1, 1), 18, True,
     "d__Bacteria;p__Acidobacteriota;c__Acidobacteriae;o__Acidobacteriales;f__Acidobacteriaceae;g__Acidobacterium;s__Acidobacterium capsulatum"),
    ("bin.7", "soil_P3", 58.3, 8.7, 2_140_000, (0, 1, 0), 14, True,
     "d__Bacteria;p__Pseudomonadota;c__Betaproteobacteria;o__Burkholderiales;f__Comamonadaceae;g__Comamonas;s__Comamonas testosteroni"),
    # Low by completeness.
    ("bin.8", "soil_C2", 41.7, 2.8, 1_520_000, (0, 1, 0), 9, False,
     "d__Archaea;p__Thermoproteota;c__Nitrososphaeria;o__Nitrososphaerales;f__Nitrososphaeraceae;g__Nitrososphaera;s__Nitrososphaera viennensis"),
    # Low by contamination despite being near-complete.
    ("bin.9", "soil_M4", 91.8, 14.2, 6_310_000, (1, 1, 1), 20, False,
     "d__Bacteria;p__Bacteroidota;c__Bacteroidia;o__Bacteroidales;f__Bacteroidaceae;g__Bacteroides;s__Bacteroides fragilis"),
]

AMR_GENES = {
    "bin.4": [("blaTEM-1", "beta-lactam"), ("sul1", "sulfonamide"), ("tetA", "tetracycline")],
    "bin.5": [("mexB", "efflux"), ("catA1", "phenicol")],
    "bin.7": [("blaOXA-10", "beta-lactam"), ("aadA1", "aminoglycoside"), ("sul1", "sulfonamide"), ("merA", "mercury")],
    "bin.9": [("ermF", "macrolide")],
}
VF_GENES = {
    "bin.1": ["fliC", "cheA"],
    "bin.4": ["exoS", "lasB", "plcH"],
    "bin.7": ["hlyA"],
}

# Bins GUNC flags as chimeric despite CheckM2 alone looking fine for them --
# bin.2 (94.1% complete / 2.2% contamination, otherwise "High") and bin.6
# (72.6% / 4.4%, already "Medium") -- so the fixture exercises a MAG whose
# GUNC failure is the ONLY sign of a real problem, the exact case the tool
# exists to catch.
GUNC_FAIL_BINS = {"bin.2", "bin.6"}

AMINO_ACIDS = ("Ala Arg Asn Asp Cys Gln Glu Gly His Ile Leu Lys Met Phe Pro "
               "Ser Thr Trp Tyr Val").split()

DNA_ALPHABET = "ACGT"
AA_ALPHABET = "ACDEFGHIKLMNPQRSTVWY"  # 20 standard one-letter codes, no stop


def random_dna(n):
    return "".join(random.choice(DNA_ALPHABET) for _ in range(n))


def random_protein(n):
    return "".join(random.choice(AA_ALPHABET) for _ in range(n))


def fasta_record(header, seq, width=70):
    lines = [f">{header}"]
    for i in range(0, len(seq), width):
        lines.append(seq[i:i + width])
    return "\n".join(lines) + "\n"


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def tsv(rows):
    return "\n".join("\t".join(str(c) for c in r) for r in rows) + "\n"


def jitter(x, frac=0.12):
    return max(0.0, x * random.uniform(1 - frac, 1 + frac))


def build_abundance(scale=1.0, noise=0.12):
    """Counts per taxon per sample, with the group multipliers applied."""
    rows = [["tax"] + SAMPLES + ["total"]]
    for lineage, base, mult in TAXA:
        counts = []
        for s in SAMPLES:
            m = mult[GROUP_OF[s]]
            counts.append(int(jitter(base * m * scale, noise)))
        rows.append([lineage] + counts + [sum(counts)])
    return tsv(rows)


# Every 09_ANNOTATION/mags/* rule computes its own per-MAG output prefix as
# `magname=$(basename "$f".fa)` -- a real, pre-existing MAGMA bug (confirmed
# by reading and literally running that line): with $f ending in ".../{mag}.fa",
# `"$f".fa` concatenates an unintended second ".fa" before basename strips the
# path, so on disk the prefix is genuinely "{mag}.fa.fa". Reproduced here
# rather than "fixed" in the fixture, since the fixture's entire point is to
# match what the pipeline actually writes.
def mag_shell_name(mag):
    return f"{mag}.fa.fa"


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    res = os.path.join(OUT, "results")

    # --- metadata -------------------------------------------------------
    meta_rows = [["SampleID", "group", "pH", "temperature_C", "organic_matter_pct", "heavy_metal_ppm"]]
    for s in SAMPLES:
        e = ENV[GROUP_OF[s]]
        meta_rows.append([
            s, GROUP_OF[s],
            round(jitter(e["pH"], 0.04), 2),
            round(jitter(e["temperature_C"], 0.05), 1),
            round(jitter(e["organic_matter_pct"], 0.15), 2),
            int(jitter(e["heavy_metal_ppm"], 0.20)),
        ])
    os.makedirs(METADATA_DIR, exist_ok=True)
    w(METADATA_FILE, tsv(meta_rows))

    # --- 01_QC ------------------------------------------------------------
    # fastp's real JSON shape (confirmed: summary.before_filtering /
    # summary.after_filtering, each with total_reads, total_bases, q30_rate,
    # gc_content). This fixture is short-read throughout, so every sample
    # gets a real fastp report; a hybrid/long-read-only MAGMA run would also
    # have nanoplot_raw/nanoplot_clean's NanoStats.txt, which
    # build_magma_qc_table.R reads when present and skips when not.
    for s in SAMPLES:
        raw_reads = random.randint(1_400_000, 2_600_000)
        raw_bases = raw_reads * random.randint(140, 155)
        # Real fastp behavior: filtering drops 2-8% of reads, and the
        # surviving ones average slightly higher quality/GC than the input.
        kept_frac = random.uniform(0.92, 0.98)
        clean_reads = int(raw_reads * kept_frac)
        clean_bases = int(raw_bases * kept_frac * random.uniform(0.97, 0.995))
        gc_before = round(random.uniform(0.50, 0.58), 4)
        gc_after = round(gc_before + random.uniform(-0.005, 0.005), 4)
        q30_before = round(random.uniform(0.88, 0.93), 4)
        q30_after = round(min(0.999, q30_before + random.uniform(0.02, 0.05)), 4)
        fastp_json = {
            "summary": {
                "before_filtering": {"total_reads": raw_reads, "total_bases": raw_bases,
                                     "q30_rate": q30_before, "gc_content": gc_before},
                "after_filtering": {"total_reads": clean_reads, "total_bases": clean_bases,
                                    "q30_rate": q30_after, "gc_content": gc_after},
            },
            "filtering_result": {
                "passed_filter_reads": clean_reads,
                "low_quality_reads": int(raw_reads * (1 - kept_frac) * 0.6),
                "too_short_reads": int(raw_reads * (1 - kept_frac) * 0.4),
            },
        }
        w(os.path.join(res, "01_QC", s, f"{s}_fastp.json"), json.dumps(fastp_json, indent=2))
        w(os.path.join(res, "01_QC", s, f"{s}_fastp.html"), "<html><!-- demonstration stub --></html>\n")

    # --- Per-sample eggNOG (09_ANNOTATION/{sample}/eggnog) --------------
    # Real 25-column emapper.annotations schema (confirmed against
    # eggNOG-mapper v2's own USAGE.md): COG_category is column 7,
    # KEGG_Pathway column 13. A handful of common real COG letters, weighted
    # so the fixture has a genuine dominant category rather than a flat
    # distribution, plus a realistic share of "-" (eggNOG's own
    # no-assignment marker) and a few multi-letter calls (e.g. "EJ").
    EGGNOG_COLUMNS = ["query", "seed_ortholog", "evalue", "score", "eggNOG_OGs", "max_annot_lvl",
                     "COG_category", "Description", "Preferred_name", "GOs", "EC", "KEGG_ko",
                     "KEGG_Pathway", "KEGG_Module", "KEGG_Reaction", "KEGG_rclass", "BRITE",
                     "KEGG_TC", "CAZy", "BiGG_Reaction", "PFAMs", "annotation_confidence",
                     "tax_ceiling", "farthest_donor_taxid", "farthest_donor_lineage"]
    COG_WEIGHTS = [("J", 14), ("K", 9), ("L", 7), ("E", 11), ("C", 8), ("M", 7), ("T", 6),
                   ("P", 6), ("G", 6), ("H", 5), ("O", 5), ("Q", 4), ("R", 8), ("S", 6),
                   ("EJ", 2), ("-", 10)]
    cog_pool = [c for c, w in COG_WEIGHTS for _ in range(w)]

    # Real KEGG pathway IDs, weighted: a prokaryotic genome's annotated genes
    # concentrate heavily on core metabolism and information processing, with
    # a long tail of specialised pathways. Drawing uniformly from the whole ID
    # space instead (as this fixture first did) makes every pathway equally
    # rare, so a top-N plot is ~100% "Others" -- an artefact of the fixture,
    # not something a real run would show.
    KEGG_PATHWAY_WEIGHTS = [
        (2010, 12),  # ABC transporters
        (3010, 10),  # Ribosome
        (10, 9),     # Glycolysis / Gluconeogenesis
        (20, 7),     # Citrate cycle (TCA)
        (190, 7),    # Oxidative phosphorylation
        (230, 6),    # Purine metabolism
        (240, 6),    # Pyrimidine metabolism
        (2020, 6),   # Two-component system
        (3070, 5),   # Bacterial secretion system
        (620, 5),    # Pyruvate metabolism
        (630, 4),    # Glyoxylate and dicarboxylate metabolism
        (500, 4),    # Starch and sucrose metabolism
        (520, 4),    # Amino sugar and nucleotide sugar metabolism
        (330, 3),    # Arginine and proline metabolism
        (260, 3),    # Glycine, serine and threonine metabolism
        (910, 3),    # Nitrogen metabolism
        (920, 3),    # Sulfur metabolism
        (61, 2),     # Fatty acid biosynthesis
        (550, 2),    # Peptidoglycan biosynthesis
        (3440, 2),   # Homologous recombination
    ]
    KEGG_PATHWAY_POOL = ([p for p, wt in KEGG_PATHWAY_WEIGHTS for _ in range(wt)]
                         # long tail: rarely-hit specialised pathways
                         + [random.randint(10, 999) for _ in range(60)])
    # eggNOG-mapper's real default output (--no_file_comments is NOT passed
    # by this pipeline's rule, confirmed reading it): '##'-prefixed banner
    # lines, then the header row itself prefixed with a SINGLE '#'
    # ("#query\t..."), then data rows, then '##'-prefixed footer lines.
    # Written in this real shape -- not a plain header -- so the fixture
    # actually exercises build_magma_functional_table.R's real parsing path
    # (drop '##' lines, keep '#'-prefixed header, strip its leading '#').
    def eggnog_annotations(query_prefix, n_orfs):
        """One emapper.annotations file's text, in eggNOG-mapper v2's real
        default shape. Shared by both levels the pipeline annotates: the
        per-sample assembled metagenome and each individual MAG."""
        lines = ["## demonstration stub -- eggNOG-mapper call info",
                 "#" + "\t".join(EGGNOG_COLUMNS)]
        for i in range(1, n_orfs + 1):
            cog = random.choice(cog_pool)
            annotated = cog != "-"
            # Real KEGG convention: eggNOG reports the SAME pathway under both
            # the "ko" and "map" namespaces in this column. Emitted as the real
            # tool does (both forms), so build_magma_functional_table.R's
            # de-duplication is genuinely exercised instead of assumed.
            if annotated:
                pw_ids = [random.choice(KEGG_PATHWAY_POOL) for _ in range(random.randint(1, 3))]
                kegg_pathway = ",".join([f"ko{p:05d}" for p in pw_ids] + [f"map{p:05d}" for p in pw_ids])
                kegg_ko = ",".join(f"ko:K{random.randint(1, 20000):05d}" for _ in range(random.randint(1, 2)))
                kegg_module = ",".join(f"M{random.randint(1, 900):05d}" for _ in range(random.randint(0, 2))) or "-"
                ec = ",".join(f"{random.randint(1,6)}.{random.randint(1,20)}.{random.randint(1,30)}.{random.randint(1,60)}"
                              for _ in range(random.randint(0, 2))) or "-"
                cazy = random.choice(["-", "-", "-", f"GH{random.randint(1, 160)}", f"GT{random.randint(1, 110)}",
                                      f"CE{random.randint(1, 20)}"])
                pfams = ",".join(f"PF{random.randint(1, 21000):05d}" for _ in range(random.randint(1, 3)))
                gos = ",".join(f"GO:{random.randint(1, 200000):07d}" for _ in range(random.randint(0, 4))) or "-"
            else:
                kegg_pathway = kegg_ko = kegg_module = ec = cazy = pfams = gos = "-"
            lines.append("\t".join(str(v) for v in [
                f"{query_prefix}_orf{i}", f"{random.randint(100000, 999999)}.{random.randint(1000, 9999)}",
                f"{10 ** -random.randint(5, 60):.1e}", round(random.uniform(80, 900), 1),
                "-", "Bacteria", cog, "-" if not annotated else "hypothetical protein",
                "-", gos, ec, kegg_ko, kegg_pathway, kegg_module,
                "-", "-", "-", "-", cazy, "-", pfams,
                random.choice(["low", "medium", "high"]), "2", "2", "Bacteria",
            ]))
        lines.append(f"## {n_orfs} queries scanned")
        lines.append("## demonstration stub -- eggNOG-mapper footer")
        return "\n".join(lines) + "\n"

    for s in SAMPLES:
        w(os.path.join(res, "09_ANNOTATION", s, "eggnog", f"{s}_annotations.emapper.annotations"),
          eggnog_annotations(s, random.randint(320, 620)))

    # --- 03_TAXONOMY ----------------------------------------------------
    w(os.path.join(res, "03_TAXONOMY", "abundance_table_final_RAW.tsv"), build_abundance())
    # Kaiju classifies by translated protein and typically assigns more reads,
    # with its own noise -- generated separately rather than copied, so a
    # classifier-agreement comparison has something real to compare.
    w(os.path.join(res, "03_TAXONOMY", "abundance_table_final_kaiju_RAW.tsv"),
      build_abundance(scale=1.18, noise=0.20))
    for s in SAMPLES:
        w(os.path.join(res, "03_TAXONOMY", s, f"{s}_bracken.kreport"),
          f"# demonstration stub -- Bracken report for {s}\n")
        w(os.path.join(res, "03_TAXONOMY", s, f"{s}.mpa"),
          f"# demonstration stub -- MetaPhlAn-style report for {s}\n")

    # --- 02_ASSEMBLY ----------------------------------------------------
    # QUAST/MetaQuast always writes both report.tsv (rows=metrics,
    # cols=assemblies) AND transposed_report.tsv (rows=assemblies,
    # cols=metrics) -- build_magma_assembly_table.R reads the transposed one,
    # same convention already verified for SIGMA's own .read_quast, so both
    # are written here even though only one is actually consumed.
    for s in SAMPLES:
        n_contigs = random.randint(180, 420)
        total_len = random.randint(18_000_000, 46_000_000)
        largest = random.randint(int(total_len * 0.02), int(total_len * 0.08))
        n50 = random.randint(9_000, 41_000)
        gc = round(random.uniform(52.0, 64.0), 2)
        l50 = random.randint(150, 900)
        report_rows = [["Assembly", s], ["# contigs", n_contigs], ["Total length", total_len],
                       ["Largest contig", largest], ["GC (%)", gc], ["N50", n50], ["L50", l50]]
        transposed_rows = [["Assembly", "# contigs", "Total length", "Largest contig", "GC (%)", "N50", "L50"],
                           [s, n_contigs, total_len, largest, gc, n50, l50]]
        for sub in ("metaquast", "metaquast_prokaryotic"):
            w(os.path.join(res, "02_ASSEMBLY", s, sub, "report.tsv"), tsv(report_rows))
            w(os.path.join(res, "02_ASSEMBLY", s, sub, "transposed_report.tsv"), tsv(transposed_rows))

    # --- 05_BINNING / 06_MAG_REFINEMENT ---------------------------------
    # One real (if short) random contig per MAG, reused everywhere that MAG's
    # assembly is expected on disk -- long enough that VFDB's coordinate
    # slicing (see below) always lands inside real sequence, short enough
    # that the fixture stays fast to generate and to read.
    mag_genome = {}
    for suffix, sample, comp, cont, size, rrna, trna, derep, lineage in MAGS:
        mag = f"{sample}_{suffix}"
        mag_genome[mag] = random_dna(random.randint(4000, 9000))

    by_sample = {}
    for suffix, sample, comp, cont, size, rrna, trna, derep, lineage in MAGS:
        by_sample.setdefault(sample, []).append((suffix, comp, cont, size))
    for s in SAMPLES:
        for binner in ("metabat2", "semibin2", "maxbin2", "vamb"):
            w(os.path.join(res, "05_BINNING", s, binner, "bin.1.fa"),
              fasta_record(f"{s}_{binner}_contig1", random_dna(2000)))
        rows = [["Name", "Completeness", "Contamination", "Genome_Size",
                 "Completeness_Model_Used", "Additional_Notes"]]
        for suffix, comp, cont, size in by_sample.get(s, []):
            rows.append([f"{s}_{suffix}", comp, cont, size, "Neural Network (Specific Model)", "None"])
        w(os.path.join(res, "06_MAG_REFINEMENT", s, "checkm2", "quality_report.tsv"), tsv(rows))

        # Real 13-column GUNC.{db}.maxCSS_level.tsv schema (confirmed against
        # the tool's own documentation). GUNC_FAIL_BINS deliberately fails a
        # couple of otherwise-decent bins with cross-clade chimerism -- the
        # exact case CheckM2 alone cannot catch -- so the MAG summary table
        # has both pass and fail states to show, not just a column of "yes".
        gunc_rows = [["genome", "n_genes_called", "n_genes_mapped", "n_contigs", "taxonomic_level",
                     "proportion_genes_retained_in_major_clades", "genes_retained_index",
                     "clade_separation_score", "contamination_portion", "n_effective_surplus_clades",
                     "mean_hit_identity", "reference_representation_score", "pass.GUNC"]]
        for suffix, comp, cont, size in by_sample.get(s, []):
            mag = f"{s}_{suffix}"
            n_called = random.randint(2200, 5200)
            n_mapped = int(n_called * random.uniform(0.85, 0.98))
            fails = suffix in GUNC_FAIL_BINS
            css = round(random.uniform(0.55, 0.82), 3) if fails else round(random.uniform(0.02, 0.35), 3)
            gunc_rows.append([
                mag, n_called, n_mapped, random.randint(1, 6), "species",
                round(random.uniform(0.85, 0.99), 3), round(random.uniform(0.70, 0.95), 3),
                css, round(random.uniform(0.15, 0.40), 3) if fails else round(random.uniform(0.0, 0.05), 3),
                random.randint(1, 4) if fails else 0,
                round(random.uniform(0.97, 0.999), 3), round(random.uniform(0.60, 0.90), 3),
                "False" if fails else "True",
            ])
        w(os.path.join(res, "06_MAG_REFINEMENT", s, "gunc", "GUNC.progenomes_2.1.maxCSS_level.tsv"),
          tsv(gunc_rows))
        for suffix, _c, _x, _s in by_sample.get(s, []):
            mag = f"{s}_{suffix}"
            w(os.path.join(res, "06_MAG_REFINEMENT", s, "binette", "final_bins", f"{mag}.fa"),
              fasta_record(f"{mag}_contig1", mag_genome[mag]))

    # --- 07_DEREP -------------------------------------------------------
    for suffix, sample, *_rest in MAGS:
        mag = f"{sample}_{suffix}"
        w(os.path.join(res, "07_DEREP", "all_hq_mags", f"{mag}.fa"),
          fasta_record(f"{mag}_contig1", mag_genome[mag]))
    for suffix, sample, comp, cont, size, rrna, trna, derep, lineage in MAGS:
        if derep:
            mag = f"{sample}_{suffix}"
            w(os.path.join(res, "07_DEREP", "drep_out", "dereplicated_genomes", f"{mag}.fa"),
              fasta_record(f"{mag}_contig1", mag_genome[mag]))
    w(os.path.join(res, "07_DEREP", "drep_out", "data_tables", "Widb.csv"),
      "# demonstration stub -- dRep winner table\n")

    # --- 08_MAG_TAXONOMY ------------------------------------------------
    bac = [["user_genome", "classification", "fastani_ani", "red_value"]]
    ar = [["user_genome", "classification", "fastani_ani", "red_value"]]
    for suffix, sample, comp, cont, size, rrna, trna, derep, lineage in MAGS:
        row = [f"{sample}_{suffix}", lineage,
               round(random.uniform(93.0, 99.6), 2), round(random.uniform(0.72, 0.95), 3)]
        (ar if lineage.startswith("d__Archaea") else bac).append(row)
    w(os.path.join(res, "08_MAG_TAXONOMY", "gtdbtk", "gtdbtk.bac120.summary.tsv"), tsv(bac))
    if len(ar) > 1:
        w(os.path.join(res, "08_MAG_TAXONOMY", "gtdbtk", "gtdbtk.ar53.summary.tsv"), tsv(ar))

    # --- 10_MAG_COVERAGE ------------------------------------------------
    # A MAG is most abundant in the group its source sample belongs to, so the
    # MAG x sample heatmap shows the same gradient the community table does.
    header = ["Genome"] + [f"{s} Relative Abundance (%)" for s in SAMPLES]
    rows = [header]
    for suffix, sample, comp, cont, size, rrna, trna, derep, lineage in MAGS:
        home = GROUP_OF[sample]
        vals = []
        for s in SAMPLES:
            base = 14.0 if GROUP_OF[s] == home else 2.5
            vals.append(round(jitter(base, 0.35), 2))
        rows.append([f"{sample}_{suffix}"] + vals)
    w(os.path.join(res, "10_MAG_COVERAGE", "coverm_coverage.tsv"), tsv(rows))

    # --- 09_ANNOTATION (per MAG) ----------------------------------------
    # Every path below uses mag_shell_name(mag) == "{mag}.fa.fa" -- the real
    # (buggy) prefix MAGMA's own rules compute, not "{mag}" or "{mag}.fa".
    mags_dir = os.path.join(res, "09_ANNOTATION", "mags")
    for suffix, sample, comp, cont, size, rrna, trna, derep, lineage in MAGS:
        mag = f"{sample}_{suffix}"
        shell_name = mag_shell_name(mag)
        genome_seq = mag_genome[mag]
        if rrna is not None:
            lines = ["##gff-version 3"]
            for name, n in zip(("5S_rRNA", "16S_rRNA", "23S_rRNA"), rrna):
                for i in range(n):
                    start = 200 * (i + 1)
                    lines.append(f"{mag}_contig1\tbarrnap:0.9\trRNA\t{start}\t{start + 120}\t"
                                 f"1e-40\t+\t.\tName={name};product={name.replace('_', ' ')}")
            w(os.path.join(mags_dir, "barrnap", f"{shell_name}_rrna.gff"), "\n".join(lines) + "\n")
        if trna is not None:
            rows = ["Sequence\ttRNA\tBounds\ttRNA\tAnti\tIntron Bounds\tInf",
                    "Name  \t#   \tBegin\tEnd\tType\tCodon\tScore",
                    "--------\t----\t-----\t----\t----\t-----\t-----"]
            for i, aa in enumerate(AMINO_ACIDS[:trna], start=1):
                rows.append(f"{mag}\t{i}\t{100 * i}\t{100 * i + 73}\t{aa}\tTGC\t{round(random.uniform(45, 92), 1)}")
            w(os.path.join(mags_dir, "trnascan", f"{shell_name}_trna.out"), "\n".join(rows) + "\n")

        # Real protein sequences, one FASTA record per AMR gene, written where
        # pyrodigal's own rule puts them -- a subdirectory named shell_name,
        # containing "{shell_name}_proteins.faa". AMRFinderPlus's "Protein
        # identifier" column below matches these headers exactly, the same
        # 1:1 lookup attach_gene_sequences() does against a real run.
        amr = AMR_GENES.get(suffix, [])
        faa_records = []
        amr_rows = [["Protein identifier", "Element symbol", "Element name", "Class", "Subclass",
                     "% Coverage of reference", "% Identity to reference"]]
        for gene, cls in amr:
            prot_id = f"{mag}_prot{len(faa_records) + 1}"
            faa_records.append(fasta_record(prot_id, random_protein(random.randint(80, 260))))
            amr_rows.append([prot_id, gene, f"{gene} resistance protein",
                             cls.upper(), cls, round(random.uniform(88, 100), 1), round(random.uniform(90, 100), 1)])
        if faa_records:
            w(os.path.join(mags_dir, "prodigal", shell_name, f"{shell_name}_proteins.faa"),
              "".join(faa_records))
        w(os.path.join(mags_dir, "amrfinder", shell_name, "amrfinder_results.tsv"), tsv(amr_rows))

        # VFDB hits are nucleotide regions on the MAG's own contig -- picking a
        # real, in-bounds [start, end) window of the generated genome sequence
        # means attach_gene_sequences() slicing it back out is a genuine round
        # trip, not a coincidence.
        vf = VF_GENES.get(suffix, [])
        # abricate's coordinates are 1-based, START < END regardless of
        # strand -- these are the columns attach_gene_sequences() reads.
        vf_rows = [["#FILE", "SEQUENCE", "START", "END", "STRAND", "GENE", "COVERAGE",
                    "%COVERAGE", "%IDENTITY", "DATABASE", "PRODUCT"]]
        for j, gene in enumerate(vf):
            span = random.randint(200, 600)
            start = 300 + j * 700
            end = min(start + span, len(genome_seq) - 1)
            vf_rows.append([f"{mag}.fa", f"{mag}_contig1", start, end, "+", gene,
                            f"{start}-{end}/{end - start}", round(random.uniform(90, 100), 2),
                            round(random.uniform(88, 99), 2), "vfdb", f"{gene} virulence factor"])
        w(os.path.join(mags_dir, "vfdb", f"{shell_name}_vfdb_results.tab"), tsv(vf_rows))

        # Per-MAG eggNOG, the second level the pipeline annotates. Gene count
        # is on the scale of a real bacterial genome (~2-3k), which the
        # per-sample files here deliberately are not -- those are downsized
        # stubs, since a real assembled metagenome has hundreds of thousands.
        w(os.path.join(mags_dir, "eggnog", shell_name, f"{shell_name}_annotations.emapper.annotations"),
          eggnog_annotations(mag, random.randint(1800, 3400)))

    # --- config ---------------------------------------------------------
    w(os.path.join(OUT, "config", "config.yaml"),
      json.dumps({"samples": SAMPLES, "note": "synthetic MAGMA fixture"}, indent=2))

    print(f"run:      {OUT}")
    print(f"metadata: {METADATA_FILE}")
    print(f"samples:  {len(SAMPLES)} in {len(GROUPS)} groups")
    print(f"taxa:     {len(TAXA)}")
    print(f"MAGs:     {len(MAGS)} ({sum(1 for m in MAGS if m[7])} dereplicated)")
    print(f"files:    {sum(len(f) for _, _, f in os.walk(OUT))}")


if __name__ == "__main__":
    main()
