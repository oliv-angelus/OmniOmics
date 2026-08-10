import re

# Real, deliberate scope limit (see the picrust2 tool's own manifest
# description): only runs for the PacBio/DADA2 path with --gene 16S.
# PICRUSt2's own bundled reference tree is 16S/bacteria-archaea-specific
# (Douglas et al. 2020) -- there's no equivalent for ITS/18S/23S/28S, and
# the Nanopore/Emu path produces no per-sample consensus sequence at all
# (reference-only EM classification) for PICRUSt2 to phylogenetically place
# in the first place. Both real constraints, not a wiring gap.

rule picrust2:
    input:
        seqs="results/04_DENOISE/dada2/prism_asv_sequences.fasta",
        counts="results/04_DENOISE/dada2/prism_asv_counts.tsv"
    output:
        ko="results/06_FUNCTIONAL/KO_metagenome_out/pred_metagenome_unstrat.tsv.gz",
        ec="results/06_FUNCTIONAL/EC_metagenome_out/pred_metagenome_unstrat.tsv.gz",
        pathways="results/06_FUNCTIONAL/pathways_out/path_abun_unstrat.tsv.gz"
    params:
        gene=_gene("dada2_pacbio"),
        max_nsti=_flag_value(config["params"].get("picrust2", ""), "--max_nsti", "2.0"),
        stratified_flag=lambda wc: "--stratified" if "--stratified" in config["params"].get("picrust2", "") else ""
    conda: "../envs/picrust2.yaml"
    # .get with a default, not a plain [] lookup: Snakemake evaluates
    # `threads:` at DAG-build time even when picrust2 is disabled or absent
    # from a run's config (any config.yaml generated before picrust2 was
    # added to the manifest, or any run where it isn't enabled), so
    # config["threads"]["picrust2"] would KeyError the whole DAG build even
    # for runs that never reach this rule -- the same class of gotcha as
    # Kaiju's fmi glob and _resolve_ref_path.
    threads: config["threads"].get("picrust2", 1)
    log: "logs/functional/picrust2.log"
    shell:
        """
        if [ "{PLATFORM}" == "pacbio_hifi" ] && [ "{params.gene}" == "16S" ]; then
            # Real, gotcha: PICRUSt2's
            # bioconda package ships with NO reference data at all (the
            # actual conda package is ~500KB) -- it relies on its own
            # post-link.sh script to `wget` a ~330MB GitHub release tarball
            # and move its default_files/ into place during `conda install`.
            # That download can silently fail/timeout (confirmed hitting
            # this directly: a plain `wget` of the same URL took >2 minutes
            # and needed resuming), leaving `picrust2_pipeline.py` to fail
            # deep inside place_seqs.py with a confusing "No FASTA file
            # found" error instead of a clear one. Checked up front here
            # instead, with a message naming the actual fix.
            PICRUST2_REF=$(python3 -c "import site; print(site.getsitepackages[0])")/picrust2/default_files/bacteria/bac_ref/bac_ref.tre
            if [ ! -f "$PICRUST2_REF" ]; then
                echo "PICRUSt2's reference data is missing (expected at $PICRUST2_REF)." > {log}
                echo "This is a known bioconda packaging gap: 'conda install picrust2' downloads it via its own post-link.sh (~330MB from GitHub), which can silently fail/timeout on a slow connection." >> {log}
                echo "Fix: re-run the picrust2 conda env install, or download+extract https://github.com/picrust/picrust2/archive/v2.6.2.tar.gz and move its picrust2/default_files/ into the env's site-packages/picrust2/ directory by hand." >> {log}
                exit 1
            fi
            rm -rf results/06_FUNCTIONAL
            picrust2_pipeline.py -s {input.seqs} -i {input.counts} -o results/06_FUNCTIONAL \
                -p {threads} --max_nsti {params.max_nsti} {params.stratified_flag} > {log} 2>&1
        else
            mkdir -p $(dirname {output.ko}) $(dirname {output.ec}) $(dirname {output.pathways})
            touch {output.ko} {output.ec} {output.pathways}
            echo "picrust2: skipped -- needs platform=pacbio_hifi and gene=16S (got platform={PLATFORM}, gene={params.gene})" > {log}
        fi
        """
