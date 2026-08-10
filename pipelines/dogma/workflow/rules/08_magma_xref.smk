import os
import glob
import csv

# ── Phase 2, mode 2 (PROTOTYPE) ────────────────────────────────────────────
# Cross-references DOGMA's own de novo assembled transcripts (TransDecoder
#.pep, from mode 1/mode 3 -- see DOGMA) against a companion MAGMA run's
# dereplicated MAGs, via DIAMOND blastp against each MAG's own Prodigal/
# Pyrodigal protein predictions -- reusing files MAGMA already produces
# unchanged (results/09_ANNOTATION/mags/prodigal/{mag}/{mag}_proteins.faa)
# and MAGMA's own GTDB-Tk taxonomy per MAG
# (results/08_MAG_TAXONOMY/gtdbtk/gtdbtk.*.summary.tsv), instead of a generic
# public reference like CAT/BAT uses. Rationale: when a site has paired
# metagenome (MAGMA) + metatranscriptome (DOGMA) data, mapping expression to
# that site's own assembled genomes is more rigorous than a generic database
# hit, and needs zero new MAGMA-side work or cross-pipeline execution -- just
# reads a finished MAGMA run's output folder, exposed the same way every
# other non-downloadable DOGMA database is (EUKulele/CAT: empty
# download_options, folder picked + "Validar"'d on the Databases tab,
# config["databases"]["magma_run"] the same as any other database path).
#
# The MAGMA MAG catalog is shared across an entire MAGMA run (MAGMA pools
# every sample's bins together before dereplication -- see
# pool_hq_mags/drep in MAGMA's 06_dereplication_tax.smk), so magma_mag_db
# below builds ONE combined index, same "shared, not per-sample" pattern
# EUKulele/CAT's *_setup rules already use.

MAGMA_RUN_DIR = config.get("databases", {}).get("magma_run", "")


def _magma_mag_protein_files(wildcards):
    pattern = os.path.join(MAGMA_RUN_DIR, "results", "09_ANNOTATION", "mags", "prodigal", "*", "*_proteins.faa")
    return sorted(glob.glob(pattern))


rule magma_mag_db:
    """Concatenates every MAG's own Prodigal protein set from a finished
    MAGMA run into one combined FASTA (headers prefixed '{mag}|' so a
    DIAMOND hit's subject id can be traced back to its source MAG) and
    builds one DIAMOND index from it -- built once, shared across every
    DOGMA sample/domain."""
    output:
        combined="results/08_MAGMA_XREF/_db/magma_mag_proteins.faa",
        dmnd="results/08_MAGMA_XREF/_db/magma_mag_proteins.dmnd"
    params:
        prefix="results/08_MAGMA_XREF/_db/magma_mag_proteins",
        protein_files=_magma_mag_protein_files
    threads: config.get("threads", {}).get("magma_xref", 4)
    conda: "../envs/diamond.yaml"
    log: "logs/magma_xref/magma_mag_db.log"
    shell:
        """: > {output.combined}
        for f in {params.protein_files}; do
            magname=$(basename "$(dirname "$f")")
            sed "s/^>/>${{magname}}|/" "$f" >> {output.combined}
        done
        diamond makedb --in {output.combined} --db {params.prefix} --threads {threads} > {log} 2>&1
        """


rule magma_mag_annotate:
    """DIAMOND blastp of this sample's TransDecoder proteins against the
    combined MAG protein index, then joins each hit's source MAG back to
    that MAG's GTDB-Tk taxonomy call (bac120 and/or ar53 summary, whichever
    the MAGMA run produced) -- gives transcript-to-genome-resolved-taxon
    assignment for free, no separate taxonomic classifier needed for this
    path."""
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        dmnd="results/08_MAGMA_XREF/_db/magma_mag_proteins.dmnd"
    output:
        hits="results/08_MAGMA_XREF/{sample}/{domain}/{sample}_magma_mag_hits.tsv",
        annot="results/08_MAGMA_XREF/{sample}/{domain}/{sample}_magma_mag_annotations.tsv"
    params:
        db_prefix="results/08_MAGMA_XREF/_db/magma_mag_proteins",
        extra=config.get("params", {}).get("magma_xref", "-k 1 -e 0.0001"),
        gtdbtk_dir=lambda wc: os.path.join(MAGMA_RUN_DIR, "results", "08_MAG_TAXONOMY", "gtdbtk")
    threads: config.get("threads", {}).get("magma_xref", 4)
    conda: "../envs/diamond.yaml"
    log: "logs/magma_xref/{sample}_{domain}_magma_mag_annotate.log"
    run:
        shell(
            "diamond blastp -q {input.faa} -d {params.db_prefix} --threads {threads} {params.extra} "
            "--outfmt 6 qseqid sseqid pident length evalue bitscore -o {output.hits} > {log} 2>&1"
        )
        tax = {}
        for summary in glob.glob(os.path.join(params.gtdbtk_dir, "gtdbtk.*.summary.tsv")):
            with open(summary) as fh:
                reader = csv.DictReader(fh, delimiter="\t")
                for row in reader:
                    tax[row["user_genome"]] = row["classification"]
        with open(output.hits) as fh, open(output.annot, "w") as out:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                mag = cols[1].split("|", 1)[0]
                out.write("\t".join(cols + [mag, tax.get(mag, "NA")]) + "\n")
