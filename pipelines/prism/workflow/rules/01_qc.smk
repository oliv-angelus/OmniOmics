import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# ---------------------------------------------------------------------------
# Short-read (Illumina) QC -- fastp. Only ever requested for SHORT_SAMPLES
# (see Snakefile's rule all), so unlike MAGMA's fastp/filtlong this needs no
# if/else-touch branching: a sample is either short or long, never both, so
# Snakemake simply never asks this rule to build for a long-read sample.
# ---------------------------------------------------------------------------
rule fastp:
    input:
        r1=lambda wildcards: samples.loc[wildcards.sample, "fq1"],
        r2=lambda wildcards: samples.loc[wildcards.sample, "fq2"]
    output:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        html="results/01_QC/{sample}/{sample}_fastp.html",
        json="results/01_QC/{sample}/{sample}_fastp.json"
    params:
        extra=config["params"]["fastp"]
    conda: "../envs/qc.yaml"
    log: "logs/fastp/{sample}.log"
    threads: config["threads"]["fastp"]
    shell:
        "fastp {params.extra} --thread {threads} -i {input.r1} -I {input.r2} "
        "-o {output.r1} -O {output.r2} -h {output.html} -j {output.json} 2> {log}"

rule nanoplot_raw:
    input:
        long=lambda wildcards: samples.loc[wildcards.sample, "fq_long"]
    output:
        outdir=directory("results/01_QC/{sample}/nanoplot_raw"),
        stats="results/01_QC/{sample}/nanoplot_raw/NanoStats.txt"
    threads: config["threads"]["nanoplot"]
    conda: "../envs/qc.yaml"
    log: "logs/nanoplot/{sample}_raw.log"
    shell:
        "NanoPlot --fastq {input.long} -o {output.outdir} -t {threads} > {log} 2>&1"

def _filtlong_extra(wildcards):
    """Filtlong's length window follows the amplicon, not the run: a 16S
    window (1300-1700) silently filters out 100% of an ITS run (~500 bp) or
    a full rrn-operon run (~4300 bp). The run-wide amplicon preset supplies
    it (see config_engine.py's amplicon_preset block); an explicit
    --min_length/--max_length typed on the Tools tab still wins, so custom
    amplicons stay possible."""
    extra = config["params"]["filtlong"]
    if "--min_length" in extra or "--max_length" in extra:
        return extra
    preset = config.get("amplicon_preset", {}) or {}
    mn, mx = preset.get("min_length", 0), preset.get("max_length", 0)
    if not mn or not mx:
        return extra  # e.g. the deliberately empty "custom" preset
    return f"--min_length {mn} --max_length {mx} {extra}".strip()


rule filtlong:
    input:
        long=lambda wildcards: samples.loc[wildcards.sample, "fq_long"]
    output:
        long="results/01_QC/{sample}/{sample}_filtered.fastq.gz"
    params:
        extra=_filtlong_extra
    conda: "../envs/qc.yaml"
    log: "logs/filtlong/{sample}.log"
    threads: 1  # Filtlong has no multithreading option -- not configurable on the Resources tab
    shell:
        "filtlong {params.extra} {input.long} 2> {log} | gzip > {output.long}"

rule nanoplot_clean:
    input:
        long="results/01_QC/{sample}/{sample}_filtered.fastq.gz"
    output:
        outdir=directory("results/01_QC/{sample}/nanoplot_clean"),
        stats="results/01_QC/{sample}/nanoplot_clean/NanoStats.txt"
    threads: config["threads"]["nanoplot"]
    conda: "../envs/qc.yaml"
    log: "logs/nanoplot/{sample}_clean.log"
    shell:
        "NanoPlot --fastq {input.long} -o {output.outdir} -t {threads} > {log} 2>&1"
