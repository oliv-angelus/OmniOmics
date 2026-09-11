# Real caveat this whole rule exists to respect (not a formality -- see the
# vsearch_chimera tool's manifest description + Hakimzadeh et al. 2025,
# Scientific References.md): long-read chimera detectors have measured
# false-positive rates as high as 55% at default settings.
#
# **Rule ordering ** after real testing found the original
# design (exact dereplication -> uchime3_denovo) detected ZERO chimeras,
# including one deliberately planted for the test -- not a false-positive
# problem, the opposite failure mode. Root cause, confirmed empirically:
# raw noisy long reads essentially never exact-duplicate (every read has its
# own independent error pattern), so every "dereplicated" sequence has
# abundance=1 and uchime3_denovo's abundance-skew parent/child logic has
# nothing to work with. Fixed by clustering at 95% identity first (real ONT
# reads of the same species run ~98% pairwise identity at a realistic ~1%
# per-base error rate -- well above 95%, so same-species reads still merge
# into real abundance-weighted clusters -- while real between-species 16S
# divergence, tested against 3 genuinely different real organisms, stayed
# nowhere near close enough to 95% to cross-contaminate a cluster) --
# clusters now have real abundance for the chimera algorithm to reason
# about. Also switched from `--uchime3_denovo` to classic `--uchime_denovo`:
# re-tested both against the same real clustered data, uchime3_denovo still
# found 0 chimeras (even with real abundance now available) while classic
# uchime_denovo correctly and precisely flagged just the one planted chimera
# at default settings, no false positives -- matches Hakimzadeh et al.
# 2025's own finding that uchime_denovo was the most precise of the
# algorithms they benchmarked, not just a theoretical citation this time.
#
# recover_nonchimeric_reads.py maps the chimera verdict on cluster
# centroids back onto every original member read via vsearch's own --uc
# cluster mapping (works unchanged with --cluster_size's.uc output, same
# H/S/C record shape --fastx_uniques produced before) -- see that script's
# own docstring for the full reasoning.
#
# Long-read-only rules, deliberately: the short-read (Illumina) path added
# 2026-09-11 has NO equivalent step here -- chimera removal happens inside
# dada2_illumina.R via DADA2's own removeBimeraDenovo() instead (see
# 04_denoise_classify.smk). Short Illumina reads exact-dereplicate reliably
# (unlike raw noisy long reads, the whole reason this file's clustering
# workaround exists), which is exactly the abundance signal
# removeBimeraDenovo's own parent/child logic needs -- no external VSEARCH
# step or clustering workaround needed for that read type.

rule vsearch_cluster:
    input:
        long="results/02_PRIMER_TRIM/{sample}/{sample}_trimmed.fastq.gz"
    output:
        fasta="results/03_CHIMERA/{sample}/{sample}_clustered.fasta",
        uc="results/03_CHIMERA/{sample}/{sample}_clustered.uc"
    params:
        id=lambda wc: config["params"]["vsearch_chimera"].split("--id")[-1].strip().split()[0]
            if "--id" in config["params"]["vsearch_chimera"] else "0.95"
    conda: "../envs/vsearch.yaml"
    threads: config["threads"]["vsearch_chimera"]
    log: "logs/chimera/{sample}_cluster.log"
    shell:
        "vsearch --cluster_size {input.long} --id {params.id} --sizeout "
        "--centroids {output.fasta} --uc {output.uc} --threads {threads} 2> {log}"

rule vsearch_chimera:
    input:
        fasta="results/03_CHIMERA/{sample}/{sample}_clustered.fasta",
        uc="results/03_CHIMERA/{sample}/{sample}_clustered.uc",
        original="results/02_PRIMER_TRIM/{sample}/{sample}_trimmed.fastq.gz"
    output:
        chimeras="results/03_CHIMERA/{sample}/{sample}_chimeras.fasta",
        nonchimeric="results/03_CHIMERA/{sample}/{sample}_nonchimeric.fastq.gz"
    params:
        abskew=lambda wc: config["params"]["vsearch_chimera"].split("--abskew")[-1].strip().split()[0]
            if "--abskew" in config["params"]["vsearch_chimera"] else "2.0"
    conda: "../envs/vsearch.yaml"
    threads: config["threads"]["vsearch_chimera"]
    log: "logs/chimera/{sample}_uchime.log"
    shell:
        """
        vsearch --uchime_denovo {input.fasta} --abskew {params.abskew} \
            --chimeras {output.chimeras} \
            --nonchimeras results/03_CHIMERA/{wildcards.sample}/{wildcards.sample}_nonchimeric_centroids.fasta \
            2> {log}
        python3 {workflow.basedir}/workflow/scripts/recover_nonchimeric_reads.py \
            --uc {input.uc} \
            --nonchimeras results/03_CHIMERA/{wildcards.sample}/{wildcards.sample}_nonchimeric_centroids.fasta \
            --original {input.original} \
            --out {output.nonchimeric} >> {log} 2>&1
        """
