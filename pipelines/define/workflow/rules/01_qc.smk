rule fastp:
    input:
        r1=lambda wildcards: samples.loc[wildcards.sample, "fq1"],
        r2=lambda wildcards: samples.loc[wildcards.sample, "fq2"]
    output:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        html="results/01_QC/{sample}/{sample}_fastp.html",
        json="results/01_QC/{sample}/{sample}_fastp.json()"
    params:
        extra=config["params"]["fastp"]
    conda: "../envs/qc.yaml"
    log: "logs/qc/{sample}_fastp.log"
    threads: config["threads"]["fastp"]
    shell:
        """
        fastp {params.extra} --thread {threads} \
            -i {input.r1} -I {input.r2} -o {output.r1} -O {output.r2} \
            -h {output.html} -j {output.json()} > {log} 2>&1
        """

rule fastqc_raw:
    input:
        r1=lambda wildcards: samples.loc[wildcards.sample, "fq1"],
        r2=lambda wildcards: samples.loc[wildcards.sample, "fq2"]
    output:
        outdir=directory("results/01_QC/{sample}/fastqc_raw")
    conda: "../envs/fastqc.yaml"
    threads: config["threads"]["fastqc"]
    log: "logs/qc/{sample}_fastqc_raw.log"
    shell:
        """
        mkdir -p {output.outdir}
        fastqc -t {threads} -o {output.outdir} {input.r1} {input.r2} > {log} 2>&1
        """

rule fastqc_trim:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz"
    output:
        outdir=directory("results/01_QC/{sample}/fastqc_trim")
    conda: "../envs/fastqc.yaml"
    threads: config["threads"]["fastqc"]
    log: "logs/qc/{sample}_fastqc_trim.log"
    shell:
        """
        mkdir -p {output.outdir}
        fastqc -t {threads} -o {output.outdir} {input.r1} {input.r2} > {log} 2>&1
        """

rule multiqc_raw:
    """One consolidated report over every sample's raw-read FastQC output -- mechanical, no per-sample judgment call (see PIPELINE_SPEC.md [1])."""
    input:
        expand("results/01_QC/{sample}/fastqc_raw", sample=SAMPLES)
    output:
        outdir=directory("results/01_QC/multiqc_raw")
    conda: "../envs/multiqc.yaml"
    log: "logs/qc/multiqc_raw.log"
    shell:
        "multiqc {input} -o {output.outdir} > {log} 2>&1"

rule multiqc_trim:
    """Same as multiqc_raw but post-trim, plus fastp's own JSON reports -- lets a user compare before/after in one place (PIPELINE_SPEC.md [3])."""
    input:
        fastqc=expand("results/01_QC/{sample}/fastqc_trim", sample=SAMPLES),
        fastp=expand("results/01_QC/{sample}/{sample}_fastp.json()", sample=SAMPLES)
    output:
        outdir=directory("results/01_QC/multiqc_trim")
    conda: "../envs/multiqc.yaml"
    log: "logs/qc/multiqc_trim.log"
    shell:
        "multiqc {input.fastqc} {input.fastp} -o {output.outdir} > {log} 2>&1"
