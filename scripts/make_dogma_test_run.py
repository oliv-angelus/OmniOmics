#!/usr/bin/env python3
"""Generates a synthetic but structurally faithful DOGMA run for exercising the
Plots tab end to end.

Same intent and limits as make_magma_test_run.py: every path and column layout
matches what DOGMA's own rules actually produce (see
pipelines/dogma/workflow/rules/*.smk and lib/build_dogma_table.R's per-tool
readers), but the numbers are generated, not measured.

Covers the file set build_dogma_table.R actually joins:
  04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep   (the ORF spine)
  06_QUANTIFICATION/{sample}/{domain}/{sample}_quant/quant.sf  (Salmon)
  05_ANNOTATION/{sample}/{domain}/eggnog/...emapper.annotations
  05_ANNOTATION/{sample}/{domain}/ncycdb/{sample}_ncycdb_annotations.tsv
  05_ANNOTATION/{sample}/{domain}/catbat/... (taxonomy, must NOT be split)

Deliberately exercises the term-expansion rules: eggNOG cells carry several
KEGG pathways with the ko/map duplication KEGG really emits, multi-letter COG
categories, and a realistic share of "-" (eggNOG's no-assignment marker).
"""
import os
import random
import shutil

random.seed(20260811)

OUT = "/home/angelo/omniomics_demo_runs/dogma_testrun"
METADATA_DIR = "/home/angelo/Documentos/omniomics_test_metadata"
METADATA_FILE = os.path.join(METADATA_DIR, "metadata_dogma_testrun.tsv")

# Three groups, not two: dogma_de_upset needs at least TWO non-reference
# levels to have anything to intersect (with one it is just the MA plot), so
# a two-group fixture silently leaves that analysis untested.
GROUPS = {"control":  [f"rna_C{i}" for i in range(1, 5)],
          "treated":  [f"rna_T{i}" for i in range(1, 5)],
          "recovery": [f"rna_R{i}" for i in range(1, 5)]}
SAMPLES = [s for g in GROUPS.values() for s in g]
GROUP_OF = {s: g for g, ss in GROUPS.items() for s in ss}
DOMAIN = "prokaryote"

# Pathways carry a per-group multiplier so differential abundance has real
# signal to find rather than noise.
PATHWAYS = [
    ("ko00010", dict(control=1.0, treated=1.0, recovery=1.0)),
    ("ko00020", dict(control=1.8, treated=0.4, recovery=1.5)),
    ("ko00190", dict(control=0.5, treated=2.2, recovery=0.8)),
    ("ko00240", dict(control=1.0, treated=1.1, recovery=1.0)),
    ("ko00500", dict(control=1.3, treated=0.7, recovery=1.2)),
    ("ko00620", dict(control=0.6, treated=1.9, recovery=0.7)),
]
COG_LETTERS = "CEGHJKLMOPQRST"
NCYC_GENES = ["nifH", "nirK", "nosZ", "amoA", "narG", "nrfA"]
# CAT/BAT lineages here are ';'-separated NCBI TAXIDS, not readable names --
# DOGMA's rule never runs `CAT_pack add_names` (confirmed in
# build_dogma_table.R's own reader comment), so this is what the real file
# holds. Written faithfully so the "must not be split" rule is tested against
# the real shape.
LINEAGES = [
    "1;131567;2;1224;1236;72274",
    "1;131567;2;1239;91061;1385",
    "1;131567;2;201174;1760;85011",
]


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def tsv(rows):
    return "\n".join("\t".join(str(c) for c in r) for r in rows) + "\n"


