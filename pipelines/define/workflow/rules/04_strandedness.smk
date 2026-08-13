import os


rule bed12_from_gff:
    """Bacterial genes are single-exon, so each filtered CDS feature converts
    directly to one BED12 block."""
    input:
        gff="results/00_REFERENCE/bakta/reference_filtered.gff3"
    output:
        bed="results/03_STRANDEDNESS/reference.bed12"
    log: "logs/strandedness/bed12.log"
    shell:
        """
        mkdir -p results/03_STRANDEDNESS
        awk -F'\t' 'BEGIN{{OFS="\t"}} $3=="CDS" {{
            start=$4-1; end=$5;
            match($9, /ID=[^;]+/); id=substr($9, RSTART+3, RLENGTH-3);
            print $1, start, end, id, 0, $7, start, end, 0, 1, end-start, 0
        }}' {input.gff} > {output.bed} 2> {log}
        """

rule infer_experiment:
    input:
        bam="results/02_MAPPING/{sample}/{sample}.sorted.bam",
        bai="results/02_MAPPING/{sample}/{sample}.sorted.bam.bai",
        bed="results/03_STRANDEDNESS/reference.bed12"
    output:
        txt="results/03_STRANDEDNESS/{sample}/infer_experiment.txt"
    params:
        extra=config["params"]["rseqc"]
    conda: "../envs/rseqc.yaml"
    log: "logs/strandedness/{sample}_infer_experiment.log"
    shell:
        """
        mkdir -p results/03_STRANDEDNESS/{wildcards.sample}
        infer_experiment.py -r {input.bed} -i {input.bam} {params.extra} > {output.txt} 2> {log}
        """

rule decide_strandedness:
    """Runs on every sample (not just 1-3 "representative" ones -- cheap
    enough, and avoids picking a representative sample) and applies the
    automatable decision rule: one pattern >90% ->
    stranded forward/reverse; close to 50/50 -> unstranded. Writes both the
    plain value featureCounts consumes and a per-sample audit trail, so the
    threshold actually used is never undocumented -- an undocumented threshold
    is exactly what makes a differential-expression result impossible to
    reproduce later."""
    input:
        reports=expand("results/03_STRANDEDNESS/{sample}/infer_experiment.txt", sample=SAMPLES)
    output:
        strand_value="results/03_STRANDEDNESS/strandedness.txt",
        report="results/03_STRANDEDNESS/strandedness_report.tsv"
    params:
        samples=SAMPLES,
        script=os.path.join(workflow.basedir, "workflow", "scripts", "decide_strandedness.py")
    conda: "../envs/pandas.yaml"
    log: "logs/strandedness/decide.log"
    shell:
        # Explicit interpreter, not a bare `python`: the conda env is active
        # (CONDA_PREFIX is set) but any directory earlier in PATH -- notably
        # OmniOmics' own backend.venv, which the app runs from -- would
        # otherwise shadow it with an interpreter that lacks this env's
        # packages. Falls back to PATH when running without --use-conda.
        """
        PY="${{CONDA_PREFIX:+$CONDA_PREFIX/bin/}}python"
        "$PY" {params.script} \
            --reports {input.reports} \
            --samples {params.samples} \
            --out-value {output.strand_value} \
            --out-report {output.report} > {log} 2>&1
        """
