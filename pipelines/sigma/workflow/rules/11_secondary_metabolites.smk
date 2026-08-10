rule antismash:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/11_BGC/{sample}/antismash")
    params:
        db=config["databases"]["antismash"],
        extra=config["params"]["antismash"]
    threads: config["threads"]["antismash"]
    conda: "../envs/antismash.yaml"
    log: "logs/bgc/{sample}_antismash.log"
    shell:
        """
        mkdir -p {output.outdir}
        antismash {input.fa} --databases {params.db} --output-dir {output.outdir} \
            --genefinding-tool prodigal --cpus {threads} --logfile {log} {params.extra}
        """

rule bigscape:
    input:
        ast_dir="results/11_BGC/{sample}/antismash"
    output:
        outdir=directory("results/11_BGC/{sample}/bigscape")
    params:
        pfam=config["databases"]["pfam"],
        extra=config["params"]["bigscape"]
    threads: config["threads"]["bigscape"]
    conda: "../envs/bigscape.yaml"
    log: "logs/bgc/{sample}_bigscape.log"
    shell:
        """
        mkdir -p {output.outdir}/gbk_pool
        find {input.ast_dir} -name "*.gbk" -exec cp {{}} {output.outdir}/gbk_pool/ \\;
        if [ "$(ls -A {output.outdir}/gbk_pool)" ]; then
            bigscape cluster -i {output.outdir}/gbk_pool -o {output.outdir} --pfam-path {params.pfam} -c {threads} {params.extra} > {log} 2>&1
        else
            echo "No GBK files found for BiG-SCAPE." > {log}
        fi
        """
