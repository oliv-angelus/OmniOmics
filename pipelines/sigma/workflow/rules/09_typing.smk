rule mlst:
    """Multi-locus sequence typing against PubMLST schemes -- the database
    ships bundled inside the conda package itself, no separate download
    needed."""
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        "results/09_TYPING/{sample}/mlst.tsv"
    params:
        extra=config["params"]["mlst"]
    threads: config["threads"]["mlst"]
    conda: "../envs/mlst.yaml"
    log: "logs/typing/{sample}_mlst.log"
    shell:
        "mlst --threads {threads} {params.extra} {input.fa} > {output} 2> {log}"
