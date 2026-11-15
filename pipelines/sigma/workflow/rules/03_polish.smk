import pandas as pd

# fillna("") -- an empty "reference" cell reads back as NaN, and bool(nan) is
# True in Python, which would wrongly treat every sample as having a reference.
samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# Polishing per read_type:
#   long   -> Flye, then Racon (+ Medaka for ONT) below.
#   hybrid -> Unicycler, then short-read polishing: Polypolish followed by
#             Pypolca --careful, the combination Bouras et al. 2024 found best
#             for polishing long-read-based bacterial assemblies with short
#             reads (Microbial Genomics 10:001254, doi:10.1099/mgen.0.001254;
#             Polypolish: Wick & Holt 2022, PLoS Comput Biol 18:e1009802,
#             doi:10.1371/journal.pcbi.1009802).
#   short  -> Unicycler output used as-is: Wick (2023, "Short-read polishing
#             of short-read assemblies", rrwick.github.io) found polishing a
#             short-read assembly with the same reads makes no difference or
#             introduces errors.
#
# Real bug fixed 2026-11-15: this file used to skip hybrid polishing on the
# premise that "Unicycler already runs its own Pilon rounds". That stopped
# being true in Unicycler v0.5.0 -- the version pinned in envs/unicycler.yaml
# -- whose release notes say Pilon polishing was removed from the pipeline and
# should be done separately. Hybrid assemblies were therefore never polished,
# which is consistent with the validation's QUAST mismatches/100 kbp rising
# from 6.06 (short-only) to 10.99 (ONT hybrid) and 12.69 (PacBio hybrid).
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
    benchmark: "benchmarks/polish/{sample}_racon.tsv"
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
    benchmark: "benchmarks/polish/{sample}_medaka.tsv"
    shell:
        """
        rm -rf {output.outdir}
        medaka_consensus -i {input.reads} -d {input.assembly} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

rule polypolish_polish:
    """Hybrid samples only: Polypolish uses every alignment of each short read
    (bwa mem -a, R1 and R2 aligned separately, as its documentation requires)
    to fix errors, including in repeats, without introducing new ones."""
    input:
        assembly="results/02_ASSEMBLY/{sample}/final.contigs.fa",
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz"
    output:
        polished="results/03_POLISH/{sample}/polypolish/polished.fasta"
    params:
        workdir="results/03_POLISH/{sample}/polypolish",
        extra=config["params"].get("polypolish", "")
    threads: config["threads"].get("polypolish", 16)
    conda: "../envs/polypolish.yaml"
    log: "logs/polish/{sample}_polypolish.log"
    benchmark: "benchmarks/polish/{sample}_polypolish.tsv"
    shell:
        """
        W={params.workdir}
        cp {input.assembly} $W/draft.fasta
        bwa index $W/draft.fasta > {log} 2>&1
        bwa mem -t {threads} -a $W/draft.fasta {input.r1} > $W/aln_1.sam 2>> {log}
        bwa mem -t {threads} -a $W/draft.fasta {input.r2} > $W/aln_2.sam 2>> {log}
        polypolish filter --in1 $W/aln_1.sam --in2 $W/aln_2.sam --out1 $W/filt_1.sam --out2 $W/filt_2.sam >> {log} 2>&1
        polypolish polish {params.extra} $W/draft.fasta $W/filt_1.sam $W/filt_2.sam > {output.polished} 2>> {log}
        rm -f $W/aln_1.sam $W/aln_2.sam $W/filt_1.sam $W/filt_2.sam $W/draft.fasta.*
        """

rule pypolca_polish:
    """Second short-read pass on Polypolish's output (Bouras et al. 2024
    recommend Polypolish then Pypolca --careful). --careful is the default
    param in the manifest; the user can drop it on the Tools tab."""
    input:
        assembly="results/03_POLISH/{sample}/polypolish/polished.fasta",
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz"
    output:
        polished="results/03_POLISH/{sample}/pypolca/pypolca_corrected.fasta"
    params:
        outdir="results/03_POLISH/{sample}/pypolca",
        extra=config["params"].get("pypolca", "--careful")
    threads: config["threads"].get("pypolca", 16)
    conda: "../envs/pypolca.yaml"
    log: "logs/polish/{sample}_pypolca.log"
    benchmark: "benchmarks/polish/{sample}_pypolca.tsv"
    shell:
        """
        pypolca run -a {input.assembly} -1 {input.r1} -2 {input.r2} -t {threads} \
            -o {params.outdir} -p pypolca -f {params.extra} > {log} 2>&1
        """

def get_polished_input(wildcards):
    read_type = samples.loc[wildcards.sample, "read_type"]
    if read_type == "hybrid":
        return f"results/03_POLISH/{wildcards.sample}/pypolca/pypolca_corrected.fasta"
    if read_type != "long":
        # Short-only Unicycler assemblies are used as-is (see header comment).
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
    benchmark: "benchmarks/polish/{sample}_ragtag.tsv"
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
    benchmark: "benchmarks/polish/{sample}_finalize.tsv"
    shell: "cp {input} {output} 2> {log}"
