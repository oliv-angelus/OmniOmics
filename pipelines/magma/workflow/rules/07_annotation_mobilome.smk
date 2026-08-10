import pandas as pd
import os

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# Annotation pipeline — two independent tracks:
# Track 1 (*_sample): per-sample annotation from prokaryotic contigs.
# Track 2 (*_mags):   per-MAG annotation from dereplicated genomes.


# ==============================================================================
# TRACK 1 — Per-sample annotation
# ==============================================================================

rule prodigal_sample:
    """Uses Pyrodigal instead of the original Prodigal binary: same gene-calling
    algorithm (validated to produce identical results to Prodigal v2.6.3), but
    actively maintained and -- unlike original Prodigal -- supports real
    multithreading (-j), so its thread count is configurable on the
    Resources tab again."""
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        faa="results/09_ANNOTATION/{sample}/prodigal/{sample}_proteins.faa",
        gff="results/09_ANNOTATION/{sample}/prodigal/{sample}_coords.gff"
    params:
        extra=config["params"]["prodigal"]
    threads: config["threads"]["prodigal"]
    conda: "../envs/pyrodigal.yaml"
    log: "logs/annotation/{sample}_prodigal.log"
    shell:
        "pyrodigal -i {input.fa} -a {output.faa} -o {output.gff} -p meta -f gff -j {threads} {params.extra} > {log} 2>&1"

rule eggnog_sample:
    input:
        faa="results/09_ANNOTATION/{sample}/prodigal/{sample}_proteins.faa"
    output:
        annot="results/09_ANNOTATION/{sample}/eggnog/{sample}_annotations.emapper.annotations"
    params:
        db=config["databases"]["eggnog"],
        extra=config["params"]["eggnog"],
        out_prefix="results/09_ANNOTATION/{sample}/eggnog/{sample}_annotations"
    threads: config["threads"]["eggnog"]
    conda: "../envs/eggnog.yaml"
    log: "logs/annotation/{sample}_eggnog.log"
    shell:
        "emapper.py -m diamond -i {input.faa} --data_dir {params.db} -o {params.out_prefix} --cpu {threads} {params.extra} > {log} 2>&1"

rule abricate_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/abricate")
    params:
        extra=config["params"]["abricate"]
    threads: config["threads"]["abricate"]
    conda: "../envs/abricate.yaml"
    log: "logs/annotation/{sample}_abricate.log"
    shell:
        """
        mkdir -p {output.outdir}
        abricate --db ncbi --threads {threads} {params.extra} {input.fa} > {output.outdir}/ncbi_results.tab 2> {log}
        abricate --db card --threads {threads} {params.extra} {input.fa} > {output.outdir}/card_results.tab 2>> {log}
        """

rule amrfinder_sample:
    input:
        faa="results/09_ANNOTATION/{sample}/prodigal/{sample}_proteins.faa",
        fna="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa",
        gff="results/09_ANNOTATION/{sample}/prodigal/{sample}_coords.gff"
    output:
        out="results/09_ANNOTATION/{sample}/amrfinder/amrfinder_results.tsv"
    params:
        db=config["databases"]["amrfinderplus"],
        extra=config["params"]["amrfinderplus"]
    threads: config["threads"]["amrfinderplus"]
    conda: "../envs/amrfinder.yaml"
    log: "logs/annotation/{sample}_amrfinder.log"
    shell:
        """
        mkdir -p $(dirname {output.out})
        amrfinder -p {input.faa} -n {input.fna} -g {input.gff} \
            --database {params.db} --annotation_format prodigal \
            --plus --threads {threads} {params.extra} -o {output.out} > {log} 2>&1
        """

rule minced_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        crisprs="results/09_ANNOTATION/{sample}/minced/{sample}.crisprs",
        gff="results/09_ANNOTATION/{sample}/minced/{sample}.gff"
    params:
        extra=config["params"]["minced"]
    conda: "../envs/minced.yaml"
    log: "logs/annotation/{sample}_minced.log"
    shell:
        "minced -minNR 2 {params.extra} {input.fa} {output.crisprs} {output.gff} > {log} 2>&1"

