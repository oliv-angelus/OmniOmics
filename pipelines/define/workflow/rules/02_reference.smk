# Every rule in this file runs exactly once per run (no {sample} wildcard),
# against the single user-provided reference genome -- every per-sample rule
# downstream (mapping, counting) depends on these fixed paths instead of
# re-annotating/re-indexing per sample. Same "build once, reuse for every
# sample" mechanism already used by DOGMA's ncycdb_index and MAGMA's
# coverm_index (see pipelines/dogma/workflow/rules/05_annotation.smk and
# pipelines/magma/workflow/rules/08_coverage.smk).

rule bakta_reference:
    """All-in-one reference genome annotation: gene calling, tRNA/tmRNA/rRNA/
    ncRNA/CRISPR detection, functional annotation. Runs once for the whole
    project, not once per sample (PIPELINE_SPEC.md [4])."""
    input:
        fa=config["databases"]["reference_genome"]
    output:
        outdir=directory("results/00_REFERENCE/bakta"),
        fna="results/00_REFERENCE/bakta/reference.fna",
        faa="results/00_REFERENCE/bakta/reference.faa",
        gff="results/00_REFERENCE/bakta/reference.gff3",
        tsv="results/00_REFERENCE/bakta/reference.tsv"
    params:
        db=config["databases"]["bakta"],
        extra=config["params"]["bakta_reference"]
    threads: config["threads"]["bakta_reference"]
    conda: "../envs/bakta.yaml"
    log: "logs/reference/bakta.log"
    shell:
        """
        rm -rf {output.outdir}
        bakta --db {params.db} --output {output.outdir} --prefix reference \
            --threads {threads} {params.extra} {input.fa} > {log} 2>&1
        """

rule filter_rrna:
    """Excludes rRNA/tRNA/tmRNA features before counting -- residual
    ribosomal/transfer RNA would otherwise distort expression normalization
    (PIPELINE_SPEC.md [5])."""
    input:
        gff="results/00_REFERENCE/bakta/reference.gff3"
    output:
        gff="results/00_REFERENCE/bakta/reference_filtered.gff3"
    log: "logs/reference/filter_rrna.log"
    shell:
        """
        awk -F'\t' '$1~/^#/ || ($3!="rRNA" && $3!="tRNA" && $3!="tmRNA")' \
            {input.gff} > {output.gff} 2> {log}
        """

rule bowtie2_index_reference:
    input:
        fa="results/00_REFERENCE/bakta/reference.fna"
    output:
        idx_dir=directory("results/00_REFERENCE/index")
    threads: config["threads"]["bowtie2"]
    conda: "../envs/mapping.yaml"
    log: "logs/reference/bowtie2_index.log"
    shell:
        """
        mkdir -p {output.idx_dir}
        bowtie2-build --threads {threads} {input.fa} {output.idx_dir}/reference > {log} 2>&1
        """

rule eggnog_reference:
    """Functional annotation of the reference's own proteins (OG, COG, GO,
    EC, KEGG, PFAM) -- merged into the final annotated count table in
    06_merge.smk (PIPELINE_SPEC.md [10])."""
    input:
        faa="results/00_REFERENCE/bakta/reference.faa"
    output:
        annot="results/00_REFERENCE/eggnog/reference_annotations.emapper.annotations"
    params:
        db=config["databases"]["eggnog"],
        extra=config["params"]["eggnog_reference"],
        out_prefix="results/00_REFERENCE/eggnog/reference_annotations"
    threads: config["threads"]["eggnog_reference"]
    conda: "../envs/eggnog.yaml"
    log: "logs/reference/eggnog.log"
    shell:
        """
        mkdir -p results/00_REFERENCE/eggnog
        emapper.py -m diamond -i {input.faa} --data_dir {params.db} \
            -o {params.out_prefix} --cpu {threads} {params.extra} > {log} 2>&1
        """
