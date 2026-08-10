import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# ── Phase 2, step 2: ORF calling (TransDecoder) ───────────────────────────────
# Identifies candidate coding regions on the MAD (multi-assembler-deduplicated)
# transcript set from 03_ASSEMBLY, per the environmental-metatranscriptome
# approach in PMC9983209 (see DOGMA). Only applies where a MAD set exists,
# i.e. short/hybrid samples (SHORT_SAMPLES in the Snakefile) -- same scope as
# the assembly step itself.
#
# TransDecoder.LongOrfs/.Predict write their outputs into the current working
# directory, named off the input file's basename -- running that directly in
# the shared pipeline root would collide across samples running in parallel.
# So each sample gets its own scratch work dir (mirroring how the trinity rule
# already handles the same "tool writes next to its input" problem), and the
# real outputs are moved out to the declared per-sample paths afterward.


rule transdecoder:
    input:
        mad="results/03_ASSEMBLY/{sample}/{domain}/{sample}_transcripts_mad.fasta"
    output:
        pep="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        cds="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.cds",
        gff3="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.gff3",
        bed="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.bed"
    params:
        workdir="results/04_ORF_CALLING/{sample}/{domain}/transdecoder_work",
        extra=config["params"].get("transdecoder", "")
    threads: 1  # TransDecoder.LongOrfs/.Predict have no multithreading option
    conda: "../envs/transdecoder.yaml"
    log: "logs/orf_calling/{sample}_{domain}_transdecoder.log"
    shell:
        """
        rm -rf {params.workdir}
        mkdir -p {params.workdir}
        ln -sf "$(readlink -f {input.mad})" "{params.workdir}/transcripts.fasta"
        logfile="$(readlink -f {log})"
        (cd {params.workdir} && \
            TransDecoder.LongOrfs -t transcripts.fasta > "$logfile" 2>&1 && \
            TransDecoder.Predict -t transcripts.fasta {params.extra} >> "$logfile" 2>&1)
        mv {params.workdir}/transcripts.fasta.transdecoder.pep {output.pep}
        mv {params.workdir}/transcripts.fasta.transdecoder.cds {output.cds}
        mv {params.workdir}/transcripts.fasta.transdecoder.gff3 {output.gff3}
        mv {params.workdir}/transcripts.fasta.transdecoder.bed {output.bed}
        rm -rf {params.workdir}
        """
