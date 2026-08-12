#!/usr/bin/env python3
"""Generates a synthetic but structurally faithful DEFINE run for exercising the
Plots tab end to end.

Same intent and limits as make_magma_test_run.py: the column layout matches what
DEFINE's own merge_annotated_counts.py produces (see
pipelines/define/workflow/rules/06_merge.smk and lib/build_count_matrix.R's
DEFINE_ANNOTATION_COLS), but the numbers are generated, not measured.

DEFINE's whole Plots-tab shape is a single file -- results/05_TABLES/
contagem_anotada.tsv -- carrying a fixed annotation block, then one raw-count
column per sample, then a second annotation block. That split layout is real,
not an accident of writing order, and is exactly why build_count_matrix.R
identifies sample columns by SUBTRACTING the known annotation names rather than
by assuming they are contiguous. Reproduced here in the real order so that
logic is genuinely exercised.

Deliberately exercises the enrichment path too: --term_source can be
COG_category (letters concatenated, no delimiter), GOs or KEGG_Pathway (both
comma-separated), and genes are assigned terms in a way that gives the
differentially-expressed set a real, findable enrichment rather than noise.
"""
import os
import random
import shutil

random.seed(20260812)

OUT = "/home/angelo/omniomics_demo_runs/define_testrun"
METADATA_DIR = "/home/angelo/Documentos/omniomics_test_metadata"
METADATA_FILE = os.path.join(METADATA_DIR, "metadata_define_testrun.tsv")

# Three groups, not two: de_upset needs at least TWO non-reference levels to
# have anything to intersect (with one it is just the MA plot), so a two-group
# fixture silently leaves that analysis untested. Same reasoning as DOGMA's.
GROUPS = {
    "control":   [f"strain_C{i}" for i in range(1, 5)],
    "acid":      [f"strain_A{i}" for i in range(1, 5)],
    "oxidative": [f"strain_O{i}" for i in range(1, 5)],
}
SAMPLES = [s for g in GROUPS.values() for s in g]
GROUP_OF = {s: g for g, ss in GROUPS.items() for s in ss}

N_GENES = 1600
CHROMOSOME = "NZ_CP012345.1"

# Functional modules. Each carries a per-group expression multiplier, and every
# gene in the module inherits it -- so a whole COG category / KEGG pathway
# moves together, which is what makes functional_enrichment able to find
# anything at all. A module with a flat multiplier is a real negative control.
MODULES = [
    # (name, COG letters, KEGG pathway, GO terms, share of genes, multipliers)
    ("translation",          "J",  "ko03010", ["GO:0006412", "GO:0003735"], 0.10,
     dict(control=1.0, acid=1.0, oxidative=1.0)),
    ("stress_response",      "OT", "ko02020", ["GO:0006950", "GO:0009408"], 0.08,
     dict(control=0.5, acid=2.6, oxidative=3.1)),
    ("oxidative_defense",    "P",  "ko00480", ["GO:0006979", "GO:0004601"], 0.06,
     dict(control=0.6, acid=0.9, oxidative=4.2)),
    ("acid_tolerance",       "E",  "ko00330", ["GO:0006520", "GO:0008152"], 0.06,
     dict(control=0.7, acid=3.8, oxidative=0.8)),
    ("energy_metabolism",    "C",  "ko00190", ["GO:0006119", "GO:0015078"], 0.12,
     dict(control=1.4, acid=0.6, oxidative=0.7)),
    ("carbohydrate",         "G",  "ko00010", ["GO:0005975", "GO:0016052"], 0.10,
     dict(control=1.2, acid=0.8, oxidative=0.9)),
    ("cell_wall",            "M",  "ko00550", ["GO:0071555", "GO:0009252"], 0.09,
     dict(control=1.0, acid=1.5, oxidative=1.1)),
    ("transcription",        "K",  "ko03020", ["GO:0006355"], 0.09,
     dict(control=1.0, acid=1.1, oxidative=1.2)),
    ("replication_repair",   "L",  "ko03430", ["GO:0006281", "GO:0006260"], 0.08,
     dict(control=0.9, acid=1.0, oxidative=2.2)),
    ("transport",            "EP", "ko02010", ["GO:0055085", "GO:0022857"], 0.12,
     dict(control=1.0, acid=1.3, oxidative=1.0)),
    # No functional assignment at all: eggNOG's "-" marker across the board.
    # A real annotated genome has a solid fraction of these, and their handling
    # (dropped from term2gene, never a term literally named "-") is worth
    # exercising rather than assuming.
    ("hypothetical",         None, None,      None,                          0.10,
     dict(control=1.0, acid=1.0, oxidative=1.0)),
]

