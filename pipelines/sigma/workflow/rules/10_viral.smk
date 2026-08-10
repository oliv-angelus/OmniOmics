rule genomad:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/10_VIRAL/{sample}/genomad")
    params:
        db=config["databases"]["genomad"],
        extra=config["params"]["genomad"]
    threads: config["threads"]["genomad"]
    conda: "../envs/genomad.yaml"
    log: "logs/viral/{sample}_genomad.log"
    shell:
        """
        rm -rf {output.outdir}
        genomad end-to-end --cleanup --splits 8 --threads {threads} {params.extra} {input.fa} {output.outdir} {params.db} > {log} 2>&1
        """

rule virsorter2:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/10_VIRAL/{sample}/virsorter2"),
        viral_fa="results/10_VIRAL/{sample}/virsorter2/final-viral-combined.fa"
    params:
        db=config["databases"]["virsorter2"],
        extra=config["params"]["virsorter2"]
    threads: config["threads"]["virsorter2"]
    conda: "../envs/virsorter2.yaml"
    log: "logs/viral/{sample}_virsorter2.log"
    shell:
        """
        rm -rf {output.outdir}
        virsorter run -w {output.outdir} -i {input.fa} --db-dir {params.db} \
        --include-groups dsDNAphage,ssDNA -j {threads} {params.extra} all > {log} 2>&1
        if [ ! -f "{output.viral_fa}" ]; then
            touch "{output.viral_fa}"
        fi
        """

rule checkv:
    input:
        fa="results/10_VIRAL/{sample}/virsorter2/final-viral-combined.fa"
    output:
        outdir=directory("results/10_VIRAL/{sample}/checkv"),
        summary="results/10_VIRAL/{sample}/checkv/quality_summary.tsv"
    params:
        db=config["databases"]["checkv"],
        extra=config["params"]["checkv"]
    threads: config["threads"]["checkv"]
    conda: "../envs/checkv.yaml"
    log: "logs/viral/{sample}_checkv.log"
    shell:
        """
        export CHECKVDB={params.db}
        checkv end_to_end {input.fa} {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

rule vibrant:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/10_VIRAL/{sample}/vibrant")
    params:
        db=config["databases"]["vibrant_files"],
        extra=config["params"]["vibrant"]
    threads: config["threads"]["vibrant"]
    conda: "../envs/vibrant.yaml"
    log: "logs/viral/{sample}_vibrant.log"
    shell:
        """
        rm -rf {output.outdir}
        mkdir -p {output.outdir}
        VIBRANT_run.py -i {input.fa} -folder {output.outdir} -t {threads} \
            -d {params.db} {params.extra} > {log} 2>&1
        """
