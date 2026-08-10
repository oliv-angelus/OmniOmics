import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

wildcard_constraints:
    domain="[^/]+"

# ── Phase 2, mode 3: de novo transcript assembly ──────────────────────────────
# Multi-assembler ensemble (rnaSPAdes + MEGAHIT + Trinity) deduplicated with
# MMseqs2 into a single "MAD" (multi-assembler-deduplicated) transcript set, per
# the environmental-metatranscriptome approach in PMC9983209 (Krinos et al.
# 2023, "eukrhythmic" pipeline -- see DOGMA). All three are short-read
# assemblers, so they run on short/hybrid samples only (SHORT_SAMPLES in the
# Snakefile); long-read-only metatranscriptome assembly has no validated tool
# as of 2026 (real WebSearch confirmed this is a genuine literature gap, not
# left unresolved by default -- see DOGMA) and is deliberately not
# implemented.
#
# Each assembler is an independently toggleable tool. The transcript_set step
# below reads config["active_tools"] to combine only the assemblers that ran, so
# it stays consistent with the client's --omit-from (which drops an inactive
# assembler's rule): disabling one assembler simply shrinks the ensemble instead
# of breaking the dedup step.
#
# ── domain_filter wiring ───────────────────────────────────────────────────
# Every rule below carries a {domain} wildcard, resolved against Snakefile's
# DOMAINS list: ["all"] when domain_filter is inactive (plain ribodetector-
# clean reads, same behavior as before this wiring existed), ["prokaryote"] or
# ["eukaryote"] when active with a single mode, or ["prokaryote", "eukaryote"]
# when mode is "both" -- in which case the *entire* downstream Phase 2 chain
# (assembly through every annotation extra) runs twice per sample, fully
# separately, per the user's explicit choice over the simpler
# alternative (domain_filter only affecting 02_SCREENING characterization).


def _short_reads_r1(wildcards):
    if wildcards.domain == "all":
        return f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R1_clean.fastq.gz"
    return f"results/02_SCREENING/{wildcards.sample}/{wildcards.sample}_R1_{wildcards.domain}.fastq.gz"


def _short_reads_r2(wildcards):
    if wildcards.domain == "all":
        return f"results/01_QC/{wildcards.sample}/{wildcards.sample}_R2_clean.fastq.gz"
    return f"results/02_SCREENING/{wildcards.sample}/{wildcards.sample}_R2_{wildcards.domain}.fastq.gz"


rule rnaspades:
    input:
        r1=_short_reads_r1,
        r2=_short_reads_r2
    output:
        transcripts="results/03_ASSEMBLY/{sample}/{domain}/rnaspades/transcripts.fasta",
        outdir=directory("results/03_ASSEMBLY/{sample}/{domain}/rnaspades")
    params:
        extra=config["params"].get("rnaspades", "")
    threads: config["threads"]["rnaspades"]
    conda: "../envs/rnaspades.yaml"
    log: "logs/assembly/{sample}_{domain}_rnaspades.log"
    shell:
        """
        rm -rf {output.outdir}
        rnaspades.py -1 {input.r1} -2 {input.r2} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """


rule megahit:
    input:
        r1=_short_reads_r1,
        r2=_short_reads_r2
    output:
        contigs="results/03_ASSEMBLY/{sample}/{domain}/megahit/final.contigs.fa",
        outdir=directory("results/03_ASSEMBLY/{sample}/{domain}/megahit")
    params:
        extra=config["params"].get("megahit", "")
    threads: config["threads"]["megahit"]
    conda: "../envs/megahit.yaml"
    log: "logs/assembly/{sample}_{domain}_megahit.log"
    shell:
        """
        rm -rf {output.outdir}
        megahit -1 {input.r1} -2 {input.r2} -o {output.outdir} -t {threads} {params.extra} > {log} 2>&1
        """


