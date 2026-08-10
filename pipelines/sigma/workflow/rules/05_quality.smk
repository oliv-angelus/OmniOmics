rule quast:
    input:
        contigs="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/05_QUALITY/{sample}/quast")
    params:
        extra=config["params"]["quast"]
    threads: config["threads"]["quast"]
    conda: "../envs/quast.yaml"
    log: "logs/quast/{sample}.log"
    shell:
        "quast.py {input.contigs} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1"

rule checkm2:
    """CheckM2 estimates completeness/contamination for a single isolate
    genome directly -- no binning/refinement step to feed it, unlike MAGMA
    where it runs against a set of MAG bins."""
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        report="results/05_QUALITY/{sample}/checkm2/quality_report.tsv",
        outdir=directory("results/05_QUALITY/{sample}/checkm2")
    params:
        db=config["databases"]["checkm2"],
        extra=config["params"]["checkm2"],
        indir="results/05_QUALITY/{sample}/checkm2_input"
    threads: config["threads"]["checkm2"]
    conda: "../envs/checkm2.yaml"
    log: "logs/checkm2/{sample}.log"
    shell:
        """
        rm -rf {output.outdir} {params.indir}
        mkdir -p {params.indir}
        cp {input.fa} {params.indir}/{wildcards.sample}.fa
        checkm2 predict --threads {threads} --input {params.indir} -x fa --output-directory {output.outdir} --database_path {params.db} {params.extra} > {log} 2>&1
        """

rule gunc:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/05_QUALITY/{sample}/gunc")
    params:
        extra=config["params"]["gunc"]
    threads: config["threads"]["gunc"]
    conda: "../envs/gunc.yaml"
    log: "logs/gunc/{sample}.log"
    shell:
        """
        mkdir -p {output.outdir}
        gunc run --input_file {input.fa} --out_dir {output.outdir} --threads {threads} {params.extra} > {log} 2>&1
        """
