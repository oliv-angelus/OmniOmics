#!/usr/bin/env python3
"""Generates a synthetic but structurally faithful SIGMA run for exercising the
Plots tab end to end.

Same intent and limits as make_magma_test_run.py: every path and column layout
matches what SIGMA's own rules produce, verified against the readers in
lib/build_sigma_table.R (which in turn were written against the pinned tool
versions' real output), but the numbers are generated, not measured.

Two real quirks of SIGMA's output are reproduced ON PURPOSE, because the loader
exists largely to work around them and a fixture that "cleaned them up" would
test nothing:

  * QUAST's own "Assembly" column and CoverM's own "Genome" column are BOTH the
    literal string "final_polished" for every sample -- SIGMA never passes
    --labels, and every sample's fasta is named identically before being handed
    to these tools. Neither can be used as a join key, which is why the loader
    keys everything off the {sample} path segment instead.
  * CoverM bakes the sample name into its own column HEADERS ("{sample} Trimmed
    Mean"), so those are read by name-suffix match, not fixed position.

The genome set deliberately spans the range that makes the quality overview
worth looking at: near-complete high-quality genomes, one borderline draft, and
one genuinely poor assembly that should be visibly separated. One genome is an
archaeon, so the GTDB-Tk reader's ar53-vs-bac120 branch is exercised rather than
assumed, and one has no MLST scheme match (literal "-", which is a real result,
not missing data).
"""
import os
import random
import shutil

random.seed(20260812)

OUT = "/home/angelo/omniomics_demo_runs/sigma_testrun"
METADATA_DIR = "/home/angelo/Documentos/omniomics_test_metadata"
METADATA_FILE = os.path.join(METADATA_DIR, "metadata_sigma_testrun.tsv")

# (sample, source, species lineage, completeness, contamination, size,
#  n_contigs, mlst_scheme, mlst_st, domain_file)
GENOMES = [
    ("iso_EC01", "clinical", "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Enterobacterales;f__Enterobacteriaceae;g__Escherichia;s__Escherichia coli",
     99.6, 0.4, 5_120_000, 84, "ecoli_achtman_4", "131", "bac120"),
    ("iso_EC02", "clinical", "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Enterobacterales;f__Enterobacteriaceae;g__Escherichia;s__Escherichia coli",
     98.9, 1.1, 4_980_000, 121, "ecoli_achtman_4", "10", "bac120"),
    ("iso_KP01", "clinical", "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Enterobacterales;f__Enterobacteriaceae;g__Klebsiella;s__Klebsiella pneumoniae",
     99.2, 0.8, 5_640_000, 96, "klebsiella", "258", "bac120"),
    ("iso_KP02", "environmental", "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Enterobacterales;f__Enterobacteriaceae;g__Klebsiella;s__Klebsiella pneumoniae",
     97.4, 2.3, 5_410_000, 187, "klebsiella", "147", "bac120"),
    ("iso_PA01", "clinical", "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Pseudomonadales;f__Pseudomonadaceae;g__Pseudomonas;s__Pseudomonas aeruginosa",
     99.8, 0.2, 6_310_000, 61, "paeruginosa", "235", "bac120"),
    ("iso_SA01", "clinical", "d__Bacteria;p__Bacillota;c__Bacilli;o__Staphylococcales;f__Staphylococcaceae;g__Staphylococcus;s__Staphylococcus aureus",
     99.1, 0.6, 2_820_000, 47, "saureus", "398", "bac120"),
    ("iso_SA02", "environmental", "d__Bacteria;p__Bacillota;c__Bacilli;o__Staphylococcales;f__Staphylococcaceae;g__Staphylococcus;s__Staphylococcus aureus",
     96.2, 3.4, 2_910_000, 264, "saureus", "8", "bac120"),
    ("iso_BS01", "environmental", "d__Bacteria;p__Bacillota;c__Bacilli;o__Bacillales;f__Bacillaceae;g__Bacillus;s__Bacillus subtilis",
     98.4, 1.0, 4_210_000, 73, "bsubtilis", "62", "bac120"),
    # Borderline draft: passes the usual 90/5 bar but only just, and is
    # visibly more fragmented -- the case a quality overview should surface.
    ("iso_AB01", "environmental", "d__Bacteria;p__Pseudomonadota;c__Gammaproteobacteria;o__Pseudomonadales;f__Moraxellaceae;g__Acinetobacter;s__Acinetobacter baumannii",
     91.3, 4.7, 3_940_000, 512, "abaumannii_2", "2", "bac120"),
    # Genuinely poor: below the bar on both axes, no MLST scheme matched.
    # "-" for scheme/ST is AMRFinder-free real MLST behavior, a meaningful
    # result ("no scheme matched"), not missing data -- kept literal.
    ("iso_UN01", "environmental", "d__Bacteria;p__Bacteroidota;c__Bacteroidia;o__Flavobacteriales;f__Weeksellaceae;g__Chryseobacterium;s__Chryseobacterium indologenes",
     72.8, 8.9, 4_460_000, 1104, "-", "-", "bac120"),
    # Archaeon: GTDB-Tk writes gtdbtk.ar53.summary.tsv instead of bac120,
    # and the reader has to find whichever of the two exists.
    ("iso_MS01", "environmental", "d__Archaea;p__Methanobacteriota;c__Methanobacteria;o__Methanobacteriales;f__Methanobacteriaceae;g__Methanobrevibacter;s__Methanobrevibacter smithii",
     95.7, 1.8, 1_850_000, 118, "-", "-", "ar53"),
]

