import pandas as pd

# fillna("") -- see the comment in 02_assembly.smk: include: shares one
# namespace, so every file redefining "samples" needs this for consistency
# regardless of which one's assignment ends up executing last.
samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule bowtie2_index:
    input:
        contigs="results/03_POLISH/{sample}/final_polished.fa"
    output:
        idx_dir=directory("results/03_POLISH/{sample}/index")
    params:
        extra=config["params"]["bowtie2"]
    threads: config["threads"]["bowtie2"]
    conda: "../envs/mapping.yaml"
    log: "logs/mapping/{sample}_index.log"
    shell:
        """
        mkdir -p {output.idx_dir}
        bowtie2-build --threads {threads} {params.extra} {input.contigs} {output.idx_dir}/assembly > {log} 2>&1
        """

rule map_reads:
    """Maps each sample's own reads back to its own polished assembly (self-
    coverage) -- used by CoverM to report depth/uniformity, not cross-sample
    abundance like MAGMA's pooled-MAG mapping."""
    input:
        contigs="results/03_POLISH/{sample}/final_polished.fa",
        idx_dir=lambda wildcards: f"results/03_POLISH/{wildcards.sample}/index" if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else [],
        r1=lambda wildcards: f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R1_clean.fastq.gz" if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else [],
        r2=lambda wildcards: f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R2_clean.fastq.gz" if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else [],
        long=lambda wildcards: f"results/01_QC/{wildcards.sample}/{wildcards.sample}_clean.fastq.gz" if samples.loc[wildcards.sample, "read_type"] == "long" else []
    output:
        "results/04_MAPPING/{sample}/{sample}.bam"
    params:
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"],
        bowtie2_extra=config["params"]["bowtie2"],
        minimap2_extra=config["params"]["minimap2"],
        minimap2_preset=config["long_read_platform"]["minimap2_preset"]
    log:
        "logs/mapping/{sample}_map.log"
    threads: lambda wildcards: config["threads"]["minimap2"] if samples.loc[wildcards.sample, "read_type"] == "long" else config["threads"]["bowtie2"]
    resources: tmpdir="/tmp"
    conda:
        "../envs/mapping.yaml"
    shell:
        """
        if [ "{params.rtype}" == "long" ]; then
            minimap2 -ax {params.minimap2_preset} -t {threads} {params.minimap2_extra} {input.contigs} {input.long} 2> {log} | \
            samtools sort -@ {threads} -O BAM -o {output} - 2>> {log}
        else
            bowtie2 -p {threads} {params.bowtie2_extra} -x {input.idx_dir}/assembly \
            -1 {input.r1} -2 {input.r2} 2> {log} | \
            samtools sort -@ {threads} -O BAM -o {output} - 2>> {log}
        fi
        """

rule index_bam:
    input:
        bam="results/04_MAPPING/{sample}/{sample}.bam"
    output:
        bai="results/04_MAPPING/{sample}/{sample}.bam.bai"
    params:
        extra=config["params"]["samtools_index"]
    threads: config["threads"]["samtools_index"]
    conda: "../envs/mapping.yaml"
    log: "logs/mapping/{sample}_index_bam.log"
    shell:
        "samtools index -@ {threads} {params.extra} {input.bam} > {log} 2>&1"
