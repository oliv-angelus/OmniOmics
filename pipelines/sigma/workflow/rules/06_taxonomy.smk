rule gtdbtk:
    """Classifies each sample's single genome directly -- no cross-sample
    dereplication step first, unlike MAGMA where GTDB-Tk runs on a pooled,
    dereplicated MAG set."""
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/06_TAXONOMY/{sample}/gtdbtk")
    params:
        db=config["databases"]["gtdbtk"],
        extra=config["params"]["gtdbtk"],
        indir="results/06_TAXONOMY/{sample}/gtdbtk_input"
    threads: config["threads"]["gtdbtk"]
    conda: "../envs/gtdbtk.yaml"
    log: "logs/gtdbtk/{sample}.log"
    shell:
        """
        rm -rf {params.indir}
        mkdir -p {params.indir}
        cp {input.fa} {params.indir}/{wildcards.sample}.fa
        export GTDBTK_DATA_PATH={params.db}
        gtdbtk classify_wf --genome_dir {params.indir} --out_dir {output.outdir} --extension fa --cpus {threads} {params.extra} > {log} 2>&1
        """