PRODUCTS = {
    "translation": "50S ribosomal protein", "stress_response": "universal stress protein",
    "oxidative_defense": "catalase-peroxidase", "acid_tolerance": "glutamate decarboxylase",
    "energy_metabolism": "NADH-quinone oxidoreductase subunit",
    "carbohydrate": "phosphofructokinase", "cell_wall": "penicillin-binding protein",
    "transcription": "RNA polymerase sigma factor", "replication_repair": "DNA repair protein RecN",
    "transport": "ABC transporter permease", "hypothetical": "hypothetical protein",
}

ANNOTATION_HEAD = ["locus_tag", "Chr", "Start", "End", "Strand", "Length"]
ANNOTATION_TAIL = ["Gene", "Product", "eggNOG_OGs", "COG_category", "Description",
                   "GOs", "EC", "KEGG_ko", "KEGG_Pathway", "PFAMs"]


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

    meta_rows = [["SampleID", "condition", "replicate", "od600"]]
    for s in SAMPLES:
        meta_rows.append([s, GROUP_OF[s], s[-1], round(random.uniform(0.4, 0.9), 3)])
    os.makedirs(METADATA_DIR, exist_ok=True)
    w(METADATA_FILE, tsv(meta_rows))

    # Assign each gene to a module, in genome order -- real operons keep
    # functionally related genes adjacent, and Start/End are monotonic in a
    # real annotation table.
    assignments = []
    for name, cog, kegg, gos, share, mult in MODULES:
        assignments += [(name, cog, kegg, gos, mult)] * int(N_GENES * share)
    while len(assignments) < N_GENES:
        assignments.append(assignments[-1])
    random.shuffle(assignments)

    rows = [ANNOTATION_HEAD + SAMPLES + ANNOTATION_TAIL]
    position = 500
    for i, (name, cog, kegg, gos, mult) in enumerate(assignments, start=1):
        length = random.randint(240, 3600)
        start, end = position, position + length - 1
        position = end + random.randint(20, 260)
        locus = f"DEFINE_{i:05d}"

        # Per-gene baseline spans four orders of magnitude, as a real
        # transcriptome does -- a flat baseline would make DESeq2's dispersion
        # estimation and the MA plot's whole x axis meaningless.
        baseline = 10 ** random.uniform(0.6, 3.4)
        counts = []
        for s in SAMPLES:
            lam = baseline * mult[GROUP_OF[s]] * random.uniform(0.75, 1.3)
            counts.append(max(0, int(random.gauss(lam, max(2.0, lam * 0.22)))))

        if cog is None:
            annot = ["-", PRODUCTS[name], "-", "-", "-", "-", "-", "-", "-", "-"]
        else:
            gene_name = f"{name[:3]}{random.choice('ABCDEFGH')}"
            annot = [
                gene_name,
                f"{PRODUCTS[name]} {random.randint(1, 40)}",
                f"COG{random.randint(1000, 4999)}@1|root,{random.randint(1000, 4999)}@2|Bacteria",
                cog,  # concatenated letters, no delimiter -- eggNOG's real form
                f"{PRODUCTS[name]}, {name.replace('_', ' ')} module",
                ",".join(gos),
                f"{random.randint(1,6)}.{random.randint(1,20)}.{random.randint(1,30)}.{random.randint(1,60)}"
                if random.random() < 0.45 else "-",
                f"ko:K{random.randint(1, 20000):05d}",
                kegg,
                ",".join(f"PF{random.randint(1, 21000):05d}" for _ in range(random.randint(1, 3))),
            ]

        rows.append([locus, CHROMOSOME, start, end, random.choice(["+", "-"]), length]
                    + counts + annot)

    w(os.path.join(res, "05_TABLES", "contagem_anotada.tsv"), tsv(rows))

    w(os.path.join(OUT, "config", "config.yaml"),
      '{"samples": %s, "note": "synthetic DEFINE fixture"}\n' % (
          "[" + ", ".join(f'"{s}"' for s in SAMPLES) + "]"))

    print(f"run:      {OUT}")
    print(f"metadata: {METADATA_FILE}")
    print(f"samples:  {len(SAMPLES)} in {len(GROUPS)} groups")
    print(f"genes:    {N_GENES} across {len(MODULES)} functional modules")
    print(f"files:    {sum(len(f) for _, _, f in os.walk(OUT))}")


if __name__ == "__main__":
    main()
