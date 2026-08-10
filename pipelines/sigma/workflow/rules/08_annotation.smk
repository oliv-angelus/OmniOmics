rule bakta:
    """All-in-one isolate genome annotation: gene calling (its own internal
    Pyrodigal run) + tRNA/tmRNA/rRNA/ncRNA/CRISPR detection + functional
    annotation. Standalone Prodigal isn't needed for SIGMA the way MAGMA needs
    it, since Bakta covers gene calling + non-coding detection in one step;
    eggNOG-mapper is still offered as an optional add-on (below) for deeper
    orthology-based functional profiling (KEGG/COG/GO) beyond what Bakta's
    own annotation provides."""
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/08_ANNOTATION/{sample}/bakta"),
        faa="results/08_ANNOTATION/{sample}/bakta/{sample}.faa",
        gff="results/08_ANNOTATION/{sample}/bakta/{sample}.gff3"
    params:
        db=config["databases"]["bakta"],
        extra=config["params"]["bakta"]
    threads: config["threads"]["bakta"]
    conda: "../envs/bakta.yaml"
    log: "logs/annotation/{sample}_bakta.log"
    shell:
        """
        rm -rf {output.outdir}
        bakta --db {params.db} --output {output.outdir} --prefix {wildcards.sample} --threads {threads} {params.extra} {input.fa} > {log} 2>&1
        """

rule eggnog_sample:
    """Optional deeper functional annotation (KEGG/COG/GO) on top of Bakta's
    own gene calls -- consumes Bakta's protein FASTA directly instead of
    running a separate Prodigal step, unlike MAGMA's eggnog_sample rule."""
    input:
        faa="results/08_ANNOTATION/{sample}/bakta/{sample}.faa"
    output:
        annot="results/08_ANNOTATION/{sample}/eggnog/{sample}_annotations.emapper.annotations"
    params:
        db=config["databases"]["eggnog"],
        extra=config["params"]["eggnog"],
        out_prefix="results/08_ANNOTATION/{sample}/eggnog/{sample}_annotations"
    threads: config["threads"]["eggnog"]
    conda: "../envs/eggnog.yaml"
    log: "logs/annotation/{sample}_eggnog.log"
    shell:
        "emapper.py -m diamond -i {input.faa} --data_dir {params.db} -o {params.out_prefix} --cpu {threads} {params.extra} > {log} 2>&1"

rule amrfinder_sample:
    input:
        faa="results/08_ANNOTATION/{sample}/bakta/{sample}.faa",
        fna="results/03_POLISH/{sample}/final_polished.fa",
        gff="results/08_ANNOTATION/{sample}/bakta/{sample}.gff3"
    output:
        out="results/08_ANNOTATION/{sample}/amrfinder/amrfinder_results.tsv"
    params:
        db=config["databases"]["amrfinderplus"],
        # Bakta's GFF3/protein FASTA use its own header conventions -- AMRFinderPlus
        # reads them natively via --annotation_format bakta rather than "prodigal".
        extra=config["params"]["amrfinderplus"]
    threads: config["threads"]["amrfinderplus"]
    conda: "../envs/amrfinder.yaml"
    log: "logs/annotation/{sample}_amrfinder.log"
    shell:
        """
        mkdir -p $(dirname {output.out})
        amrfinder -p {input.faa} -n {input.fna} -g {input.gff} \
            --database {params.db} --annotation_format bakta \
            --plus --threads {threads} {params.extra} -o {output.out} > {log} 2>&1
        """

rule abricate_sample:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/08_ANNOTATION/{sample}/abricate")
    params:
        extra=config["params"]["abricate"]
    threads: config["threads"]["abricate"]
    conda: "../envs/abricate.yaml"
    log: "logs/annotation/{sample}_abricate.log"
    shell:
        """
        mkdir -p {output.outdir}
        abricate --db ncbi --threads {threads} {params.extra} {input.fa} > {output.outdir}/ncbi_results.tab 2> {log}
        abricate --db card --threads {threads} {params.extra} {input.fa} > {output.outdir}/card_results.tab 2>> {log}
        """

rule vfdb_sample:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        out="results/08_ANNOTATION/{sample}/vfdb/vfdb_results.tab"
    params:
        extra=config["params"]["vfdb"]
    threads: config["threads"]["vfdb"]
    conda: "../envs/abricate.yaml"
    log: "logs/annotation/{sample}_vfdb.log"
    shell:
        """
        mkdir -p $(dirname {output.out})
        abricate --db vfdb --threads {threads} {params.extra} {input.fa} > {output.out} 2> {log}
        """

rule isescan_sample:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/08_ANNOTATION/{sample}/isescan")
    params:
        extra=config["params"]["isescan"]
    threads: config["threads"]["isescan"]
    conda: "../envs/isescan.yaml"
    log: "logs/annotation/{sample}_isescan.log"
    shell:
        """
        isescan.py --seqfile {input.fa} --output {output.outdir} --nthread {threads} {params.extra} > {log} 2>&1
        rm -f {wildcards.sample}_*.list
        """

rule mobsuite_sample:
    input:
        fa="results/03_POLISH/{sample}/final_polished.fa"
    output:
        outdir=directory("results/08_ANNOTATION/{sample}/mobsuite")
    params:
        extra=config["params"]["mobsuite"]
    threads: config["threads"]["mobsuite"]
    conda: "../envs/mobsuite.yaml"
    log: "logs/annotation/{sample}_mobsuite.log"
    shell:
        """
        rm -rf {output.outdir}
        mob_recon -i {input.fa} -o {output.outdir} -n {threads} {params.extra} > {log} 2>&1
        """
