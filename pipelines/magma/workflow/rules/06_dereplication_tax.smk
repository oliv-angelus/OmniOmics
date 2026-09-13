import pandas as pd
import os
import shutil

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule pool_hq_mags:
    """Also writes genome_info.csv (genome,completeness,contamination) with the
    CheckM2 numbers already computed here, so rule drep can hand it to dRep via
    --genomeInfo. Without it, dRep's own filter step tries to run classic
    CheckM1 (a separate binary/database from CheckM2, not part of envs/drep.yaml)
    to (re-)score every genome -- when checkm1 isn't on PATH this fails
    silently from Snakemake's point of view (dRep still exits 0 and creates an
    empty dereplicated_genomes/, since directory() outputs only check
    existence), which is what happened on the RAPA02 test run, 2026-08-28
    (logs/drep/drep.log: "Cannot locate the program checkm").
    """
    input:
        reports=expand("results/06_MAG_REFINEMENT/{sample}/checkm2/quality_report.tsv", sample=samples.index),
        bins=expand("results/06_MAG_REFINEMENT/{sample}/binette/final_bins", sample=samples.index)
    output:
        outdir=directory("results/07_DEREP/all_hq_mags"),
        genome_info="results/07_DEREP/genome_info.csv"
    params:
        comp=config["params"]["mags_annot"]["hq_min_completeness"],
        cont=config["params"]["mags_annot"]["hq_max_contamination"]
    run:
        os.makedirs(output.outdir, exist_ok=True)
        rows = []
        for report_file, bin_dir in zip(input.reports, input.bins):
            sample_name = report_file.split("/")[-3]
            df = pd.read_csv(report_file, sep="\t")
            hq_mags = df[(df["Completeness"] >= params.comp) & (df["Contamination"] <= params.cont)]
            for _, row in hq_mags.iterrows():
                mag_name = row["Name"]
                src = os.path.join(bin_dir, f"{mag_name}.fa")
                if os.path.exists(src):
                    dst_name = f"{sample_name}_{mag_name}.fa"
                    shutil.copy2(src, os.path.join(output.outdir, dst_name))
                    rows.append((dst_name, row["Completeness"], row["Contamination"]))
        pd.DataFrame(rows, columns=["genome", "completeness", "contamination"]).to_csv(
            output.genome_info, index=False
        )

rule drep:
    input:
        bins_dir="results/07_DEREP/all_hq_mags",
        genome_info="results/07_DEREP/genome_info.csv"
    output:
        outdir=directory("results/07_DEREP/drep_out"),
        dereplicated_dir=directory("results/07_DEREP/drep_out/dereplicated_genomes")
    params:
        extra=config["params"]["drep"]
    threads: config["threads"]["drep"]
    conda: "../envs/drep.yaml"
    log: "logs/drep/drep.log"
    shell:
        """
        n_mags=$(find {input.bins_dir} -maxdepth 1 -name "*.fa" | wc -l)
        if [ "$n_mags" -eq 0 ]; then
            echo "No HQ MAGs available for dereplication." | tee {log}
            mkdir -p {output.dereplicated_dir}
        else
            rm -rf {output.outdir}
            dRep dereplicate {output.outdir} -g {input.bins_dir}/*.fa \
                --genomeInfo {input.genome_info} -p {threads} {params.extra} > {log} 2>&1
        fi
        """

rule gtdbtk:
    input:
        bins="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/08_MAG_TAXONOMY/gtdbtk")
    params:
        db=config["databases"]["gtdbtk"],
        extra=config["params"]["gtdbtk"]
    threads: config["threads"]["gtdbtk"]
    conda: "../envs/gtdbtk.yaml"
    log: "logs/gtdbtk/gtdbtk.log"
    shell:
        """
        n_mags=$(find {input.bins} -maxdepth 1 -name "*.fa" | wc -l)
        if [ "$n_mags" -eq 0 ]; then
            echo "No dereplicated MAGs found; GTDB-Tk skipped." | tee {log}
            mkdir -p {output.outdir}
        else
            export GTDBTK_DATA_PATH={params.db}
            gtdbtk classify_wf --genome_dir {input.bins} --out_dir {output.outdir} --extension fa --cpus {threads} {params.extra} > {log} 2>&1
        fi
        """
