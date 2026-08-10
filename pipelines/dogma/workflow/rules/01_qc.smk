import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule fastp:
    input:
        r1=lambda wildcards: samples.loc[wildcards.sample, "fq1"] if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else [],
        r2=lambda wildcards: samples.loc[wildcards.sample, "fq2"] if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else []
    output:
        r1="results/01_QC/{sample}/{sample}_R1_trimmed.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_trimmed.fastq.gz",
        html="results/01_QC/{sample}/{sample}_fastp.html",
        json="results/01_QC/{sample}/{sample}_fastp.json"
    params:
        extra=config["params"]["fastp"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/qc.yaml"
    log: "logs/fastp/{sample}.log"
    threads: config["threads"]["fastp"]
    shell:
        """
        if [ "{params.rtype}" == "short" ] || [ "{params.rtype}" == "hybrid" ]; then
            fastp {params.extra} --thread {threads} -i {input.r1} -I {input.r2} -o {output.r1} -O {output.r2} -h {output.html} -j {output.json} 2> {log}
        else
            touch {output.r1} {output.r2} {output.html} {output.json}
        fi
        """

rule filtlong:
    input:
        long=lambda wildcards: samples.loc[wildcards.sample, "fq_long"] if samples.loc[wildcards.sample, "read_type"] in ["long", "hybrid"] else []
    output:
        long="results/01_QC/{sample}/{sample}_trimmed.fastq.gz"
    params:
        extra=config["params"]["filtlong"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/qc.yaml"
    log: "logs/filtlong/{sample}.log"
    threads: 1  # Filtlong has no multithreading option -- not configurable on the Resources tab
    shell:
        """
        if [ "{params.rtype}" == "long" ] || [ "{params.rtype}" == "hybrid" ]; then
            filtlong {params.extra} {input.long} 2> {log} | gzip > {output.long}
        else
            touch {output.long}
        fi
        """

# riboDetector runs after fastp/filtlong, not instead of them -- most of the
# RNA in a total-RNA extraction is ribosomal, not messenger, and everything
# downstream (taxonomy screening, assembly, quantification) needs that
# filtered out first. Split into a short/long rule the same way fastp and
# filtlong already are, since riboDetector's -l (expected read length) means
# something different for each and short reads need -i/-j (paired) while
# long reads are single-end.
rule ribodetector_short:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_trimmed.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_trimmed.fastq.gz"
    output:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        rrna1="results/01_QC/{sample}/{sample}_R1_rrna.fastq.gz",
        rrna2="results/01_QC/{sample}/{sample}_R2_rrna.fastq.gz"
    params:
        extra=config["params"]["ribodetector"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/ribodetector.yaml"
    threads: config["threads"]["ribodetector"]
    log: "logs/ribodetector/{sample}_short.log"
    shell:
        """
        if [ "{params.rtype}" == "short" ] || [ "{params.rtype}" == "hybrid" ]; then
            ribodetector_cpu -i {input.r1} {input.r2} -o {output.r1} {output.r2} \
                -r {output.rrna1} {output.rrna2} -l 150 -t {threads} {params.extra} > {log} 2>&1
        else
            touch {output.r1} {output.r2} {output.rrna1} {output.rrna2}
        fi
        """

rule ribodetector_long:
    input:
        long="results/01_QC/{sample}/{sample}_trimmed.fastq.gz"
    output:
        long="results/01_QC/{sample}/{sample}_clean.fastq.gz",
        rrna="results/01_QC/{sample}/{sample}_rrna.fastq.gz"
    params:
        extra=config["params"]["ribodetector"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/ribodetector.yaml"
    threads: config["threads"]["ribodetector"]
    log: "logs/ribodetector/{sample}_long.log"
    shell:
        """
        if [ "{params.rtype}" == "long" ] || [ "{params.rtype}" == "hybrid" ]; then
            ribodetector_cpu -i {input.long} -o {output.long} -r {output.rrna} \
                -l 1000 -t {threads} {params.extra} > {log} 2>&1
        else
            touch {output.long} {output.rrna}
        fi
        """

rule nanoplot_raw:
    input:
        long=lambda wildcards: samples.loc[wildcards.sample, "fq_long"]
    output:
        outdir=directory("results/01_QC/{sample}/nanoplot_raw"),
        stats="results/01_QC/{sample}/nanoplot_raw/NanoStats.txt"
    threads: 4
    conda: "../envs/nanoplot.yaml"
    log: "logs/nanoplot/{sample}_raw.log"
    shell:
        "NanoPlot --fastq {input.long} -o {output.outdir} -t {threads} > {log} 2>&1"

rule nanoplot_clean:
    input:
        long="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        outdir=directory("results/01_QC/{sample}/nanoplot_clean"),
        stats="results/01_QC/{sample}/nanoplot_clean/NanoStats.txt"
    threads: 4
    conda: "../envs/nanoplot.yaml"
    log: "logs/nanoplot/{sample}_clean.log"
    shell:
        "NanoPlot --fastq {input.long} -o {output.outdir} -t {threads} > {log} 2>&1"
