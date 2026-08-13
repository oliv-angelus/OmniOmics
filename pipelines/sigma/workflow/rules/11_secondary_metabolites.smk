rule antismash:
    """BGC detection on the polished assembly, using Bakta's gene calls rather
    than re-predicting genes.

    antiSMASH would otherwise run its own bundled Prodigal over the raw FASTA,
    producing a second, independent set of ORFs for a genome Bakta has already
    annotated. The two callers disagree at some loci, so a BGC's coordinates and
    member genes would not line up with the annotation every other stage — and
    the Plots tab's genome ring — is built from.

    Passing --genefinding-gff3 loads Bakta's CDS features into the record, which
    suppresses gene finding entirely (antismash/common/record_processing.py only
    calls genefinding when a record has no CDS features and no GFF3 was given).
    --genefinding-tool error is then a failsafe: if the GFF3 ever fails to supply
    genes, the run stops loudly instead of silently skipping the record, which is
    what the 'none' setting would do."""
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa",
        gff="results/08_ANNOTATION/{sample}/bakta/{sample}.gff3"
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
            --genefinding-gff3 {input.gff} --genefinding-tool error \
            --cpus {threads} --logfile {log} {params.extra}
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