rule virsorter2_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/virsorter2"),
        viral_fa="results/09_ANNOTATION/{sample}/virsorter2/final-viral-combined.fa"
    params:
        db=config["databases"]["virsorter2"],
        extra=config["params"]["virsorter2"]
    threads: config["threads"]["virsorter2"]
    conda: "../envs/virsorter2.yaml"
    log: "logs/annotation/{sample}_virsorter2.log"
    shell:
        """
        rm -rf {output.outdir}
        virsorter run -w {output.outdir} -i {input.fa} --db-dir {params.db} \
        --include-groups dsDNAphage,ssDNA -j {threads} {params.extra} all > {log} 2>&1
        if [ ! -f "{output.viral_fa}" ]; then
            touch "{output.viral_fa}"
        fi
        """

rule checkv_sample:
    input:
        fa="results/09_ANNOTATION/{sample}/virsorter2/final-viral-combined.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/checkv"),
        summary="results/09_ANNOTATION/{sample}/checkv/quality_summary.tsv"
    params:
        db=config["databases"]["checkv"],
        extra=config["params"]["checkv"]
    threads: config["threads"]["checkv"]
    conda: "../envs/checkv.yaml"
    log: "logs/annotation/{sample}_checkv.log"
    shell:
        """
        export CHECKVDB={params.db}
        checkv end_to_end {input.fa} {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """

rule genomad_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/genomad")
    params:
        db=config["databases"]["genomad"],
        extra=config["params"]["genomad"]
    threads: config["threads"]["genomad"]
    conda: "../envs/genomad.yaml"
    log: "logs/annotation/{sample}_genomad.log"
    shell:
        """
        rm -rf {output.outdir}
        genomad end-to-end --cleanup --splits 8 --threads {threads} {params.extra} {input.fa} {output.outdir} {params.db} > {log} 2>&1
        """

rule isescan_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/isescan")
    params:
        extra=config["params"]["isescan"]
    threads: config["threads"]["isescan"]
    conda: "../envs/isescan.yaml"
    log: "logs/annotation/{sample}_isescan.log"
    shell:
        """
        isescan.py --seqfile {input.fa} --output {output.outdir} --nthread {threads} {params.extra} > {log} 2>&1
        rm -f {wildcards.sample}_*.list
        """

rule antismash_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/antismash")
    params:
        db=config["databases"]["antismash"],
        extra=config["params"]["antismash"]
    threads: config["threads"]["antismash"]
    conda: "../envs/antismash.yaml"
    log: "logs/annotation/{sample}_antismash.log"
    shell:
        """
        mkdir -p {output.outdir}
        antismash {input.fa} --databases {params.db} --output-dir {output.outdir} \
            --genefinding-tool prodigal --cpus {threads} --logfile {log} {params.extra}
        """

rule bigscape_sample:
    input:
        ast_dir="results/09_ANNOTATION/{sample}/antismash"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/bigscape")
    params:
        pfam=config["databases"]["pfam"],
        extra=config["params"]["bigscape"]
    threads: config["threads"]["bigscape"]
    conda: "../envs/bigscape.yaml"
    log: "logs/annotation/{sample}_bigscape.log"
    shell:
        """
        mkdir -p {output.outdir}/gbk_pool
        find {input.ast_dir} -name "*.gbk" -exec cp {{}} {output.outdir}/gbk_pool/ \\;
        if [ "$(ls -A {output.outdir}/gbk_pool)" ]; then
            bigscape cluster -i {output.outdir}/gbk_pool -o {output.outdir} --pfam-path {params.pfam} -c {threads} {params.extra} > {log} 2>&1
        else
            echo "No GBK files found for BiG-SCAPE." > {log}
        fi
        """

rule mobsuite_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/mobsuite")
    params:
        extra=config["params"]["mobsuite"]
    threads: config["threads"]["mobsuite"]
    conda: "../envs/mobsuite.yaml"
    log: "logs/annotation/{sample}_mobsuite.log"
    shell:
        """
        rm -rf {output.outdir}
        mob_recon -i {input.fa} -o {output.outdir} -n {threads} {params.extra} > {log} 2>&1
        """

