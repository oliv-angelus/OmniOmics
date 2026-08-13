import os

SCRIPTS = os.path.join(workflow.basedir, "workflow", "scripts")


rule merge_annotated_counts:
    """Joins the raw count matrix with the reference's gene/product table
    (Bakta) and functional annotation (eggNOG: OG, COG, GO, EC, KEGG, PFAM)
    into one "completona" TSV -- this is where the pipeline stops on
    purpose: the design (which sample is which condition, which is the
    reference group) and the statistics (DESeq2) are left to the user's own
    downstream work, same as MAGMA/SIGMA/DOGMA stopping at raw outputs."""
    input:
        counts="results/04_COUNTS/counts.tsv",
        bakta_tsv="results/00_REFERENCE/bakta/reference.tsv",
        eggnog="results/00_REFERENCE/eggnog/reference_annotations.emapper.annotations"
    output:
        tsv="results/05_TABLES/contagem_anotada.tsv"
    params:
        samples=SAMPLES,
        script=os.path.join(SCRIPTS, "merge_annotated_counts.py")
    conda: "../envs/pandas.yaml"
    log: "logs/tables/merge_annotated_counts.log"
    shell:
        # Explicit interpreter -- see the note in 04_strandedness.smk's
        # decide_strandedness rule (PATH can shadow the conda env's python).
        """
        PY="${{CONDA_PREFIX:+$CONDA_PREFIX/bin/}}python"
        "$PY" {params.script} \
            --counts {input.counts} \
            --bakta-tsv {input.bakta_tsv} \
            --eggnog {input.eggnog} \
            --samples {params.samples} \
            --out {output.tsv} > {log} 2>&1
        """

rule qc_summary:
    """One row per sample: fastp retention %, Bowtie2 alignment %,
    featureCounts assigned %, detected strandedness -- the automatic
    QC metrics worth alerting on, consolidated
    instead of left scattered across each tool's own report/log."""
    input:
        fastp=expand("results/01_QC/{sample}/{sample}_fastp.json", sample=SAMPLES),
        bowtie2_logs=expand("logs/mapping/{sample}_bowtie2.log", sample=SAMPLES),
        summary="results/04_COUNTS/counts.tsv.summary",
        strand_report="results/03_STRANDEDNESS/strandedness_report.tsv"
    output:
        tsv="results/05_TABLES/qc_summary.tsv"
    params:
        samples=SAMPLES,
        script=os.path.join(SCRIPTS, "qc_summary.py")
    conda: "../envs/pandas.yaml"
    log: "logs/tables/qc_summary.log"
    shell:
        # Explicit interpreter -- see the note in 04_strandedness.smk's
        # decide_strandedness rule (PATH can shadow the conda env's python).
        """
        PY="${{CONDA_PREFIX:+$CONDA_PREFIX/bin/}}python"
        "$PY" {params.script} \
            --fastp {input.fastp} \
            --bowtie2-logs {input.bowtie2_logs} \
            --summary {input.summary} \
            --strand-report {input.strand_report} \
            --samples {params.samples} \
            --out {output.tsv} > {log} 2>&1
        """
