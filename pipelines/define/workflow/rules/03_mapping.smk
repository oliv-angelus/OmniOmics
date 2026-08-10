rule bowtie2_align:
    input:
        idx_dir="results/00_REFERENCE/index",
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz"
    output:
        bam="results/02_MAPPING/{sample}/{sample}.sorted.bam"
    params:
        extra=config["params"]["bowtie2"]
    threads: config["threads"]["bowtie2"]
    conda: "../envs/mapping.yaml"
    # Bowtie2 writes its "% overall alignment rate" summary to stderr, so
    # this log doubles as an input to qc_summary's automatic QC-alert table
    # (06_merge.smk) -- not just a debugging artifact.
    log: "logs/mapping/{sample}_bowtie2.log"
    shell:
        """
        mkdir -p results/02_MAPPING/{wildcards.sample}
        bowtie2 -p {threads} -x {input.idx_dir}/reference -1 {input.r1} -2 {input.r2} {params.extra} 2> {log} \
          | samtools sort -@ {threads} -o {output.bam} - >> {log} 2>&1
        """

rule index_bam:
    input:
        bam="results/02_MAPPING/{sample}/{sample}.sorted.bam"
    output:
        bai="results/02_MAPPING/{sample}/{sample}.sorted.bam.bai"
    threads: config["threads"]["samtools_index"]
    conda: "../envs/mapping.yaml"
    log: "logs/mapping/{sample}_index.log"
    shell:
        "samtools index -@ {threads} {input.bam} > {log} 2>&1"
