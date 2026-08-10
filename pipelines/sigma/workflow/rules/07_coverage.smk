rule coverm:
    """Self-coverage: each sample's own reads mapped back to its own polished
    assembly -- reports depth/uniformity for a single genome, unlike MAGMA's
    cross-sample relative-abundance table over a pooled MAG set."""
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa",
        bam="results/04_MAPPING/{sample}/{sample}.bam",
        bai="results/04_MAPPING/{sample}/{sample}.bam.bai"
    output:
        coverage="results/07_COVERAGE/{sample}/coverm_coverage.tsv"
    params:
        extra=config["params"]["coverm"]
    threads: config["threads"]["coverm"]
    conda: "../envs/coverm.yaml"
    log: "logs/coverm/{sample}.log"
    shell:
        """
        mkdir -p $(dirname {output.coverage})
        coverm genome \
            --bam-files {input.bam} \
            --genome-fasta-files {input.fa} \
            --methods trimmed_mean covered_fraction mean \
            --threads {threads} \
            {params.extra} \
            -o {output.coverage} > {log} 2>&1
        """
