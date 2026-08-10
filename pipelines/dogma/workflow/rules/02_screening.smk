import pandas as pd
import os
import glob

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# Screening runs on the rRNA-depleted reads (riboDetector's output), not the
# raw fastp/filtlong trim -- classifying rRNA reads would just say "this is
# ribosomal RNA from something," which isn't the point here.
def get_clean_reads(wildcards):
    row = samples.loc[wildcards.sample]
    if row["read_type"] in ["short", "hybrid"]:
        return [f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R1_clean.fastq.gz",
                f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R2_clean.fastq.gz"]
    else:
        return [f"results/01_QC/{wildcards.sample}/{wildcards.sample}_clean.fastq.gz"]

rule kraken2:
    input: reads=get_clean_reads
    output:
        report="results/02_SCREENING/{sample}/{sample}_kraken2.kreport",
        output="results/02_SCREENING/{sample}/{sample}_kraken2.output"
    params:
        db=config["databases"]["kraken2"],
        extra=config["params"]["kraken2"],
        paired=lambda wildcards, input: "--paired" if len(input.reads) == 2 else ""
    conda: "../envs/kraken2.yaml"
    threads: config["threads"]["kraken2"]
    log: "logs/screening/{sample}_kraken2.log"
    shell:
        "kraken2 --db {params.db} --threads {threads} {params.extra} {params.paired} "
        "--report {output.report} {input.reads} > {output.output} 2> {log}"

def kaiju_reads_flag(wildcards, input):
    return f"-i {input.reads[0]} -j {input.reads[1]}" if len(input.reads) == 2 else f"-i {input.reads[0]}"

rule kaiju_classify:
    input: reads=get_clean_reads
    output:
        out="results/02_SCREENING/{sample}/{sample}_kaiju.out"
    params:
        nodes=lambda wc: os.path.join(config["databases"]["kaiju"], "nodes.dmp"),
        # Guard the [0]: Snakemake evaluates this params lambda at DAG-build
        # time even when kaiju is inactive (--omit-from doesn't prevent it), so
        # an empty/unconfigured kaiju DB (glob finds no.fmi) must not raise
        # IndexError and abort the whole run before it starts. Returns "" then -- # harmless, since the rule only actually runs when kaiju is active with a
        # real DB (glob then finds the.fmi).
        fmi=lambda wc: (glob.glob(os.path.join(config["databases"]["kaiju"], "*.fmi")) or [""])[0],
        extra=config["params"]["kaiju"],
        reads_flag=kaiju_reads_flag
    conda: "../envs/kaiju.yaml"
    threads: config["threads"]["kaiju"]
    log: "logs/screening/{sample}_kaiju_classify.log"
    shell:
        "kaiju -z {threads} -t {params.nodes} -f {params.fmi} {params.reads_flag} "
        "{params.extra} -o {output.out} 2> {log}"

rule kaiju_table:
    input:
        out="results/02_SCREENING/{sample}/{sample}_kaiju.out"
    output:
        table="results/02_SCREENING/{sample}/{sample}_kaiju_species.tsv",
        names="results/02_SCREENING/{sample}/{sample}_kaiju_named.out"
    params:
        nodes=lambda wc: os.path.join(config["databases"]["kaiju"], "nodes.dmp"),
        names_dmp=lambda wc: os.path.join(config["databases"]["kaiju"], "names.dmp")
    conda: "../envs/kaiju.yaml"
    threads: 1
    log: "logs/screening/{sample}_kaiju_table.log"
    shell:
        """
        kaiju2table -t {params.nodes} -n {params.names_dmp} -r species -o {output.table} {input.out} > {log} 2>&1
        kaiju-addTaxonNames -t {params.nodes} -n {params.names_dmp} -i {input.out} -o {output.names} >> {log} 2>&1
        """

# Splits rRNA-depleted reads by taxonomic domain *before* assembly -- the
# established order for eukaryotic metatranscriptome assembly (see notes/DOGMA.md),
# not classifying contigs after assembly the way MAGMA's Tiara does. Uses
# Kraken2's own report/output (not Kaiju's -- its output isn't Kraken-report
# shaped, so this tool requires Kraken2 specifically). NCBI taxids: 2 = Bacteria,
# 2157 = Archaea, 2759 = Eukaryota; --include-children pulls in everything
# nested below those nodes. "mode" picks which domain(s) actually get extracted
# -- the other output(s) are touched empty, same pattern fastp/filtlong/
# ribodetector already use for a read type that doesn't apply to a given sample.
rule extract_domain_short:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        kraken_out="results/02_SCREENING/{sample}/{sample}_kraken2.output",
        kraken_report="results/02_SCREENING/{sample}/{sample}_kraken2.kreport"
    output:
        r1_prok="results/02_SCREENING/{sample}/{sample}_R1_prokaryote.fastq.gz",
        r2_prok="results/02_SCREENING/{sample}/{sample}_R2_prokaryote.fastq.gz",
        r1_euk="results/02_SCREENING/{sample}/{sample}_R1_eukaryote.fastq.gz",
        r2_euk="results/02_SCREENING/{sample}/{sample}_R2_eukaryote.fastq.gz"
    params:
        mode=config["params"]["domain_filter"]["mode"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/kraken2.yaml"
    threads: 1  # extract_kraken_reads.py has no multithreading option
    log: "logs/screening/{sample}_extract_domain_short.log"
    shell:
        # "$PY" "$EKR" instead of a bare extract_kraken_reads.py: conda leaves
        # KrakenTools' scripts with a plain `#!/usr/bin/env python` shebang (it
        # rewrites most packages' but not this one), so running it directly
        # resolves `python` through PATH and picks up whatever interpreter comes
        # first -- which lacks this env's Biopython. The backend strips its own
        # venv from PATH for exactly this reason (see _snakemake_env in
        # backend/main.py); this keeps the rule correct when Snakemake is
        # invoked by hand too.
        """
        PY="${{CONDA_PREFIX:+$CONDA_PREFIX/bin/}}python"
        EKR="$(command -v extract_kraken_reads.py)"
        if [ "{params.rtype}" == "short" ] || [ "{params.rtype}" == "hybrid" ]; then
            if [ "{params.mode}" == "prokaryote" ] || [ "{params.mode}" == "both" ]; then
                "$PY" "$EKR" -k {input.kraken_out} -r {input.kraken_report} \
                    -s1 {input.r1} -s2 {input.r2} -t 2 2157 --include-children --fastq-output \
                    -o {output.r1_prok}.tmp -o2 {output.r2_prok}.tmp > {log} 2>&1
                gzip -c {output.r1_prok}.tmp > {output.r1_prok} && rm {output.r1_prok}.tmp
                gzip -c {output.r2_prok}.tmp > {output.r2_prok} && rm {output.r2_prok}.tmp
            else
                touch {output.r1_prok} {output.r2_prok}
            fi
            if [ "{params.mode}" == "eukaryote" ] || [ "{params.mode}" == "both" ]; then
                "$PY" "$EKR" -k {input.kraken_out} -r {input.kraken_report} \
                    -s1 {input.r1} -s2 {input.r2} -t 2759 --include-children --fastq-output \
                    -o {output.r1_euk}.tmp -o2 {output.r2_euk}.tmp >> {log} 2>&1
                gzip -c {output.r1_euk}.tmp > {output.r1_euk} && rm {output.r1_euk}.tmp
                gzip -c {output.r2_euk}.tmp > {output.r2_euk} && rm {output.r2_euk}.tmp
            else
                touch {output.r1_euk} {output.r2_euk}
            fi
        else
            touch {output.r1_prok} {output.r2_prok} {output.r1_euk} {output.r2_euk}
        fi
        """

rule extract_domain_long:
    input:
        long="results/01_QC/{sample}/{sample}_clean.fastq.gz",
        kraken_out="results/02_SCREENING/{sample}/{sample}_kraken2.output",
        kraken_report="results/02_SCREENING/{sample}/{sample}_kraken2.kreport"
    output:
        prok="results/02_SCREENING/{sample}/{sample}_prokaryote.fastq.gz",
        euk="results/02_SCREENING/{sample}/{sample}_eukaryote.fastq.gz"
    params:
        mode=config["params"]["domain_filter"]["mode"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/kraken2.yaml"
    threads: 1
    log: "logs/screening/{sample}_extract_domain_long.log"
    shell:
        # "$PY" "$EKR" instead of a bare extract_kraken_reads.py -- same reason
        # as extract_domain_short above (KrakenTools keeps an unrewritten
        # `#!/usr/bin/env python` shebang).
        """
        PY="${{CONDA_PREFIX:+$CONDA_PREFIX/bin/}}python"
        EKR="$(command -v extract_kraken_reads.py)"
        if [ "{params.rtype}" == "long" ] || [ "{params.rtype}" == "hybrid" ]; then
            if [ "{params.mode}" == "prokaryote" ] || [ "{params.mode}" == "both" ]; then
                "$PY" "$EKR" -k {input.kraken_out} -r {input.kraken_report} \
                    -s1 {input.long} -t 2 2157 --include-children --fastq-output \
                    -o {output.prok}.tmp > {log} 2>&1
                gzip -c {output.prok}.tmp > {output.prok} && rm {output.prok}.tmp
            else
                touch {output.prok}
            fi
            if [ "{params.mode}" == "eukaryote" ] || [ "{params.mode}" == "both" ]; then
                "$PY" "$EKR" -k {input.kraken_out} -r {input.kraken_report} \
                    -s1 {input.long} -t 2759 --include-children --fastq-output \
                    -o {output.euk}.tmp >> {log} 2>&1
                gzip -c {output.euk}.tmp > {output.euk} && rm {output.euk}.tmp
            else
                touch {output.euk}
            fi
        else
            touch {output.prok} {output.euk}
        fi
        """
