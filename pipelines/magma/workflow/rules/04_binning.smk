import pandas as pd
import os

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule metabat2:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        depth="results/04_MAPPING/{sample}/{sample}_depth.txt"
    output:
        outdir=directory("results/05_BINNING/{sample}/metabat2")
    params: extra=config["params"].get("metabat2", "")
    threads: config["threads"]["metabat2"]
    conda: "../envs/metabat2.yaml"
    log: "logs/binning/{sample}_metabat2.log"
    shell:
        """
        mkdir -p {output.outdir}
        metabat2 -i {input.contigs} -a {input.depth} -o {output.outdir}/bin -t {threads} {params.extra} > {log} 2>&1
        """

rule semibin2:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        bam="results/04_MAPPING/{sample}/{sample}.bam",
        bai="results/04_MAPPING/{sample}/{sample}.bam.bai"
    output:
        outdir=directory("results/05_BINNING/{sample}/semibin2")
    params: extra=config["params"].get("semibin2", "--environment global")
    threads: config["threads"]["semibin2"]
    conda: "../envs/semibin2.yaml"
    log: "logs/binning/{sample}_semibin2.log"
    shell:
        """
        rm -rf {output.outdir}
        SemiBin2 single_easy_bin -i {input.contigs} -b {input.bam} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        gunzip -f {output.outdir}/output_bins/*.fa.gz 2>/dev/null || true
        """

rule maxbin2:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        depth="results/04_MAPPING/{sample}/{sample}_depth.txt"
    output:
        outdir=directory("results/05_BINNING/{sample}/maxbin2")
    params: extra=config["params"].get("maxbin2", "")
    threads: config["threads"]["maxbin2"]
    conda: "../envs/maxbin2.yaml"
    log: "logs/binning/{sample}_maxbin2.log"
    shell:
        """
        mkdir -p {output.outdir}
        awk 'NR>1 {{print $1"\\t"$3}}' {input.depth} > {output.outdir}/abundance.txt
        run_MaxBin.pl -contig {input.contigs} -abund {output.outdir}/abundance.txt \
            -out {output.outdir}/bin -thread {threads} {params.extra} > {log} 2>&1
        for f in {output.outdir}/*.fasta; do
            [ -f "$f" ] && mv "$f" "${{f%.fasta}}.fa"
        done
        """

rule vamb:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        bam="results/04_MAPPING/{sample}/{sample}.bam",
        bai="results/04_MAPPING/{sample}/{sample}.bam.bai"
    output:
        outdir=directory("results/05_BINNING/{sample}/vamb")
    params: extra=config["params"].get("vamb", "")
    threads: config["threads"]["vamb"]
    conda: "../envs/vamb.yaml"
    log: "logs/binning/{sample}_vamb.log"
    shell:
        """
        rm -rf {output.outdir}
        BAM_DIR=$(dirname {input.bam})
        vamb bin default --outdir {output.outdir} --fasta {input.contigs} --bamdir $BAM_DIR -p {threads} {params.extra} > {log} 2>&1
        for f in {output.outdir}/bins/*.fna; do
            [ -f "$f" ] && mv "$f" "${{f%.fna}}.fa"
        done
        """