rule vibrant_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs.fa"
    output:
        outdir=directory("results/09_ANNOTATION/{sample}/vibrant")
    params:
        db=config["databases"]["vibrant_files"],
        extra=config["params"]["vibrant"]
    threads: config["threads"]["vibrant"]
    conda: "../envs/vibrant.yaml"
    log: "logs/annotation/{sample}_vibrant.log"
    shell:
        """
        rm -rf {output.outdir}
        mkdir -p {output.outdir}
        VIBRANT_run.py -i {input.fa} -folder {output.outdir} -t {threads} \
            -d {params.db} {params.extra} > {log} 2>&1
        """

rule vfdb_sample:
    input:
        fa="results/02_ASSEMBLY/{sample}/final.contigs_prokaryotic.fa"
    output:
        out="results/09_ANNOTATION/{sample}/vfdb/vfdb_results.tab"
    params:
        extra=config["params"]["vfdb"]
    threads: config["threads"]["vfdb"]
    conda: "../envs/abricate.yaml"
    log: "logs/annotation/{sample}_vfdb.log"
    shell:
        """
        mkdir -p $(dirname {output.out})
        abricate --db vfdb --threads {threads} {params.extra} {input.fa} > {output.out} 2> {log}
        """


# ==============================================================================
# TRACK 2 — Per-MAG annotation
# ==============================================================================

rule prodigal_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/prodigal")
    params:
        extra=config["params"]["prodigal"]
    threads: config["threads"]["prodigal"]
    conda: "../envs/pyrodigal.yaml"
    log: "logs/annotation/mags_prodigal.log"
    shell:
        """
        rm -rf {output.outdir}
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            mkdir -p {output.outdir}/$magname
            pyrodigal -i "$f" -a {output.outdir}/$magname/${{magname}}_proteins.faa \
                      -o {output.outdir}/$magname/${{magname}}_coords.gff \
                      -p single -f gff -j {threads} {params.extra} >> {log} 2>&1
        done
        """

rule eggnog_mags:
    input:
        prodigal_dir="results/09_ANNOTATION/mags/prodigal"
    output:
        outdir=directory("results/09_ANNOTATION/mags/eggnog")
    params:
        db=config["databases"]["eggnog"],
        extra=config["params"]["eggnog"]
    threads: config["threads"]["eggnog"]
    conda: "../envs/eggnog.yaml"
    log: "logs/annotation/mags_eggnog.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for d in {input.prodigal_dir}/*/; do
            magname=$(basename "$d")
            faa="$d/${{magname}}_proteins.faa"
            [ -e "$faa" ] || continue
            mkdir -p {output.outdir}/$magname
            emapper.py -m diamond -i "$faa" --data_dir {params.db} \
                       -o {output.outdir}/$magname/${{magname}}_annotations \
                       --cpu {threads} {params.extra} >> {log} 2>&1
        done
        """

rule abricate_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/abricate")
    params:
        extra=config["params"]["abricate"]
    threads: config["threads"]["abricate"]
    conda: "../envs/abricate.yaml"
    log: "logs/annotation/mags_abricate.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            mkdir -p {output.outdir}/$magname
            abricate --db ncbi --threads {threads} {params.extra} "$f" > {output.outdir}/$magname/ncbi_results.tab 2>> {log}
            abricate --db card --threads {threads} {params.extra} "$f" > {output.outdir}/$magname/card_results.tab 2>> {log}
        done
        """

rule amrfinder_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes",
        prodigal_dir="results/09_ANNOTATION/mags/prodigal"
    output:
        outdir=directory("results/09_ANNOTATION/mags/amrfinder")
    params:
        db=config["databases"]["amrfinderplus"],
        extra=config["params"]["amrfinderplus"]
    threads: config["threads"]["amrfinderplus"]
    conda: "../envs/amrfinder.yaml"
    log: "logs/annotation/mags_amrfinder.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            faa="{input.prodigal_dir}/$magname/${{magname}}_proteins.faa"
            gff="{input.prodigal_dir}/$magname/${{magname}}_coords.gff"
            [ -e "$faa" ] && [ -e "$gff" ] || continue
            mkdir -p {output.outdir}/$magname
            amrfinder -p "$faa" -n "$f" -g "$gff" \
                --database {params.db} --annotation_format prodigal \
                --plus --threads {threads} {params.extra} \
                -o {output.outdir}/$magname/amrfinder_results.tsv >> {log} 2>&1
        done
        """

rule minced_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/minced")
    params:
        extra=config["params"]["minced"]
    conda: "../envs/minced.yaml"
    log: "logs/annotation/mags_minced.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            mkdir -p {output.outdir}/$magname
            minced -minNR 2 {params.extra} "$f" {output.outdir}/$magname/${{magname}}.crisprs {output.outdir}/$magname/${{magname}}.gff >> {log} 2>&1
        done
        """

