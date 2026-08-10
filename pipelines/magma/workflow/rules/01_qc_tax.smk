import pandas as pd
import os
import glob

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

def get_qc_reads(wildcards):
    row = samples.loc[wildcards.sample]
    if row["read_type"] in ["short", "hybrid"]:
        return [f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R1_clean.fastq.gz",
                f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R2_clean.fastq.gz"]
    else:
        return [f"results/01_QC/{wildcards.sample}/{wildcards.sample}_clean.fastq.gz"]

rule fastp:
    input:
        r1=lambda wildcards: samples.loc[wildcards.sample, "fq1"] if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else [],
        r2=lambda wildcards: samples.loc[wildcards.sample, "fq2"] if samples.loc[wildcards.sample, "read_type"] in ["short", "hybrid"] else []
    output:
        r1="results/01_QC/{sample}/{sample}_R1_clean.fastq.gz",
        r2="results/01_QC/{sample}/{sample}_R2_clean.fastq.gz",
        html="results/01_QC/{sample}/{sample}_fastp.html",
        json="results/01_QC/{sample}/{sample}_fastp.json"
    params:
        extra=config["params"]["fastp"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/qc.yaml"
    log: "logs/fastp/{sample}.log"
    threads: config["threads"]["fastp"]
    shell:
        """
        if [ "{params.rtype}" == "short" ] || [ "{params.rtype}" == "hybrid" ]; then
            fastp {params.extra} --thread {threads} -i {input.r1} -I {input.r2} -o {output.r1} -O {output.r2} -h {output.html} -j {output.json()} 2> {log}
        else
            touch {output.r1} {output.r2} {output.html} {output.json()}
        fi
        """

rule filtlong:
    input:
        long=lambda wildcards: samples.loc[wildcards.sample, "fq_long"] if samples.loc[wildcards.sample, "read_type"] in ["long", "hybrid"] else []
    output:
        long="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    params:
        extra=config["params"]["filtlong"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/qc.yaml"
    log: "logs/filtlong/{sample}.log"
    threads: 1  # Filtlong has no multithreading option -- not configurable on the Resources tab
    shell:
        """
        if [ "{params.rtype}" == "long" ] || [ "{params.rtype}" == "hybrid" ]; then
            filtlong {params.extra} {input.long} 2> {log} | gzip > {output.long}
        else
            touch {output.long}
        fi
        """

rule nanoplot_raw:
    input:
        long=lambda wildcards: samples.loc[wildcards.sample, "fq_long"]
    output:
        outdir=directory("results/01_QC/{sample}/nanoplot_raw"),
        stats="results/01_QC/{sample}/nanoplot_raw/NanoStats.txt"
    threads: 4
    conda: "../envs/nanoplot.yaml"
    log: "logs/nanoplot/{sample}_raw.log"
    shell:
        "NanoPlot --fastq {input.long} -o {output.outdir} -t {threads} > {log} 2>&1"

rule nanoplot_clean:
    input:
        long="results/01_QC/{sample}/{sample}_clean.fastq.gz"
    output:
        outdir=directory("results/01_QC/{sample}/nanoplot_clean"),
        stats="results/01_QC/{sample}/nanoplot_clean/NanoStats.txt"
    threads: 4
    conda: "../envs/nanoplot.yaml"
    log: "logs/nanoplot/{sample}_clean.log"
    shell:
        "NanoPlot --fastq {input.long} -o {output.outdir} -t {threads} > {log} 2>&1"

rule kraken2:
    input: reads=get_qc_reads
    output:
        report="results/03_TAXONOMY/{sample}/{sample}_kraken2.kreport",
        output="results/03_TAXONOMY/{sample}/{sample}_kraken2.output"
    params:
        db=config["databases"]["kraken2"],
        extra=config["params"]["kraken2"],
        paired=lambda wildcards, input: "--paired" if len(input.reads) == 2 else ""
    conda: "../envs/taxonomy.yaml"
    threads: config["threads"]["kraken2"]
    log: "logs/kraken2/{sample}.log"
    shell:
        "kraken2 --db {params.db} --threads {threads} {params.extra} {params.paired} "
        "--report {output.report} {input.reads} > {output.output} 2> {log}"

rule bracken:
    input:
        report="results/03_TAXONOMY/{sample}/{sample}_kraken2.kreport"
    output:
        report="results/03_TAXONOMY/{sample}/{sample}_bracken.kreport",
        txt="results/03_TAXONOMY/{sample}/{sample}_bracken.txt"
    params:
        db=config["databases"]["kraken2"],
        extra=config["params"]["bracken"],
        rtype=lambda wildcards: samples.loc[wildcards.sample, "read_type"]
    conda: "../envs/taxonomy.yaml"
    threads: 1  # Bracken has no multithreading option -- not configurable on the Resources tab
    log: "logs/bracken/{sample}.log"
    shell:
        """
        if [ "{params.rtype}" == "long" ]; then
            cp {input.report} {output.report}
            echo "Long-read sample: Bracken skipped." > {output.txt}
            echo "Bracken skipped for long-read sample." > {log}
        else
            bracken -d {params.db} -i {input.report} -o {output.txt} -w {output.report} {params.extra} > {log} 2>&1 || true
            if [ ! -f {output.report} ] || [ ! -f {output.txt} ]; then
                cp {input.report} {output.report}
                echo "Insufficient species for Bracken; falling back to Kraken2 report." > {output.txt}
                echo "Warning: Bracken produced no output; Kraken2 report used as fallback." >> {log}
            fi
        fi
        """

rule kreport2mpa:
    input:
        report="results/03_TAXONOMY/{sample}/{sample}_bracken.kreport"
    output:
        mpa="results/03_TAXONOMY/{sample}/{sample}.mpa"
    params:
        extra=config["params"]["kreport2mpa"]
    conda: "../envs/taxonomy.yaml"
    log: "logs/krakentools/{sample}_kreport2mpa.log"
    shell:
        # Explicit interpreter: conda leaves KrakenTools' scripts with a plain
        # `#!/usr/bin/env python` shebang (it rewrites most packages' but not
        # this one), so running it directly resolves `python` through PATH and
        # picks up whatever interpreter happens to come first -- which has none
        # of this env's dependencies. The backend strips its own venv from PATH
        # for exactly this reason (see _snakemake_env in backend/main.py); this
        # keeps the rule correct when Snakemake is invoked by hand too.
        """
        PY="${{CONDA_PREFIX:+$CONDA_PREFIX/bin/}}python"
        "$PY" "$(command -v kreport2mpa.py)" -r {input.report} -o {output.mpa} {params.extra} > {log} 2>&1
        """

rule consolidate_taxonomy:
    input:
        mpas=expand("results/03_TAXONOMY/{sample}/{sample}.mpa", sample=samples.index)
    output:
        final_table="results/03_TAXONOMY/abundance_table_final_RAW.tsv"
    run:
        import pandas as pd
        import os

        def read_sample(f):
            name = os.path.basename(f).replace(".mpa", "")
            return pd.read_csv(f, sep="\t", names=["tax", name]).set_index("tax")

        df = pd.concat([read_sample(f) for f in input.mpas], axis=1).fillna(0).astype(int)
        df.index = [str(i).replace("|", ";") for i in df.index]
        df = df[df.index != ""]
        df = df.groupby(df.index).sum()
        df["total"] = df.sum(axis=1)
        final_table = df.reset_index().rename(columns={"index": "tax"})
        final_table = final_table.sort_values(by="total", ascending=False)
        final_table.to_csv(output.final_table, sep="\t", index=False)

# ── Kaiju: protein-level alternative/complement to Kraken2 -- independent of
# it, both only need clean reads, so the user can turn on either, both, or
# neither. Kaiju's own output format (kaiju2table) isn't Kraken-report shaped,
# so it gets its own summary + consolidation instead of feeding Bracken/
# kreport2mpa, which are Kraken2-specific.
def kaiju_reads_flag(wildcards, input):
    return f"-i {input.reads[0]} -j {input.reads[1]}" if len(input.reads) == 2 else f"-i {input.reads[0]}"

rule kaiju_classify:
    input: reads=get_qc_reads
    output:
        out="results/03_TAXONOMY/{sample}/{sample}_kaiju.out"
    params:
        nodes=lambda wc: os.path.join(config["databases"]["kaiju"], "nodes.dmp"),
        fmi=lambda wc: glob.glob(os.path.join(config["databases"]["kaiju"], "*.fmi"))[0],
        extra=config["params"]["kaiju"],
        reads_flag=kaiju_reads_flag
    conda: "../envs/kaiju.yaml"
    threads: config["threads"]["kaiju"]
    log: "logs/kaiju/{sample}_classify.log"
    shell:
        "kaiju -z {threads} -t {params.nodes} -f {params.fmi} {params.reads_flag} "
        "{params.extra} -o {output.out} 2> {log}"

rule kaiju_table:
    input:
        out="results/03_TAXONOMY/{sample}/{sample}_kaiju.out"
    output:
        table="results/03_TAXONOMY/{sample}/{sample}_kaiju_species.tsv",
        names="results/03_TAXONOMY/{sample}/{sample}_kaiju_named.out"
    params:
        nodes=lambda wc: os.path.join(config["databases"]["kaiju"], "nodes.dmp"),
        names_dmp=lambda wc: os.path.join(config["databases"]["kaiju"], "names.dmp")
    conda: "../envs/kaiju.yaml"
    threads: 1  # kaiju2table/addTaxonNames have no multithreading option
    log: "logs/kaiju/{sample}_table.log"
    shell:
        """
        kaiju2table -t {params.nodes} -n {params.names_dmp} -r species -o {output.table} {input.out} > {log} 2>&1
        kaiju-addTaxonNames -t {params.nodes} -n {params.names_dmp} -i {input.out} -o {output.names} >> {log} 2>&1
        """

rule consolidate_taxonomy_kaiju:
    input:
        tables=expand("results/03_TAXONOMY/{sample}/{sample}_kaiju_species.tsv", sample=samples.index)
    output:
        final_table="results/03_TAXONOMY/abundance_table_final_kaiju_RAW.tsv"
    run:
        import pandas as pd
        import os

        def read_sample(f):
            name = os.path.basename(f).replace("_kaiju_species.tsv", "")
            df = pd.read_csv(f, sep="\t")
            df = df[["taxon_name", "reads"]].rename(columns={"reads": name})
            return df.set_index("taxon_name")

        df = pd.concat([read_sample(f) for f in input.tables], axis=1).fillna(0).astype(int)
        df = df.groupby(df.index).sum()
        df["total"] = df.sum(axis=1)
        final_table = df.reset_index().rename(columns={"index": "taxon_name"})
        final_table = final_table.sort_values(by="total", ascending=False)
        final_table.to_csv(output.final_table, sep="\t", index=False)