# AMR genes by species, so the heatmap has real block structure (genes shared
# within a species, a few shared across) instead of noise.
AMR_BY_GENUS = {
    "Escherichia":   [("blaTEM-1", "BETA-LACTAM", "BETA-LACTAM"), ("sul2", "SULFONAMIDE", "SULFONAMIDE"),
                      ("tet(A)", "TETRACYCLINE", "TETRACYCLINE"), ("aph(3'')-Ib", "AMINOGLYCOSIDE", "STREPTOMYCIN")],
    "Klebsiella":    [("blaKPC-2", "BETA-LACTAM", "CARBAPENEM"), ("blaSHV-11", "BETA-LACTAM", "BETA-LACTAM"),
                      ("fosA", "FOSFOMYCIN", "FOSFOMYCIN"), ("oqxA", "PHENICOL/QUINOLONE", "QUINOLONE"),
                      ("sul2", "SULFONAMIDE", "SULFONAMIDE")],
    "Pseudomonas":   [("blaOXA-50", "BETA-LACTAM", "BETA-LACTAM"), ("aph(3')-IIb", "AMINOGLYCOSIDE", "KANAMYCIN"),
                      ("catB7", "PHENICOL", "CHLORAMPHENICOL"), ("fosA", "FOSFOMYCIN", "FOSFOMYCIN")],
    "Staphylococcus": [("mecA", "BETA-LACTAM", "METHICILLIN"), ("blaZ", "BETA-LACTAM", "BETA-LACTAM"),
                       ("tet(K)", "TETRACYCLINE", "TETRACYCLINE"), ("erm(C)", "MACROLIDE", "LINCOSAMIDE")],
    "Bacillus":      [("fosB", "FOSFOMYCIN", "FOSFOMYCIN")],
    "Acinetobacter": [("blaOXA-23", "BETA-LACTAM", "CARBAPENEM"), ("blaADC-25", "BETA-LACTAM", "CEPHALOSPORIN"),
                      ("aph(3')-VIa", "AMINOGLYCOSIDE", "AMIKACIN")],
    "Chryseobacterium": [("blaCIA-1", "BETA-LACTAM", "BETA-LACTAM")],
    "Methanobrevibacter": [],
}

VF_BY_GENUS = {
    "Escherichia": ["fimH", "ompA", "csgA"], "Klebsiella": ["fimA", "mrkD", "entB", "ybtS"],
    "Pseudomonas": ["exoS", "lasA", "toxA", "plcH"], "Staphylococcus": ["hla", "sea", "icaA", "spa"],
    "Bacillus": ["plcR"], "Acinetobacter": ["ompA", "bap"], "Chryseobacterium": [],
    "Methanobrevibacter": [],
}

QUAST_COLUMNS = ["Assembly", "# contigs (>= 0 bp)", "# contigs (>= 1000 bp)", "Total length (>= 0 bp)",
                 "# contigs", "Largest contig", "Total length", "GC (%)", "N50", "N90", "L50", "L90",
                 "# N's per 100 kbp"]