rule isescan_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/isescan")
    params:
        extra=config["params"]["isescan"]
    threads: config["threads"]["isescan"]
    conda: "../envs/isescan.yaml"
    log: "logs/annotation/mags_isescan.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            isescan.py --seqfile "$f" --output {output.outdir}/$magname --nthread {threads} {params.extra} >> {log} 2>&1
            parent=$(basename "$(dirname "$f")")
            rm -f "${{parent}}_$(basename "$f").list"
        done
        """

rule antismash_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/antismash")
    params:
        db=config["databases"]["antismash"],
        extra=config["params"]["antismash"]
    threads: config["threads"]["antismash"]
    conda: "../envs/antismash.yaml"
    log: "logs/annotation/mags_antismash.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            antismash "$f" --databases {params.db} --output-dir {output.outdir}/$magname \
                --genefinding-tool prodigal --cpus {threads} \
                --logfile {output.outdir}/$magname/antismash.log \
                {params.extra} >> {log} 2>&1
        done
        """

rule bigscape_mags:
    input:
        ast_dir="results/09_ANNOTATION/mags/antismash"
    output:
        outdir=directory("results/09_ANNOTATION/mags/bigscape")
    params:
        pfam=config["databases"]["pfam"],
        extra=config["params"]["bigscape"]
    threads: config["threads"]["bigscape"]
    conda: "../envs/bigscape.yaml"
    log: "logs/annotation/mags_bigscape.log"
    shell:
        """
        mkdir -p {output.outdir}/gbk_pool
        find {input.ast_dir} -name "*.gbk" -exec cp {{}} {output.outdir}/gbk_pool/ \\;
        if [ "$(ls -A {output.outdir}/gbk_pool)" ]; then
            bigscape cluster -i {output.outdir}/gbk_pool -o {output.outdir} --pfam-path {params.pfam} -c {threads} {params.extra} > {log} 2>&1
        else
            echo "No GBK files found for BiG-SCAPE." > {log}
        fi
        """

rule vfdb_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/vfdb")
    params:
        extra=config["params"]["vfdb"]
    threads: config["threads"]["vfdb"]
    conda: "../envs/abricate.yaml"
    log: "logs/annotation/mags_vfdb.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            abricate --db vfdb --threads {threads} {params.extra} "$f" > {output.outdir}/${{magname}}_vfdb_results.tab 2>> {log}
        done
        """

rule barrnap_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/barrnap")
    params:
        extra=config["params"]["barrnap"]
    threads: config["threads"]["barrnap"]
    conda: "../envs/barrnap.yaml"
    log: "logs/annotation/mags_barrnap.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            barrnap {params.extra} --threads {threads} --outseq {output.outdir}/${{magname}}_rrna.fa \
                "$f" > {output.outdir}/${{magname}}_rrna.gff 2>> {log}
        done
        """

rule trnascan_mags:
    input:
        mags="results/07_DEREP/drep_out/dereplicated_genomes"
    output:
        outdir=directory("results/09_ANNOTATION/mags/trnascan")
    params:
        extra=config["params"]["trnascan"]
    threads: config["threads"]["trnascan"]
    conda: "../envs/trnascan.yaml"
    log: "logs/annotation/mags_trnascan.log"
    shell:
        """
        mkdir -p {output.outdir}
        > {log}
        for f in {input.mags}/*.fa; do
            [ -e "$f" ] || continue
            magname=$(basename "$f".fa)
            tRNAscan-SE {params.extra} --thread {threads} \
                -o {output.outdir}/${{magname}}_trna.out -f {output.outdir}/${{magname}}_trna.struct \
                "$f" >> {log} 2>&1
        done
        """
