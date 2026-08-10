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
    shell:
        """
        rm -rf {output.outdir}
        megahit -1 {input.r1} -2 {input.r2} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

rule metaspades_hybrid:
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
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
    shell:
        "metaquast.py {input.contigs} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1"
