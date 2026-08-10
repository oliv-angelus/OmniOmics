# binette refines/dereplicates across whichever binners the config enables --
# needs at least 2 to do any meaningful consensus refinement. Validated at
# parse time (same convention as finalize_assembly's assembler/read_type
# check in 02_assembly.smk) so a bad config fails fast, before the DAG runs.
ACTIVE_BINNERS = config.get("active_binners") or ["metabat2", "semibin2", "vamb", "maxbin2"]
if len(ACTIVE_BINNERS) < 2:
    raise ValueError(
        f"binette requires at least 2 active binners in config['active_binners'], got {ACTIVE_BINNERS!r}. "
        "Enable at least two of: metabat2, semibin2, vamb, maxbin2."
    )

# Each binner's actual bin-FASTA output lives in a different subpath.
BINNER_BIN_SUBDIR = {"metabat2": "", "semibin2": "/output_bins", "vamb": "/bins", "maxbin2": ""}

def get_binner_dirs(wildcards):
    return [f"results/05_BINNING/{wildcards.sample}/{b}" for b in ACTIVE_BINNERS]

def get_bin_dirs_arg(wildcards, input):
    return " ".join(f"{d}{BINNER_BIN_SUBDIR[b]}" for d, b in zip(input.bin_dirs, ACTIVE_BINNERS))

rule binette:
    input:
        contigs="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        bin_dirs=get_binner_dirs
    output:
        bins=directory("results/06_MAG_REFINEMENT/{sample}/binette/final_bins"),
        report="results/06_MAG_REFINEMENT/{sample}/binette/final_bins_quality_reports.tsv"
    params:
        db=config["databases"]["checkm2"],
        extra=config["params"]["binette"],
        outdir="results/06_MAG_REFINEMENT/{sample}/binette",
        bin_dirs_arg=get_bin_dirs_arg
    threads: config["threads"]["binette"]
    conda: "../envs/binette.yaml"
    log: "logs/binette/{sample}.log"
    shell:
        """
        rm -rf {params.outdir}
        binette --bin_dirs {params.bin_dirs_arg} \
                --contigs {input.contigs} \
                --checkm2_db {params.db} \
                --outdir {params.outdir} \
                --threads {threads} \
                {params.extra} > {log} 2>&1
        """

rule checkm2:
    input:
        bins="results/06_MAG_REFINEMENT/{sample}/binette/final_bins"
    output:
        report="results/06_MAG_REFINEMENT/{sample}/checkm2/quality_report.tsv",
        outdir=directory("results/06_MAG_REFINEMENT/{sample}/checkm2")
    params:
        db=config["databases"]["checkm2"],
        extra=config["params"]["checkm2"]
    threads: config["threads"]["checkm2"]
    conda: "../envs/checkm2.yaml"
    log: "logs/checkm2/{sample}.log"
    shell:
        """
        rm -rf {output.outdir}
        checkm2 predict --threads {threads} --input {input.bins} -x fa --output-directory {output.outdir} --database_path {params.db} {params.extra} > {log} 2>&1
        """

rule gunc:
    input:
        bins="results/06_MAG_REFINEMENT/{sample}/binette/final_bins"
    output:
        outdir=directory("results/06_MAG_REFINEMENT/{sample}/gunc")
    params:
        extra=config["params"]["gunc"]
    threads: config["threads"]["gunc"]
    conda: "../envs/gunc.yaml"
    log: "logs/gunc/{sample}.log"
    shell:
        """
        rm -rf {output.outdir}
        gunc run --input_dir {input.bins} --file_suffix.fa --out_dir {output.outdir} --threads {threads} {params.extra} > {log} 2>&1
        """
