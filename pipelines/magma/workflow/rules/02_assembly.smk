import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule megahit:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz"
    output:
        contigs="results/02_ASSEMBLY/{sample}/megahit/final.contigs.fa",
        outdir=directory("results/02_ASSEMBLY/{sample}/megahit")
    params: extra=config["params"]["megahit"]
    threads: config["threads"]["megahit"]
    conda: "../envs/megahit.yaml"
    log: "logs/megahit/{sample}.log"
    benchmark: "benchmarks/megahit/{sample}.tsv"
    shell:
        """
        rm -rf {output.outdir}
        megahit -1 {input.r1} -2 {input.r2} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

# Depth normalization of the short reads before hybrid metaSPAdes (BBNorm).
# A dominant organism at very high depth makes metaSPAdes leave uncollapsed
# bubbles: on the ZymoBIOMICS Log community, Listeria (~89% of reads,
# k-mer coverage ~1,150x) assembled into 94 contigs summing 4.43 Mb for a
# 2.99 Mb genome (about half the genome in 2+ near-identical copies). CheckM2
# read the duplicated markers as contamination and the best Listeria bin
# fell to 64% completeness. Capping depth at 100x (target=100) with no
# low-depth filtering (min=0, so low-abundance organisms keep every read)
# gave 47 contigs summing 2.97 Mb, with the other species' genome fraction
# unchanged. Only the assembly input is normalized: read mapping for
# binning coverage still uses the original reads. Brown et al. 2012
# (arXiv:1203.4802); Howe et al. 2014, PNAS 111:4904 (doi:10.1073/pnas.1402564111).
BBNORM_ACTIVE = "bbnorm" in (config.get("active_tools") or [])


def _bbnorm_args():
    # Manifest flags arrive as "target 100 min 0"; BBTools wants key=value.
    toks = str(config["params"].get("bbnorm", "")).split()
    return " ".join(f"{k}={v}" for k, v in zip(toks[0::2], toks[1::2]))


rule bbnorm:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz"
    output:
        r1="results/02_ASSEMBLY/{sample}/bbnorm/{sample}_R1_norm.fastq.gz",
        r2="results/02_ASSEMBLY/{sample}/bbnorm/{sample}_R2_norm.fastq.gz"
    params:
        extra=_bbnorm_args()
    threads: config["threads"].get("bbnorm", 16)
    conda: "../envs/bbnorm.yaml"
    log: "logs/assembly/{sample}_bbnorm.log"
    benchmark: "benchmarks/assembly/{sample}_bbnorm.tsv"
    shell:
        """
        bbnorm.sh in={input.r1} in2={input.r2} out={output.r1} out2={output.r2} \
            threads={threads} {params.extra} > {log} 2>&1
        """


def _assembly_short_reads(wildcards):
    if BBNORM_ACTIVE:
        return {
            "r1": f"results/02_ASSEMBLY/{wildcards.sample}/bbnorm/{wildcards.sample}_R1_norm.fastq.gz",
            "r2": f"results/02_ASSEMBLY/{wildcards.sample}/bbnorm/{wildcards.sample}_R2_norm.fastq.gz",
        }
    return {
        "r1": f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R1_clean.fastq.gz",
        "r2": f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R2_clean.fastq.gz",
    }


rule metaspades_hybrid:
    input:
        unpack(_assembly_short_reads),
        nano="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        "results/02_ASSEMBLY/{sample}/metaspades_hybrid/contigs.fasta"
    params:
        extra=config["params"]["metaspades_hybrid"],
        # --nanopore vs --pacbio depends on the user's long-read platform
        # choice (Inputs tab) -- previously hardcoded to --nanopore regardless
        # of the actual platform, which is wrong for PacBio long reads.
        platform_flag=config["long_read_platform"]["spades_flag"]
    log:
        "logs/assembly/{sample}_metaspades_hybrid.log"
    benchmark: "benchmarks/assembly/{sample}_metaspades_hybrid.tsv"
    conda:
        "../envs/spades.yaml"
    threads: config["threads"]["metaspades_hybrid"]
    shell:
        """
        spades.py --meta -t {threads} \
        -1 {input.r1} -2 {input.r2} {params.platform_flag} {input.nano} {params.extra} \
        -o results/02_ASSEMBLY/{wildcards.sample}/metaspades_hybrid > {log} 2>&1
        """

rule flye:
    input:
        reads="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        fasta="results/02_ASSEMBLY/{sample}/flye/assembly.fasta",
        outdir=directory("results/02_ASSEMBLY/{sample}/flye")
    params:
        extra=config["params"]["flye"],
        # --nano-raw / --nano-hq / --pacbio-raw / --pacbio-hifi depends on the
        # user's long-read platform choice -- previously hardcoded to
        # --nano-hq regardless of what was actually sequenced.
        platform_flag=config["long_read_platform"]["flye_flag"]
    log:
        "logs/flye/{sample}.log"
    benchmark: "benchmarks/flye/{sample}.tsv"
    threads: config["threads"]["flye"]
    conda: "../envs/flye.yaml"
    resources: tmpdir="/tmp"
    shell:
        """
        flye {params.platform_flag} {input.reads} --out-dir {output.outdir} --meta --threads {threads} {params.extra} > {log} 2>&1
        """

ASSEMBLER_FOR_READ_TYPE = {
    "short": "megahit",
    "long": "flye",
    "hybrid": "metaspades_hybrid",
}

def get_assembly_output(wildcards):
    read_type = samples.loc[wildcards.sample, "read_type"]
    assembler = samples.loc[wildcards.sample, "assembler"]
    expected = ASSEMBLER_FOR_READ_TYPE.get(read_type)
    if assembler != expected:
        raise ValueError(
            f"Assembler '{assembler}' is not valid for sample '{wildcards.sample}' "
            f"(read_type='{read_type}'). Expected '{expected}': "
            "'megahit' for short, 'flye' for long, 'metaspades_hybrid' for hybrid."
        )
    if assembler == "megahit":
        return f"results/02_ASSEMBLY/{wildcards.sample}/megahit/final.contigs.fa"
    elif assembler == "flye":
        return f"results/02_ASSEMBLY/{wildcards.sample}/flye/assembly.fasta"
    elif assembler == "metaspades_hybrid":
        return f"results/02_ASSEMBLY/{wildcards.sample}/metaspades_hybrid/contigs.fasta"

rule finalize_assembly:
    input: get_assembly_output
    output: "results/02_ASSEMBLY/{sample}/final.contigs.fa"
    log: "logs/assembly/{sample}_finalize.log"
    benchmark: "benchmarks/assembly/{sample}_finalize.tsv"
    shell: "cp {input} {output} 2> {log}"

rule metaquast:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs.fa"
    output:
        outdir=directory("results/02_ASSEMBLY/{sample}/metaquast")
    params:
        extra=config["params"]["metaquast"]
    threads: config["threads"]["metaquast"]
    conda: "../envs/quast.yaml"
    log: "logs/metaquast/{sample}.log"
    benchmark: "benchmarks/metaquast/{sample}.tsv"
    shell:
        "metaquast.py {input.contigs} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1"

rule tiara:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs.fa"
    output:
        classifications="results/02_ASSEMBLY/{sample}/tiara/classifications.txt",
        log_out="results/02_ASSEMBLY/{sample}/tiara/log_classifications.txt"
    params:
        extra=config["params"]["tiara"]
    threads: config["threads"]["tiara"]
    conda: "../envs/tiara.yaml"
    log: "logs/tiara/{sample}.log"
    benchmark: "benchmarks/tiara/{sample}.tsv"
    shell:
        """
        mkdir -p $(dirname {output.classifications}) $(dirname {log})
        contigs_abs=$(realpath {input.contigs})
        log_abs=$(realpath {log})
        cd $(dirname {output.classifications}) && \
        tiara -i "$contigs_abs" -o $(basename {output.classifications}) \
            -t {threads} {params.extra} > "$log_abs" 2>&1
        """

rule filter_prokaryotes:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs.fa",
        classifications="results/02_ASSEMBLY/{sample}/tiara/classifications.txt"
    output:
        prok="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        ids_keep="results/02_ASSEMBLY/{sample}/tiara/prokaryotic_ids.txt",
        ids_drop="results/02_ASSEMBLY/{sample}/tiara/eukaryotic_organelle_ids.txt"
    conda: "../envs/tiara.yaml"
    log: "logs/tiara/{sample}_filter.log"
    benchmark: "benchmarks/tiara/{sample}_filter.tsv"
    shell:
        """
        mkdir -p $(dirname {output.ids_keep})
        # col2: primary class; col3: secondary class (organelles only). ID is first word of col1.
        awk -F'\\t' 'NR>1 && $2 != "eukarya" && $3 !~ /^(mitochondrion|plastid)$/ {{split($1, a, " "); print a[1]}}' \
            {input.classifications} > {output.ids_keep}
        awk -F'\\t' 'NR>1 && ($2 == "eukarya" || $3 ~ /^(mitochondrion|plastid)$/) {{split($1, a, " "); print a[1]}}' \
            {input.classifications} > {output.ids_drop}
        seqkit grep -f {output.ids_keep} {input.contigs} -o {output.prok} > {log} 2>&1
        """

rule metaquast_prokaryotic:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        outdir=directory("results/02_ASSEMBLY/{sample}/metaquast_prokaryotic")
    params:
        extra=config["params"]["metaquast"]
    threads: config["threads"]["metaquast"]
    conda: "../envs/quast.yaml"
    log: "logs/metaquast/{sample}_prokaryotic.log"
    benchmark: "benchmarks/metaquast/{sample}_prokaryotic.tsv"
    shell:
        "metaquast.py {input.contigs} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1"
