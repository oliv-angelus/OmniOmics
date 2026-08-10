import pandas as pd
import os
import glob

# fillna("") -- see the comment in 02_assembly.smk: include: shares one
# namespace, so every file redefining "samples" needs this for consistency
# regardless of which one's assignment ends up executing last.
samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# Pre-assembly contamination screening on the clean reads -- SIGMA has no
# equivalent of MAGMA's read-level taxonomy step, so a mixed/contaminated
# culture would otherwise only surface much later (a messy assembly, or a
# GTDB-Tk call that doesn't match what was expected) instead of being caught
# right after QC. Both tools are independent of each other and of everything
# downstream -- either, both, or neither can be active.
def get_qc_reads(wildcards):
    row = samples.loc[wildcards.sample]
    if row["read_type"] in ["short", "hybrid"]:
        return [f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R1_clean.fastq.gz",
                f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R2_clean.fastq.gz"]
    else:
        return [f"results/01_QC/{wildcards.sample}/{wildcards.sample}_clean.fastq.gz"]

rule kraken2:
    input: reads=get_qc_reads
    output:
        report="results/00_SCREENING/{sample}/{sample}_kraken2.kreport",
        output="results/00_SCREENING/{sample}/{sample}_kraken2.output"
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
    input: reads=get_qc_reads
    output:
        out="results/00_SCREENING/{sample}/{sample}_kaiju.out"
    params:
        nodes=lambda wc: os.path.join(config["databases"]["kaiju"], "nodes.dmp"),
        fmi=lambda wc: glob.glob(os.path.join(config["databases"]["kaiju"], "*.fmi"))[0],
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
        out="results/00_SCREENING/{sample}/{sample}_kaiju.out"
    output:
        table="results/00_SCREENING/{sample}/{sample}_kaiju_species.tsv",
        names="results/00_SCREENING/{sample}/{sample}_kaiju_named.out"
    params:
        nodes=lambda wc: os.path.join(config["databases"]["kaiju"], "nodes.dmp"),
        names_dmp=lambda wc: os.path.join(config["databases"]["kaiju"], "names.dmp")
    conda: "../envs/kaiju.yaml"
    threads: 1  # kaiju2table/addTaxonNames have no multithreading option
    log: "logs/screening/{sample}_kaiju_table.log"
    shell:
        """
        kaiju2table -t {params.nodes} -n {params.names_dmp} -r species -o {output.table} {input.out} > {log} 2>&1
        kaiju-addTaxonNames -t {params.nodes} -n {params.names_dmp} -i {input.out} -o {output.names} >> {log} 2>&1
        """
