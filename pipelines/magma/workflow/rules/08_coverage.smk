import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

SHORT_COV = [s for s in SAMPLES if samples.loc[s, "read_type"] in ["short", "hybrid"]]
LONG_COV  = [s for s in SAMPLES if samples.loc[s, "read_type"] == "long"]


rule coverm_index:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        ref="results/10_MAG_COVERAGE/index/dereplicated_mags.fa",
        idx="results/10_MAG_COVERAGE/index/dereplicated_mags.1.bt2"
    threads: config["threads"]["coverm"]
    conda: "../envs/mapping.yaml"
    log: "logs/coverm/index.log"
    shell:
        """
        mkdir -p results/10_MAG_COVERAGE/index
        cat {input.mags}/*.fa > {output.ref}
        bowtie2-build --threads {threads} {output.ref} \
            results/10_MAG_COVERAGE/index/dereplicated_mags > {log} 2>&1
        """


rule coverm_map_short:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        idx="results/10_MAG_COVERAGE/index/dereplicated_mags.1.bt2"
    output:
        bam="results/10_MAG_COVERAGE/bam/{sample}.bam",
        bai="results/10_MAG_COVERAGE/bam/{sample}.bam.bai"
    wildcard_constraints:
        sample="|".join(SHORT_COV) if SHORT_COV else "NOMATCH"
    threads: config["threads"]["coverm"]
    conda: "../envs/mapping.yaml"
    log: "logs/coverm/{sample}_map.log"
    shell:
        """
        mkdir -p results/10_MAG_COVERAGE/bam
        bowtie2 -x results/10_MAG_COVERAGE/index/dereplicated_mags \
            -1 {input.r1} -2 {input.r2} -p {threads} --no-unal 2> {log} | \
        samtools sort -@ {threads} -o {output.bam} >> {log} 2>&1
        samtools index {output.bam} >> {log} 2>&1
        """


rule coverm_map_long:
    input:
        reads="results/01_QC/{sample}/{sample}_clean.fastq.gz",
        ref="results/10_MAG_COVERAGE/index/dereplicated_mags.fa"
    output:
        bam="results/10_MAG_COVERAGE/bam/{sample}.bam",
        bai="results/10_MAG_COVERAGE/bam/{sample}.bam.bai"
    params:
        minimap2_preset=config["long_read_platform"]["minimap2_preset"]
    wildcard_constraints:
        sample="|".join(LONG_COV) if LONG_COV else "NOMATCH"
    threads: config["threads"]["coverm"]
    conda: "../envs/mapping.yaml"
    log: "logs/coverm/{sample}_map.log"
    shell:
        """
        mkdir -p results/10_MAG_COVERAGE/bam
        minimap2 -ax {params.minimap2_preset} -t {threads} {input.ref} {input.reads} 2> {log} | \
        samtools sort -@ {threads} -o {output.bam} >> {log} 2>&1
        samtools index {output.bam} >> {log} 2>&1
        """


rule coverm:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes",
        bams=expand("results/10_MAG_COVERAGE/bam/{sample}.bam", sample=SAMPLES),
        bais=expand("results/10_MAG_COVERAGE/bam/{sample}.bam.bai", sample=SAMPLES)
    output:
        coverage="results/10_MAG_COVERAGE/coverm_coverage.tsv"
    params:
        extra=config["params"]["coverm"]
    threads: config["threads"]["coverm"]
    conda: "../envs/coverm.yaml"
    log: "logs/coverm/coverm.log"
    shell:
        """
        coverm genome \
            --bam-files {input.bams} \
            --genome-fasta-directory {input.mags} \
            --genome-fasta-extension fa \
            --methods trimmed_mean covered_fraction mean \
            --threads {threads} \
            {params.extra} \
            -o {output.coverage} > {log} 2>&1
        """