rule trinity:
    input:
        r1=_short_reads_r1,
        r2=_short_reads_r2
    output:
        fasta="results/03_ASSEMBLY/{sample}/{domain}/trinity/Trinity.fasta"
    params:
        # Trinity requires the --output path to contain the word "trinity" and
        # writes the final assembly to "<output>.Trinity.fasta" (a file next to
        # the work dir), which we then move to the declared output.
        outdir="results/03_ASSEMBLY/{sample}/{domain}/trinity_run",
        extra=config["params"].get("trinity", "")
    threads: config["threads"]["trinity"]
    conda: "../envs/trinity.yaml"
    log: "logs/assembly/{sample}_{domain}_trinity.log"
    shell:
        """
        mkdir -p $(dirname {output.fasta})
        rm -rf {params.outdir} {params.outdir}.Trinity.fasta
        Trinity --seqType fq --left {input.r1} --right {input.r2} \
            --CPU {threads} --output {params.outdir} {params.extra} > {log} 2>&1
        mv {params.outdir}.Trinity.fasta {output.fasta}
        """


def _active_assembler_transcripts(wildcards):
    """Transcript FASTAs of just the assemblers active for this run -- keyed on
    config["active_tools"] so it matches the client's --omit-from (an inactive
    assembler is both omitted from the DAG and excluded here), letting the
    ensemble shrink to 1 or 2 assemblers instead of breaking."""
    active = set(config.get("active_tools", []))
    outputs = {
        "rnaspades": f"results/03_ASSEMBLY/{wildcards.sample}/{wildcards.domain}/rnaspades/transcripts.fasta",
        "megahit":   f"results/03_ASSEMBLY/{wildcards.sample}/{wildcards.domain}/megahit/final.contigs.fa",
        "trinity":   f"results/03_ASSEMBLY/{wildcards.sample}/{wildcards.domain}/trinity/Trinity.fasta",
    }
    return [path for tool, path in outputs.items if tool in active]


rule transcript_set:
    input:
        _active_assembler_transcripts
    output:
        mad="results/03_ASSEMBLY/{sample}/{domain}/{sample}_transcripts_mad.fasta"
    params:
        # Real two-step MMseqs2 dedup per PMC9983209 (Krinos et al. 2023) -- # read directly from the paper's own "eukrhythmic" Snakemake source
        # (07-CAG.smk, 12-MAD.smk), not just the prose, since the prose alone
        # doesn't give exact flags. Step 1 collapses IDENTICAL contigs that
        # multiple assemblers independently recovered (100% identity); step 2
        # then collapses NEAR-identical contigs to account for sequencing
        # errors (98% identity). Both use --cov-mode 1 (coverage of the
        # shorter sequence) -c 0.98, matching eukrhythmic's exact invocation
        # (previously this rule used a single 0.98 pass with -c 0.9, missing
        # both the two-stage structure and the coverage mode/value).
        # eukrhythmic runs step 1 per "assembly group" then step 2 once
        # globally across every sample/group combined; DOGMA has no
        # co-assembly step (per-sample only, a deliberate earlier decision -- # see DOGMA), so both steps run per-sample here instead, matching
        # the paper's two-stage *structure* at DOGMA's actual granularity.
        step1_extra=config["params"].get("transcript_set_step1", "--min-seq-id 1.00 --cov-mode 1 -c 0.98"),
        step2_extra=config["params"].get("transcript_set", "--min-seq-id 0.98 --cov-mode 1 -c 0.98")
    threads: config["threads"]["transcript_set"]
    conda: "../envs/mmseqs2.yaml"
    log: "logs/assembly/{sample}_{domain}_transcript_set.log"
    shell:
        """
        tmp=$(mktemp -d)
        combined="$tmp/combined.fasta": > "$combined"
        n=0
        for f in {input}; do
            n=$((n+1))
            sed "s/^>/>asm${{n}}_/" "$f" >> "$combined"
        done
        mmseqs easy-linclust "$combined" "$tmp/step1" "$tmp/mm1" \
            --threads {threads} {params.step1_extra} > {log} 2>&1
        mmseqs easy-linclust "$tmp/step1_rep_seq.fasta" "$tmp/step2" "$tmp/mm2" \
            --threads {threads} {params.step2_extra} >> {log} 2>&1
        mv "$tmp/step2_rep_seq.fasta" {output.mad}
        rm -rf "$tmp"
        """
