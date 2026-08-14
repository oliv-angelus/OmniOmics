#!/usr/bin/env python3
"""Generates a synthetic but structurally faithful PRISM run for exercising the
Plots tab end to end.

Same intent and limits as make_magma_test_run.py: every path and column layout
matches what PRISM's own rules produce (see
pipelines/prism/workflow/rules/04_denoise_classify.smk and
workflow/scripts/dada2_pacbio.R), but the numbers are generated, not measured.

What this fixture is FOR, beyond "the analyses run": PRISM is the only pipeline
that builds a real phylogenetic tree, and therefore the only one where UniFrac
and weighted UniFrac are available at all. Those two distances are refused with
an explanatory message on every MAGMA run, so they have never been exercised
against real data by any fixture. This one writes a real Newick tree whose
topology follows the assigned taxonomy, so UniFrac has genuine phylogenetic
structure to find rather than a star.

Files written, in the real locations the loader looks in:
  results/04_DENOISE/dada2/prism_abundance_table.tsv   (the per-lineage table)
  results/04_DENOISE/dada2/prism_asv_counts.tsv        (per-ASV, pre-collapse)
  results/04_DENOISE/dada2/prism_asv_taxonomy.tsv
  results/04_DENOISE/dada2/prism_asv_sequences.fasta
  results/04_DENOISE/dada2/prism_tree.nwk
  results/05_ABUNDANCE_TABLE/prism_abundance_table.tsv (select_abundance_table's
      own copy -- the one load_phyloseq.R prefers, see its ABUNDANCE_FILE_PATTERNS)
"""
import os
import random
import shutil

random.seed(20260812)

# Written under the current user's home by default; set OMNIOMICS_DEMO_RUNS
# and OMNIOMICS_TEST_METADATA to put them elsewhere.
OUT = os.path.join(os.environ.get("OMNIOMICS_DEMO_RUNS",
                                  os.path.expanduser("~/omniomics_demo_runs")),
                   "prism_testrun")
METADATA_DIR = os.environ.get(
    "OMNIOMICS_TEST_METADATA",
    os.path.expanduser("~/Documentos/omniomics_test_metadata"))
METADATA_FILE = os.path.join(METADATA_DIR, "metadata_prism_testrun.tsv")

# Four groups of six. Four (not three, as MAGMA has) so venn_diagram is
# exercised at its documented 4-set cap rather than one below it, and six
# replicates because cooccurrence_network needs MORE than 4 samples per group
# to compute correlations at all.
GROUPS = {
    "sediment": [f"lake_S{i}" for i in range(1, 7)],
    "water":    [f"lake_W{i}" for i in range(1, 7)],
    "biofilm":  [f"lake_B{i}" for i in range(1, 7)],
    "inlet":    [f"lake_I{i}" for i in range(1, 7)],
}
SAMPLES = [s for g in GROUPS.values() for s in g]
GROUP_OF = {s: g for g, ss in GROUPS.items() for s in ss}

# Continuous variables for RDA/envfit, laid along a real gradient so the
# ordination has structure to find. dissolved_oxygen is deliberately
# uninformative -- a negative control.
ENV = {
    "sediment": dict(depth_m=12.0, oxygen_mg_L=1.2, nitrate_uM=48.0, dissolved_organic_C=14.2),
    "water":    dict(depth_m=2.0,  oxygen_mg_L=8.6, nitrate_uM=6.0,  dissolved_organic_C=4.1),
    "biofilm":  dict(depth_m=0.5,  oxygen_mg_L=7.9, nitrate_uM=11.0, dissolved_organic_C=9.8),
    "inlet":    dict(depth_m=1.5,  oxygen_mg_L=9.1, nitrate_uM=22.0, dissolved_organic_C=6.5),
}

