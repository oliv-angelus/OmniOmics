import pandas as pd

# fillna("") -- Snakemake's include: pastes every rule file into one shared
# namespace, so whichever file's "samples =..." runs *last* wins for the
# whole Snakefile; keeping this consistent across every file that redefines
# it avoids a later, un-filled reassignment silently turning empty optional
# cells (e.g. "reference") back into NaN for earlier files' rules.
samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule unicycler:
    """Handles both short-only and hybrid assembly -- Unicycler wraps SPAdes
    for the short-read graph and (when long reads are given via -l) bridges
    repeats with them; MEGAHIT was considered but is tuned for large, uneven-
    coverage metagenomic assemblies rather than single isolate genomes, and
    Unicycler natively covers both the short and hybrid cases MAGMA needed two
    separate assemblers for."""
    input:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        nano="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        "results/02_ASSEMBLY/{sample}/unicycler/assembly.fasta"
    params:
        extra=config["params"]["unicycler"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/unicycler.yaml"
    threads: config["threads"]["unicycler"]
    log: "logs/assembly/{sample}_unicycler.log"
    shell:
        """
        if [ "{params.rtype}" == "hybrid" ]; then
            unicycler -1 {input.r1} -2 {input.r2} -l {input.nano} \
                -o results/02_ASSEMBLY/{wildcards.sample}/unicycler -t {threads} {params.extra} > {log} 2>&1
        else
            unicycler -1 {input.r1} -2 {input.r2} \
                -o results/02_ASSEMBLY/{wildcards.sample}/unicycler -t {threads} {params.extra} > {log} 2>&1
        fi
        """

rule flye:
    input:
        reads="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        fasta="results/02_ASSEMBLY/{sample}/flye/assembly.fasta",
        outdir=directory("results/02_ASSEMBLY/{sample}/flye")
    params:
        extra=config["params"]["flye"],
        # --nano-raw / --nano-hq / --pacbio-raw / --pacbio-hifi, per the
        # user's long-read platform choice in the Inputs tab.
        platform_flag=config["long_read_platform"]["flye_flag"]
    log:
        "logs/flye/{sample}.log"
    threads: config["threads"]["flye"]
    conda: "../envs/flye.yaml"
    resources: tmpdir="/tmp"
    shell:
        """
        flye {params.platform_flag} {input.reads} --out-dir {output.outdir} --threads {threads} {params.extra} > {log} 2>&1
        """

ASSEMBLER_FOR_READ_TYPE = {
    "short": "unicycler",
    "long": "flye",
    "hybrid": "unicycler",
}

def get_assembly_output(wildcards):
    read_type = samples.loc[wildcards.sample, "read_type"]
    assembler = samples.loc[wildcards.sample, "assembler"]
    expected = ASSEMBLER_FOR_READ_TYPE.get(read_type)
    if assembler != expected:
        raise ValueError(
            f"Assembler '{assembler}' is not valid for sample '{wildcards.sample}' "
            f"(read_type='{read_type}'). Expected '{expected}': "
            "'unicycler' for short/hybrid, 'flye' for long."
        )
    if assembler == "unicycler":
        return f"results/02_ASSEMBLY/{wildcards.sample}/unicycler/assembly.fasta"
    elif assembler == "flye":
        return f"results/02_ASSEMBLY/{wildcards.sample}/flye/assembly.fasta"

rule finalize_assembly:
    input: get_assembly_output
    output: "results/02_ASSEMBLY/{sample}/final.contigs.fa"
    log: "logs/assembly/{sample}_finalize.log"
    shell: "cp {input} {output} 2> {log}"
