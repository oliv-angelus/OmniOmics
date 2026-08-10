import pandas as pd

# fillna("") -- an empty "reference" cell reads back as NaN, and bool(nan) is
# True in Python, which would wrongly treat every sample as having a reference.
samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# Only long-only (Flye) assemblies get extra polishing here -- Unicycler
# already runs its own short-read error correction / Pilon rounds internally
# for the short and hybrid paths, so a second pass would be redundant.
#
# Medaka's models are trained on Nanopore basecaller error profiles, so it
# only runs for nano_raw/nano_hq; PacBio assemblies get Racon-only polishing.
_USE_MEDAKA = config["long_read_platform"]["id"] in ("nano_raw", "nano_hq")

rule racon_polish:
    input:
        assembly="results/02_ASSEMBLY/{sample}/flye/assembly.fasta",
        reads="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        overlaps=temp("results/03_POLISH/{sample}/racon/overlaps.sam"),
        polished="results/03_POLISH/{sample}/racon/polished.fasta"
    params:
        extra=config["params"]["racon"],
        minimap2_preset=config["long_read_platform"]["minimap2_preset"]
    threads: config["threads"]["racon"]
    conda: "../envs/racon.yaml"
    log: "logs/polish/{sample}_racon.log"
    shell:
        """
        minimap2 -ax {params.minimap2_preset} -t {threads} {input.assembly} {input.reads} > {output.overlaps} 2> {log}
        racon -t {threads} {params.extra} {input.reads} {output.overlaps} {input.assembly} > {output.polished} 2>> {log}
        """

rule medaka_polish:
    input:
        assembly="results/03_POLISH/{sample}/racon/polished.fasta",
        reads="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        outdir=directory("results/03_POLISH/{sample}/medaka"),
        consensus="results/03_POLISH/{sample}/medaka/consensus.fasta"
    params:
        extra=config["params"]["medaka"]
    threads: config["threads"]["medaka"]
    conda: "../envs/medaka.yaml"
    log: "logs/polish/{sample}_medaka.log"
    shell:
        """
        rm -rf {output.outdir}
        medaka_consensus -i {input.reads} -d {input.assembly} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

def get_polished_input(wildcards):
    read_type = samples.loc[wildcards.sample, "read_type"]
    if read_type != "long":
        # Unicycler (short/hybrid) already self-polishes -- pass its output through.
        return f"results/02_ASSEMBLY/{wildcards.sample}/final.contigs.fa"
    if _USE_MEDAKA:
        return f"results/03_POLISH/{wildcards.sample}/medaka/consensus.fasta"
    return f"results/03_POLISH/{wildcards.sample}/racon/polished.fasta"

rule ragtag_scaffold:
    """De novo vs reference-based assembly: only built for samples that got a
    matching folder under the reference genomes input -- RagTag orders/orients
    the already-assembled (and, for long-only, already-polished) contigs
    against that reference. This is scaffolding, not variant calling/consensus
    replacement: the original contig sequences are kept, just rearranged."""
    input:
        query=get_polished_input,
        ref=lambda wildcards: samples.loc[wildcards.sample, "reference"]
    output:
        outdir=directory("results/03_POLISH/{sample}/ragtag"),
        scaffold="results/03_POLISH/{sample}/ragtag/ragtag.scaffold.fasta"
    params:
        extra=config["params"]["ragtag"]
    threads: config["threads"]["ragtag"]
    conda: "../envs/ragtag.yaml"
    log: "logs/polish/{sample}_ragtag.log"
    shell:
        """
        rm -rf {output.outdir}
        ragtag.py scaffold {input.ref} {input.query} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

def get_final_input(wildcards):
    has_reference = bool(samples.loc[wildcards.sample, "reference"])
    if has_reference:
        return f"results/03_POLISH/{wildcards.sample}/ragtag/ragtag.scaffold.fasta"
    return get_polished_input(wildcards)

rule finalize_polish:
    input: get_final_input
    output: "results/03_POLISH/{sample}/final_polished.fa"
    log: "logs/polish/{sample}_finalize.log"
    shell: "cp {input} {output} 2> {log}"
