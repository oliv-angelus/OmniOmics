rule featurecounts:
    """One matrix over every sample's BAM at once (not one run per sample
    joined afterward) -- guarantees the same gene rows/order across samples.
    -s is read from decide_strandedness's output at
    shell-execution time, not at DAG-build time (the file doesn't exist yet
    on a fresh run)."""
    input:
        bams=expand("results/02_MAPPING/{sample}/{sample}.sorted.bam", sample=SAMPLES),
        bais=expand("results/02_MAPPING/{sample}/{sample}.sorted.bam.bai", sample=SAMPLES),
        gff="results/00_REFERENCE/bakta/reference_filtered.gff3",
        strand="results/03_STRANDEDNESS/strandedness.txt"
    output:
        counts="results/04_COUNTS/counts.tsv",
        summary="results/04_COUNTS/counts.tsv.summary"
    params:
        extra=config["params"]["featurecounts"]
    threads: config["threads"]["featurecounts"]
    conda: "../envs/subread.yaml"
    log: "logs/counts/featurecounts.log"
    shell:
        """
        mkdir -p results/04_COUNTS
        S=$(cat {input.strand})
        featureCounts -T {threads} -p -s $S {params.extra} \
            -a {input.gff} -o {output.counts} {input.bams} > {log} 2>&1
        """