EGGNOG_COLUMNS = ["query", "seed_ortholog", "evalue", "score", "eggNOG_OGs", "max_annot_lvl",
                  "COG_category", "Description", "Preferred_name", "GOs", "EC", "KEGG_ko",
                  "KEGG_Pathway", "KEGG_Module", "KEGG_Reaction", "KEGG_rclass", "BRITE",
                  "KEGG_TC", "CAZy", "BiGG_Reaction", "PFAMs", "annotation_confidence",
                  "tax_ceiling", "farthest_donor_taxid", "farthest_donor_lineage"]


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    res = os.path.join(OUT, "results")

    meta_rows = [["SampleID", "condition"]]
    for s in SAMPLES:
        meta_rows.append([s, GROUP_OF[s]])
    os.makedirs(METADATA_DIR, exist_ok=True)
    w(METADATA_FILE, tsv(meta_rows))

    n_transcripts = 240
    for s in SAMPLES:
        grp = GROUP_OF[s]
        base = os.path.join(res, "05_ANNOTATION", s, DOMAIN)

        # --- ORF spine: TransDecoder names ORFs "{transcript}.p{N}" ---------
        pep, orf_ids, tx_ids = [], [], []
        for t in range(1, n_transcripts + 1):
            tx = f"{s}_TRINITY_DN{t}_c0_g1_i1"
            tx_ids.append(tx)
            orf = f"{tx}.p1"
            orf_ids.append(orf)
            pep.append(f">{orf} type:complete len:120\n" + "M" + "ACDEFGHIKLMNPQRSTVWY" * 6 + "\n")
        w(os.path.join(res, "04_ORF_CALLING", s, DOMAIN, f"{s}_transdecoder.pep"), "".join(pep))

        # --- Salmon, keyed by TRANSCRIPT (not ORF) -------------------------
        # Each ORF is assigned a pathway below; its transcript's read count
        # carries that pathway's per-group multiplier, so the differential
        # signal is real and traceable.
        orf_pathways, quant_rows = {}, [["Name", "Length", "EffectiveLength", "TPM", "NumReads"]]
        for i, (tx, orf) in enumerate(zip(tx_ids, orf_ids)):
            pw, mult = PATHWAYS[i % len(PATHWAYS)]
            orf_pathways[orf] = pw
            reads = max(1, int(random.gauss(400 * mult[grp], 60)))
            quant_rows.append([tx, 1200, 1050.0, round(reads / 10.0, 4), reads])
        w(os.path.join(res, "06_QUANTIFICATION", s, DOMAIN, f"{s}_quant", "quant.sf"), tsv(quant_rows))

        # --- eggNOG: real banner + '#query' header + '##' footer -----------
        lines = ["## demonstration stub -- eggNOG-mapper call info",
                 "#" + "\t".join(EGGNOG_COLUMNS)]
        for i, orf in enumerate(orf_ids):
            # ~15% of ORFs unannotated, written as eggNOG's own "-" marker --
            # the case that used to become a gene family literally named "-".
            if random.random() < 0.15:
                lines.append("\t".join([orf, "-", "-", "-", "-", "-"] + ["-"] * 19))
                continue
            main_pw = orf_pathways[orf]
            extra = [random.choice(PATHWAYS)[0] for _ in range(random.randint(0, 1))]
            pws = list(dict.fromkeys([main_pw] + extra))
            # Both namespaces, exactly as KEGG/eggNOG really emit them.
            kegg_pathway = ",".join(pws + [p.replace("ko", "map") for p in pws])
            # ~20% multi-letter COG ("EJ"), the additive-convention case.
            cog = random.choice(COG_LETTERS)
            if random.random() < 0.20:
                cog += random.choice(COG_LETTERS.replace(cog, ""))
            row = [orf, f"{random.randint(100000, 999999)}.{random.randint(1000, 9999)}",
                   f"{10 ** -random.randint(5, 60):.1e}", round(random.uniform(80, 900), 1),
                   "-", "Bacteria", cog, "hypothetical protein", "-", "-", "-",
                   f"ko:K{random.randint(1, 20000):05d}", kegg_pathway,
                   "-", "-", "-", "-", "-", "-", "-", f"PF{random.randint(1, 21000):05d}",
                   "medium", "2", "2", "Bacteria"]
            lines.append("\t".join(str(v) for v in row))
        lines.append("## demonstration stub -- eggNOG-mapper footer")
        w(os.path.join(base, "eggnog", f"{s}_annotations.emapper.annotations"), "\n".join(lines) + "\n")

        # --- NCycDB: DIAMOND blastp hits, NO header, gene in last column ---
        ncyc_rows = []
        for orf in orf_ids:
            if random.random() < 0.25:
                ncyc_rows.append([orf, f"NCyc_{random.randint(1000, 9999)}",
                                  round(random.uniform(40, 99), 1), random.randint(80, 400),
                                  f"{10 ** -random.randint(5, 60):.1e}", round(random.uniform(60, 700), 1),
                                  random.choice(NCYC_GENES)])
        if ncyc_rows:
            w(os.path.join(base, "ncycdb", f"{s}_ncycdb_annotations.tsv"), tsv(ncyc_rows))

        # --- CAT/BAT: transcript-keyed, ';'-separated LINEAGE --------------
        cat_rows = [["# contig", "classification", "reason", "lineage", "lineage scores"]]
        for tx in tx_ids:
            cat_rows.append([tx, "classified", "based on 5/5 ORFs", random.choice(LINEAGES), "1.00"])
        w(os.path.join(base, "cat", f"{s}.contig2classification.txt"), tsv(cat_rows))

    print(f"run:      {OUT}")
    print(f"metadata: {METADATA_FILE}")
    print(f"samples:  {len(SAMPLES)} in {len(GROUPS)} groups (domain: {DOMAIN})")
    print(f"ORFs:     {n_transcripts} per sample")
    print(f"files:    {sum(len(f) for _, _, f in os.walk(OUT))}")


if __name__ == "__main__":
    main()