# SILVA-style 7-rank lineages (Kingdom..Species), which is what PRISM's DADA2
# path assigns -- NOT the GTDB d__/p__ prefixed form MAGMA uses. Each taxon
# carries a per-group multiplier so differential abundance, indicator species
# and the ordinations all have something real to separate.
TAXA = [
    # (Kingdom, Phylum, Class, Order, Family, Genus, Species), base, multipliers
    (("Bacteria", "Pseudomonadota", "Gammaproteobacteria", "Enterobacterales", "Enterobacteriaceae", "Escherichia", "coli"),
     9000, dict(sediment=0.6, water=1.0, biofilm=0.8, inlet=2.4)),
    (("Bacteria", "Pseudomonadota", "Gammaproteobacteria", "Pseudomonadales", "Pseudomonadaceae", "Pseudomonas", "fluorescens"),
     26000, dict(sediment=0.9, water=1.4, biofilm=2.2, inlet=1.0)),
    (("Bacteria", "Pseudomonadota", "Alphaproteobacteria", "Rhodobacterales", "Rhodobacteraceae", "Rhodobacter", "sphaeroides"),
     18000, dict(sediment=0.5, water=2.1, biofilm=1.2, inlet=0.9)),
    (("Bacteria", "Bacteroidota", "Bacteroidia", "Flavobacteriales", "Flavobacteriaceae", "Flavobacterium", "psychrophilum"),
     21000, dict(sediment=0.7, water=1.8, biofilm=1.5, inlet=1.1)),
    (("Bacteria", "Bacteroidota", "Bacteroidia", "Chitinophagales", "Chitinophagaceae", "Sediminibacterium", "salmoneum"),
     15000, dict(sediment=2.6, water=0.4, biofilm=0.9, inlet=0.7)),
    (("Bacteria", "Actinomycetota", "Actinomycetia", "Micrococcales", "Microbacteriaceae", "Candidatus Aquiluna", "rubra"),
     12000, dict(sediment=0.4, water=2.3, biofilm=1.0, inlet=1.3)),
    (("Bacteria", "Actinomycetota", "Acidimicrobiia", "Acidimicrobiales", "Ilumatobacteraceae", "Ilumatobacter", "coccineus"),
     8000, dict(sediment=1.9, water=0.6, biofilm=0.8, inlet=0.9)),
    (("Bacteria", "Cyanobacteriota", "Cyanophyceae", "Synechococcales", "Synechococcaceae", "Synechococcus", "elongatus"),
     30000, dict(sediment=0.2, water=2.8, biofilm=1.6, inlet=1.0)),
    (("Bacteria", "Cyanobacteriota", "Cyanophyceae", "Nostocales", "Nostocaceae", "Dolichospermum", "flos-aquae"),
     6000, dict(sediment=0.3, water=2.0, biofilm=0.7, inlet=0.6)),
    (("Bacteria", "Bacillota", "Clostridia", "Eubacteriales", "Clostridiaceae", "Clostridium", "butyricum"),
     11000, dict(sediment=2.9, water=0.2, biofilm=0.5, inlet=0.8)),
    (("Bacteria", "Bacillota", "Bacilli", "Lactobacillales", "Streptococcaceae", "Lactococcus", "lactis"),
     4000, dict(sediment=0.5, water=0.7, biofilm=1.1, inlet=2.2)),
    (("Bacteria", "Verrucomicrobiota", "Verrucomicrobiae", "Verrucomicrobiales", "Verrucomicrobiaceae", "Prosthecobacter", "debontii"),
     7000, dict(sediment=1.2, water=1.0, biofilm=1.9, inlet=0.6)),
    (("Bacteria", "Planctomycetota", "Planctomycetia", "Planctomycetales", "Planctomycetaceae", "Planctomyces", "brasiliensis"),
     9500, dict(sediment=1.5, water=0.9, biofilm=2.1, inlet=0.5)),
    (("Bacteria", "Acidobacteriota", "Acidobacteriae", "Acidobacteriales", "Acidobacteriaceae", "Granulicella", "mallensis"),
     5500, dict(sediment=2.4, water=0.3, biofilm=0.6, inlet=0.5)),
    (("Bacteria", "Chloroflexota", "Anaerolineae", "Anaerolineales", "Anaerolineaceae", "Anaerolinea", "thermophila"),
     6500, dict(sediment=2.7, water=0.2, biofilm=0.6, inlet=0.4)),
    (("Bacteria", "Nitrospirota", "Nitrospiria", "Nitrospirales", "Nitrospiraceae", "Nitrospira", "moscoviensis"),
     8500, dict(sediment=1.8, water=0.8, biofilm=1.4, inlet=1.0)),
    (("Archaea", "Thermoproteota", "Nitrososphaeria", "Nitrososphaerales", "Nitrososphaeraceae", "Nitrosopumilus", "maritimus"),
     10000, dict(sediment=1.6, water=1.3, biofilm=0.7, inlet=0.9)),
    (("Archaea", "Euryarchaeota", "Methanomicrobia", "Methanosarcinales", "Methanosarcinaceae", "Methanosarcina", "barkeri"),
     4500, dict(sediment=3.1, water=0.0, biofilm=0.2, inlet=0.3)),
    # Group-exclusive pair, so venn_diagram / upset_plot / indicator_species
    # each have a genuinely exclusive taxon to find rather than only shared ones.
    (("Bacteria", "Campylobacterota", "Campylobacteria", "Campylobacterales", "Sulfurimonadaceae", "Sulfurimonas", "denitrificans"),
     7200, dict(sediment=2.5, water=0.0, biofilm=0.0, inlet=0.0)),
    (("Bacteria", "Pseudomonadota", "Betaproteobacteria", "Burkholderiales", "Comamonadaceae", "Acidovorax", "temperans"),
     6800, dict(sediment=0.0, water=0.0, biofilm=0.0, inlet=2.7)),
    # Rare everywhere: exercises Good's coverage / rarefaction singleton logic.
    (("Bacteria", "Deinococcota", "Deinococci", "Deinococcales", "Deinococcaceae", "Deinococcus", "radiodurans"),
     280, dict(sediment=1.0, water=1.0, biofilm=1.0, inlet=1.0)),
]

