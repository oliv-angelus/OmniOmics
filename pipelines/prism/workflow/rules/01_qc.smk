import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

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
    return f"--min_length {mn} --max_length {mx} {extra}".strip


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
