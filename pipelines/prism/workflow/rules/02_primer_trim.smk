import re

_COMPLEMENT = str.maketrans("ACGTURYSWKMBDHVNacgturyswkmbdhvn", "TGCAAYRSWMKVHDBNtgcaayrswmkvhdbn")


def _revcomp(seq: str) -> str:
    return seq.translate(_COMPLEMENT)[::-1]


def _cutadapt_primers(wildcards):
    """Pulls -g/-G/-e straight out of the manifest's flag-string param (same
    string every other tool's `extra` param uses) instead of adding a second
    config path, since cutadapt's own real CLI flags already are -g/-G/-e -- no wrapper-script indirection needed here, unlike dada2_pacbio/emu_ont's
    non-CLI --gene flag."""
    extra = config["params"]["cutadapt"]
    err = re.search(r"-e\s+(\S+)", extra)
    err = err.group(1) if err else "0.1"

    # A -g/-G typed on the Tools tab is an explicit override and always wins;
    # otherwise the run-wide amplicon preset supplies the primers (see
    # config_engine.py's amplicon_preset block for why that preset exists).
    fwd_m = re.search(r"-g\s+(\S+)", extra)
    rev_m = re.search(r"-G\s+(\S+)", extra)
    if fwd_m or rev_m:
        pairs = [(fwd_m.group(1) if fwd_m else "AGRGTTYGATYMTGGCTCAG",
                  rev_m.group(1) if rev_m else "AAGTCGTAACAAGGTARCY")]
    else:
        preset = config.get("amplicon_preset", {}) or {}
        fwds = preset.get("fwd_primers") or []
        revs = preset.get("rev_primers") or []
        if not fwds or not revs:
            raise ValueError(
                "No primers available: the chosen amplicon preset "
                f"('{preset.get('id', '?')}') carries none, and no -g/-G was set on "
                "the Tools tab. Pick a preset that includes primers, or type your "
                "own -g/-G in cutadapt's parameters."
            )
        # ONT's own microbiome kit (SQK-MAB114.24) is a real PRIMER MIX, not a
        # single pair -- it pools a universal pair with taxon-specific ones
        # (Borrelia/Chlamydia for 16S; Fusarium/Malassezia/Pythium for ITS),
        # confirmed from ONT's own primer PDF. cutadapt accepts repeated -g,
        # so every forward is paired with every reverse and the read is kept
        # if ANY combination matches -- which is exactly how a mixed-primer
        # PCR actually behaves.
        pairs = [(f, r) for f in fwds for r in revs]

    # Full-length long reads carry both primers on the same read (unlike
    # paired-end short reads) -- a linked adapter (fwd...revcomp(rev)) trims
    # both ends and orients the read in one pass, matching the real HiFi-16S-
    # workflow/EasyAmplicon2 convention for PacBio/Nanopore full-length
    # amplicon reads.
    linked = " ".join(f"-g {f}...{_revcomp(r)}" for f, r in pairs)
    return f"{linked} -e {err}"


rule cutadapt_trim:
    input:
        long="results/01_QC/{sample}/{sample}_filtered.fastq.gz"
    output:
        long="results/02_PRIMER_TRIM/{sample}/{sample}_trimmed.fastq.gz",
        report="results/02_PRIMER_TRIM/{sample}/{sample}_cutadapt.json"
    params:
        linked=_cutadapt_primers
    conda: "../envs/cutadapt.yaml"
    threads: config["threads"]["cutadapt"]
    log: "logs/cutadapt/{sample}.log"
    shell:
        "cutadapt {params.linked} --discard-untrimmed --cores {threads} "
        "--json {output.report} -o {output.long} {input.long} > {log} 2>&1"