RANKS = ["Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species"]
# The prefixes dada2_pacbio.R writes into the collapsed `tax` lineage string.
RANK_PREFIXES = ["k__", "p__", "c__", "o__", "f__", "g__", "s__"]

# Each taxon is represented by 2-3 ASVs -- real DADA2 output has several
# distinct sequences resolving to the same assigned lineage, which is exactly
# why the pipeline keeps a per-ASV table alongside the collapsed one.
ASVS_PER_TAXON = (2, 3)


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def tsv(rows):
    return "\n".join("\t".join(str(c) for c in r) for r in rows) + "\n"


def lineage_string(ranks):
    return ";".join(p + r for p, r in zip(RANK_PREFIXES, ranks))


def make_sequence(length=1400):
    """A 16S-length sequence. Not biologically meaningful -- nothing in the
    Plots tab reads it -- but the file is part of the real output shape."""
    return "".join(random.choice("ACGT") for _ in range(length))


def newick_from_taxonomy(asv_rows):
    """A real Newick tree whose topology follows the assigned taxonomy:
    ASVs nest inside genus inside family inside ... inside kingdom.

    Built this way rather than at random because UniFrac measures the branch
    length shared between communities -- on a star topology (every tip
    attached to one root at equal distance) it degenerates toward a plain
    presence/absence distance and the fixture would not actually be testing
    the phylogenetic part. A taxonomy-shaped tree makes two Cyanobacteria
    genuinely closer to each other than either is to an archaeon, which is
    what makes a UniFrac result interpretable at all.

    Branch lengths shrink with depth (0.30 at kingdom down to ~0.01 between
    ASVs of one genus), the usual shape of a real 16S tree.
    """
    depth_len = [0.30, 0.18, 0.11, 0.07, 0.045, 0.025, 0.012]

    def build(rows, depth):
        # rows: list of (asv_id, ranks). At the last rank, emit the tips.
        if depth == len(RANKS):
            return [f"{asv_id}:{depth_len[-1]:.4f}" for asv_id, _ in rows]
        groups = {}
        for asv_id, ranks in rows:
            groups.setdefault(ranks[depth], []).append((asv_id, ranks))
        parts = []
        for key in sorted(groups):
            children = build(groups[key], depth + 1)
            if len(children) == 1 and depth > 0:
                # A clade with a single child adds no structure; splice it out
                # rather than emitting a one-child node, which several Newick
                # readers accept but ape renders as a spurious internal node.
                parts.append(children[0])
            else:
                parts.append("(" + ",".join(children) + f"):{depth_len[depth]:.4f}")
        return parts

    return "(" + ",".join(build(asv_rows, 0)) + ");\n"


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    res = os.path.join(OUT, "results")

    # --- metadata ------------------------------------------------------
    meta_rows = [["SampleID", "habitat", "depth_m", "oxygen_mg_L", "nitrate_uM", "dissolved_organic_C"]]
    for s in SAMPLES:
        e = ENV[GROUP_OF[s]]
        meta_rows.append([
            s, GROUP_OF[s],
            round(e["depth_m"] * random.uniform(0.85, 1.15), 2),
            round(e["oxygen_mg_L"] * random.uniform(0.9, 1.1), 2),
            round(e["nitrate_uM"] * random.uniform(0.8, 1.2), 1),
            round(e["dissolved_organic_C"] * random.uniform(0.85, 1.15), 2),
        ])
    os.makedirs(METADATA_DIR, exist_ok=True)
    w(METADATA_FILE, tsv(meta_rows))

    # --- ASVs, their counts and their taxonomy -------------------------
    asv_rows = []          # (asv_id, ranks)
    asv_counts = {}        # asv_id -> {sample: count}
    asv_seqs = {}
    next_id = 1
    for ranks, base, mult in TAXA:
        n_asvs = random.randint(*ASVS_PER_TAXON)
        # The taxon's abundance is split unevenly across its ASVs, as real
        # DADA2 output is -- one dominant variant plus rarer ones.
        weights = [random.uniform(0.5, 1.0)] + [random.uniform(0.05, 0.3) for _ in range(n_asvs - 1)]
        total_w = sum(weights)
        for k in range(n_asvs):
            asv_id = f"ASV{next_id}"
            next_id += 1
            asv_rows.append((asv_id, ranks))
            asv_seqs[asv_id] = make_sequence()
            share = weights[k] / total_w
            counts = {}
            for s in SAMPLES:
                m = mult[GROUP_OF[s]]
                lam = base * share * m
                counts[s] = 0 if lam == 0 else max(0, int(random.gauss(lam, lam * 0.18)))
            asv_counts[asv_id] = counts

    dada_dir = os.path.join(res, "04_DENOISE", "dada2")

    w(os.path.join(dada_dir, "prism_asv_counts.tsv"),
      tsv([["asv_id"] + SAMPLES] + [[a] + [asv_counts[a][s] for s in SAMPLES] for a, _ in asv_rows]))

    w(os.path.join(dada_dir, "prism_asv_taxonomy.tsv"),
      tsv([["asv_id", "lineage"] + RANKS]
          + [[a, lineage_string(r)] + list(r) for a, r in asv_rows]))

    w(os.path.join(dada_dir, "prism_asv_sequences.fasta"),
      "".join(f">{a}\n{asv_seqs[a]}\n" for a, _ in asv_rows))

    w(os.path.join(dada_dir, "prism_tree.nwk"), newick_from_taxonomy(asv_rows))

    # --- Collapsed per-lineage abundance table -------------------------
    # rowsum over ASVs sharing an assigned lineage, exactly what
    # dada2_pacbio.R does before writing prism_abundance_table.tsv.
    collapsed = {}
    for asv_id, ranks in asv_rows:
        key = lineage_string(ranks)
        row = collapsed.setdefault(key, {s: 0 for s in SAMPLES})
        for s in SAMPLES:
            row[s] += asv_counts[asv_id][s]

    abundance_rows = [["tax"] + SAMPLES + ["total"]]
    for lineage in sorted(collapsed):
        counts = [collapsed[lineage][s] for s in SAMPLES]
        abundance_rows.append([lineage] + counts + [sum(counts)])
    abundance_tsv = tsv(abundance_rows)

    # Written twice, in both real locations: the denoiser's own output and
    # select_abundance_table's copy. load_phyloseq.R prefers the latter (see
    # its ABUNDANCE_FILE_PATTERNS `prefer`), and having both present is what
    # makes that disambiguation actually exercised rather than assumed.
    w(os.path.join(dada_dir, "prism_abundance_table.tsv"), abundance_tsv)
    w(os.path.join(res, "05_ABUNDANCE_TABLE", "prism_abundance_table.tsv"), abundance_tsv)

    # The Emu (ONT) branch's placeholder: select_abundance_table touches the
    # unused platform's file, so a real run has an EMPTY one sitting there.
    # Reproduced because it is precisely what the `prefer` rule disambiguates.
    w(os.path.join(res, "04_DENOISE", "emu", "prism_abundance_table.tsv"), "")

    w(os.path.join(OUT, "config", "config.yaml"),
      '{"samples": %s, "platform": "pacbio", "note": "synthetic PRISM fixture"}\n' % (
          "[" + ", ".join(f'"{s}"' for s in SAMPLES) + "]"))

    print(f"run:      {OUT}")
    print(f"metadata: {METADATA_FILE}")
    print(f"samples:  {len(SAMPLES)} in {len(GROUPS)} groups")
    print(f"taxa:     {len(TAXA)} lineages from {len(asv_rows)} ASVs")
    print(f"tree:     prism_tree.nwk, {len(asv_rows)} tips (UniFrac available)")
    print(f"files:    {sum(len(f) for _, _, f in os.walk(OUT))}")


if __name__ == "__main__":
    main()