CHECKM2_COLUMNS = ["Name", "Completeness", "Contamination", "Completeness_Model_Used",
                   "Translation_Table_Used", "Coding_Density", "Contig_N50", "Average_Gene_Length",
                   "Genome_Size", "GC_Content", "Total_Coding_Sequences", "Total_Contigs",
                   "Max_Contig_Length", "Additional_Notes"]
GTDBTK_COLUMNS = ["user_genome", "classification", "fastani_reference", "fastani_reference_radius",
                  "fastani_taxonomy", "fastani_ani", "fastani_af", "closest_placement_reference",
                  "closest_placement_taxonomy", "closest_placement_ani", "closest_placement_af",
                  "pplacer_taxonomy", "classification_method", "note", "other_related_references",
                  "msa_percent", "translation_table", "red_value", "warnings"]
AMRFINDER_COLUMNS = ["Protein id", "Contig id", "Start", "Stop", "Strand", "Element symbol",
                     "Element name", "Scope", "Type", "Subtype", "Class", "Subclass", "Method",
                     "Target length", "Reference sequence length", "% Coverage of reference",
                     "% Identity to reference", "Alignment length", "Closest reference accession",
                     "Closest reference name", "HMM accession", "HMM description"]
ABRICATE_COLUMNS = ["#FILE", "SEQUENCE", "START", "END", "STRAND", "GENE", "COVERAGE", "COVERAGE_MAP",
                    "GAPS", "%COVERAGE", "%IDENTITY", "DATABASE", "ACCESSION", "PRODUCT", "RESISTANCE"]


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def tsv(rows):
    return "\n".join("\t".join(str(c) for c in r) for r in rows) + "\n"


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    res = os.path.join(OUT, "results")

    meta_rows = [["SampleID", "source", "species", "collection_year"]]
    for sample, source, lineage, *_ in GENOMES:
        species = lineage.split("s__")[-1]
        meta_rows.append([sample, source, species, random.randint(2019, 2025)])
    os.makedirs(METADATA_DIR, exist_ok=True)
    w(METADATA_FILE, tsv(meta_rows))

    for (sample, source, lineage, compl, contam, size, n_contigs,
         mlst_scheme, mlst_st, domain_file) in GENOMES:
        genus = lineage.split("g__")[-1].split(";")[0]
        gc = round(random.uniform(31, 67), 2)
        n50 = int(size / max(1, n_contigs) * random.uniform(2.5, 6.0))
        largest = int(n50 * random.uniform(1.8, 3.5))
        l50 = max(1, int(n_contigs * random.uniform(0.15, 0.35)))

        # --- QUAST: "Assembly" is the literal "final_polished", NOT the sample
        q = os.path.join(res, "05_QUALITY", sample, "quast", "transposed_report.tsv")
        w(q, tsv([QUAST_COLUMNS, [
            "final_polished", n_contigs + random.randint(0, 40), n_contigs,
            size + random.randint(0, 25_000), n_contigs, largest, size, gc,
            n50, int(n50 * 0.32), l50, int(l50 * 3.4), round(random.uniform(0, 4), 2)]]))

        # --- CheckM2: `Name` IS the sample here (row named after the input file)
        c = os.path.join(res, "05_QUALITY", sample, "checkm2", "quality_report.tsv")
        w(c, tsv([CHECKM2_COLUMNS, [
            sample, compl, contam, "Neural Network (Specific Model)", 11,
            round(random.uniform(0.80, 0.90), 4), n50, round(random.uniform(280, 340), 1),
            size, round(gc / 100, 4), int(size / 1000 * random.uniform(0.85, 1.0)),
            n_contigs, largest, "None"]]))

        # --- GTDB-Tk: exactly ONE of bac120/ar53 exists per single-genome run
        g = os.path.join(res, "06_TAXONOMY", sample, "gtdbtk", f"gtdbtk.{domain_file}.summary.tsv")
        w(g, tsv([GTDBTK_COLUMNS, [
            sample, lineage, f"GCF_{random.randint(100000, 999999)}.1", 95.0, lineage,
            round(random.uniform(96, 99.8), 2), round(random.uniform(0.85, 0.98), 2),
            f"GCF_{random.randint(100000, 999999)}.1", lineage,
            round(random.uniform(96, 99.8), 2), round(random.uniform(0.85, 0.98), 2),
            lineage, "ani_screen", "topological placement and ANI have congruent species assignments",
            "N/A", round(random.uniform(85, 99), 2), 11, "N/A", "N/A"]]))

        # --- CoverM: sample name baked into the HEADERS, "Genome" is a constant
        cov = os.path.join(res, "07_COVERAGE", sample, "coverm_coverage.tsv")
        mean = round(random.uniform(28, 240), 4)
        w(cov, tsv([
            ["Genome", f"{sample} Mean", f"{sample} Trimmed Mean", f"{sample} Covered Fraction"],
            ["final_polished", mean, round(mean * random.uniform(0.9, 1.0), 4),
             round(random.uniform(0.94, 0.999), 4)]]))

        # --- MLST: NO header, ragged trailing allele columns
        alleles = [f"{p}({random.randint(1, 300)})" for p in ("adk", "fumC", "gyrB", "icd", "mdh", "purA", "recA")]
        w(os.path.join(res, "09_TYPING", sample, "mlst.tsv"),
          "\t".join([f"{sample}.fa", mlst_scheme, mlst_st] + (alleles if mlst_scheme != "-" else [])) + "\n")

        # --- AMRFinderPlus (4.2.7 column names: "Element symbol"/"Element name")
        amr = AMR_BY_GENUS.get(genus, [])
        rows = [AMRFINDER_COLUMNS]
        for j, (gene, cls, subcls) in enumerate(amr):
            start = 1000 + j * 3000
            rows.append([f"{sample}_{j:04d}", f"{sample}_contig{j % 5 + 1}", start, start + 860, "+",
                         gene, f"{gene} resistance protein", "core", "AMR", "AMR", cls, subcls,
                         "EXACTX", 287, 287, round(random.uniform(96, 100), 2),
                         round(random.uniform(97, 100), 2), 287,
                         f"WP_{random.randint(100000000, 999999999)}.1",
                         f"{gene} family protein", "NF000270.1", f"{gene} family"])
        w(os.path.join(res, "08_ANNOTATION", sample, "amrfinder", "amrfinder_results.tsv"), tsv(rows))

        # --- ABRicate x3 (ncbi, card, vfdb). A header-only zero-hit file is
        # real, valid behavior -- the header prints unconditionally.
        def abricate(hits, db):
            rows = [ABRICATE_COLUMNS]
            for j, (gene, product, resistance) in enumerate(hits):
                start = 2000 + j * 2500
                rows.append([f"{sample}.fa", f"{sample}_contig{j % 5 + 1}", start, start + 900, "+",
                             gene, f"1-900/900", "===============", 0,
                             round(random.uniform(90, 100), 2), round(random.uniform(95, 100), 2),
                             db, f"ACC_{random.randint(10000, 99999)}", product, resistance])
            return tsv(rows)

        w(os.path.join(res, "08_ANNOTATION", sample, "abricate", "ncbi_results.tab"),
          abricate([(g_, f"{g_} resistance gene", c_) for g_, c_, _ in amr], "ncbi"))
        # CARD reports a subset -- the two databases genuinely disagree on
        # marginal hits, which is worth having in the fixture.
        w(os.path.join(res, "08_ANNOTATION", sample, "abricate", "card_results.tab"),
          abricate([(g_, f"{g_} (CARD)", c_) for g_, c_, _ in amr[: max(0, len(amr) - 1)]], "card"))
        w(os.path.join(res, "08_ANNOTATION", sample, "vfdb", "vfdb_results.tab"),
          abricate([(v, f"{v} virulence factor", "") for v in VF_BY_GENUS.get(genus, [])], "vfdb"))

    w(os.path.join(OUT, "config", "config.yaml"),
      '{"samples": %s, "note": "synthetic SIGMA fixture"}\n' % (
          "[" + ", ".join(f'"{g[0]}"' for g in GENOMES) + "]"))

    print(f"run:      {OUT}")
    print(f"metadata: {METADATA_FILE}")
    print(f"genomes:  {len(GENOMES)} ({sum(1 for g in GENOMES if g[3] >= 90 and g[4] <= 5)} high-quality)")
    print(f"archaea:  {sum(1 for g in GENOMES if g[9] == 'ar53')} (exercises the ar53 branch)")
    print(f"files:    {sum(len(f) for _, _, f in os.walk(OUT))}")


if __name__ == "__main__":
    main()
