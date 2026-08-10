import pandas as pd
import os
import shutil

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

rule pool_hq_mags:
    input:
        reports=expand("results/06_MAG_REFINEMENT/{sample}/checkm2/quality_report.tsv", sample=samples.index),
        bins=expand("results/06_MAG_REFINEMENT/{sample}/binette/final_bins", sample=samples.index)
    output:
        outdir=directory("results/07_DEREP/all_hq_mags")
    params:
        comp=config["params"]["mags_annot"]["hq_min_completeness"],
        cont=config["params"]["mags_annot"]["hq_max_contamination"]
    run:
        os.makedirs(output.outdir, exist_ok=True)
        for report_file, bin_dir in zip(input.reports, input.bins):
            sample_name = report_file.split("/")[-3]
            df = pd.read_csv(report_file, sep="\t")
            hq_mags = df[(df["Completeness"] >= params.comp) & (df["Contamination"] <= params.cont)]
            for mag_name in hq_mags["Name"]:
                src = os.path.join(bin_dir, f"{mag_name}.fa")
                if os.path.exists(src):
                    dst = os.path.join(output.outdir, f"{sample_name}_{mag_name}.fa")
                    shutil.copy2(src, dst)

rule drep:
    input:
        bins_dir="results/07_DEREP/all_hq_mags"
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
            dRep dereplicate {output.outdir} -g {input.bins_dir}/*.fa -p {threads} {params.extra} > {log} 2>&1
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
