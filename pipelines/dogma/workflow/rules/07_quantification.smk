import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# ── Phase 2, step 5: quantification ─────────────────────────────────────────
# Salmon, quantifying each sample directly against that sample's own MAD
# transcript set -- no shared/merged reference across samples, matching
# DOGMA's per-sample-only assembly design (no co-assembly, an earlier
# decision -- see DOGMA). This is exactly eukrhythmic/PMC9983209's own
# approach (Krinos et al. 2023, verified by reading the paper
# directly): "We used the Salmon mapping tool to both quantify
# the abundance of each contig with respect to the raw reads, and to assess
# what proportion of the raw reads were represented in the assembled
# contigs." No featureCounts here -- researched real precedent (eukrhythmic,
# CoMW, MT-Enviro) before deciding, found none of them actually pair Salmon
# with ORF/gene-level counting on a de novo metatranscriptome assembly, and
# TransDecoder's .gff3 isn't directly featureCounts-compatible anyway (real
# incompatibility), so quantification is Salmon-only. featureCounts
# (ORF-level counts joined to TransDecoder coordinates) remains a candidate
# refinement rather than a rejected option.
#
# **Scope note, worth remembering**: because there's no shared reference
# across samples, `quant.sf` is a per-sample table (transcript x {TPM,
# NumReads} within that one sample's own MAD set) -- transcript IDs are not
# comparable across samples without further cross-sample clustering/
# orthology work (out of scope, not decided). This is *not* a cross-sample
# count matrix the way single-organism RNA-seq pipelines produce one; it's
# the same per-sample scope eukrhythmic itself uses.
#
# Real CLI verified by installing salmon=2.3.4 (current bioconda,
# a Rust rewrite -- confirmed real CLI differences from the older C++ 1.x
# series before writing this rule unchanged): `--validateMappings`
# is now a deprecated no-op (selective alignment -- its modern equivalent --
# is already the default mapping mode), so it's deliberately omitted here
# rather than cargo-culted in from older salmon docs/precedent. Ran a real
# index+quant end-to-end on a synthetic 2-transcript MAD set with reads
# generated from only one of them: 100% of reads mapped, and TPM/NumReads
# landed exactly on the correct transcript (the untouched transcript got
# TPM=0), confirming both the index/quant flags and the quant.sf column
# format (`Name, Length, EffectiveLength, TPM, NumReads`).
#
# Reuses the domain-aware read-source functions (`_short_reads_r1`/
# `_short_reads_r2`) already defined in 03_assembly.smk -- same reads that
# fed the assembler feed quantification back against that assembly.


rule salmon_index:
    input:
        mad="results/03_ASSEMBLY/{sample}/{domain}/{sample}_transcripts_mad.fasta"
    output:
        idx_dir=directory("results/03_ASSEMBLY/{sample}/{domain}/salmon_index")
    params:
        extra=config["params"].get("salmon_index", "-k 31")
    threads: config["threads"]["salmon"]
    conda: "../envs/salmon.yaml"
    log: "logs/quantification/{sample}_{domain}_salmon_index.log"
    shell:
        "salmon index -t {input.mad} -i {output.idx_dir} -p {threads} {params.extra} > {log} 2>&1"


rule salmon_quant:
    input:
        idx_dir="results/03_ASSEMBLY/{sample}/{domain}/salmon_index",
        r1=_short_reads_r1,
        r2=_short_reads_r2
    output:
        quant="results/06_QUANTIFICATION/{sample}/{domain}/{sample}_quant/quant.sf"
    params:
        outdir="results/06_QUANTIFICATION/{sample}/{domain}/{sample}_quant",
        extra=config["params"].get("salmon", "")
    threads: config["threads"]["salmon"]
    conda: "../envs/salmon.yaml"
    log: "logs/quantification/{sample}_{domain}_salmon_quant.log"
    shell:
        "salmon quant -i {input.idx_dir} -l A -1 {input.r1} -2 {input.r2} "
        "-p {threads} -o {params.outdir} {params.extra} > {log} 2>&1"
