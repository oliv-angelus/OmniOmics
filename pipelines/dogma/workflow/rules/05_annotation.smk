import pandas as pd
import os

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# ── Phase 2, step 3: functional annotation ────────────────────────────────────
# eggNOG-mapper is the default annotator (same tool/env/invocation pattern
# already used by MAGMA/SIGMA), reading TransDecoder's predicted proteins
# instead of Prodigal's (MAGMA) or Bakta's (SIGMA). CAZy and NCycDB are
# optional soil/sediment-relevant extras layered on top, per the CoMW
# (GigaScience, PMC6667343) literature decision -- see DOGMA.
#
# Every per-sample rule here carries the same {domain} wildcard 03_assembly.smk
# introduced (domain_filter wiring, see that file's header) -- "all" when
# domain_filter is inactive, or "prokaryote"/"eukaryote" otherwise, following
# the TransDecoder output up from 04_ORF_CALLING. The shared *_index rules
# (ncycdb/mcycdb/scycdb) build their DIAMOND index from the reference database
# itself, not from any sample's data, so they stay domain-independent.


rule eggnog_sample:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep"
    output:
        annot="results/05_ANNOTATION/{sample}/{domain}/eggnog/{sample}_annotations.emapper.annotations"
    params:
        db=config["databases"]["eggnog"],
        extra=config["params"]["eggnog"],
        out_prefix="results/05_ANNOTATION/{sample}/{domain}/eggnog/{sample}_annotations"
    threads: config["threads"]["eggnog"]
    conda: "../envs/eggnog.yaml"
    log: "logs/annotation/{sample}_{domain}_eggnog.log"
    shell:
        "emapper.py -m diamond -i {input.faa} --data_dir {params.db} -o {params.out_prefix} --cpu {threads} {params.extra} > {log} 2>&1"


# CAZy (carbohydrate-active enzymes) via run_dbcan/dbCAN3 -- optional extra,
# soil/sediment carbon-cycling relevance per CoMW (see DOGMA). Real CLI
# verified against dbcan=5.2.9's actual --help:
# `run_dbcan CAZyme_annotation --mode protein --input_raw_data <faa>
# --output_dir <dir> --db_dir <dir> --threads N` writes results/overview.tsv
# (consensus CAZy family calls across DIAMOND/HMM/dbCAN-sub) plus per-method
# TSVs into --output_dir. --mode protein is required since the input here is
# TransDecoder's.pep, not raw DNA (the prok/meta modes run gene calling
# themselves, which DOGMA already did via TransDecoder).
rule cazy_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep"
    output:
        overview="results/05_ANNOTATION/{sample}/{domain}/cazy/overview.tsv"
    params:
        db=config["databases"]["cazy"],
        outdir="results/05_ANNOTATION/{sample}/{domain}/cazy",
        extra=config["params"].get("cazy", "")
    threads: config["threads"]["cazy"]
    conda: "../envs/dbcan.yaml"
    log: "logs/annotation/{sample}_{domain}_cazy.log"
    shell:
        "run_dbcan CAZyme_annotation --mode protein --input_raw_data {input.faa} "
        "--output_dir {params.outdir} --db_dir {params.db} --threads {threads} {params.extra} > {log} 2>&1"


# NCycDB (nitrogen-cycling genes, Tu et al. 2019) -- optional extra, soil/
# sediment nitrogen-cycling relevance per CoMW (see DOGMA). NCycDB isn't a
# packaged tool, just a curated reference FASTA + ID-to-gene-family mapping
# table (github.com/qichao1984/NCyc); the authors' own NCycProfiler.PL scripts
# a plain `diamond blastp -k 1 -e 0.0001` search against it, then counts hits
# per gene family via id2gene.map -- verified (built the
# actual NCyc_95 diamond index and ran this exact search against real NCycDB
# sequences, confirmed the join logic against id2gene.map). NCyc_95 (95%
# identity-clustered, 84,759 seqs) is used over NCyc_100 (219,146 seqs) as the
# search database -- standard redundancy-reduction practice for a search
# reference, per the database's own README (both are offered as valid search
# options; NCycProfiler.PL's own example just happens to hardcode NCyc_100).
#
# The diamond index is built once (shared across samples) from the
# database's raw NCyc_95.faa rather than requiring diamond to be present
# wherever the database gets downloaded -- keeps database download plain
# file-fetching, no tool dependency at download time.
rule ncycdb_index:
    input:
        faa=lambda wc: os.path.join(config["databases"]["ncycdb"], "NCyc_95.faa")
    output:
        dmnd="results/05_ANNOTATION/_ncycdb/NCyc_95.dmnd"
    params:
        prefix="results/05_ANNOTATION/_ncycdb/NCyc_95"
    threads: config["threads"]["ncycdb"]
    conda: "../envs/diamond.yaml"
    log: "logs/annotation/ncycdb_index.log"
    shell:
        "diamond makedb --in {input.faa} --db {params.prefix} --threads {threads} > {log} 2>&1"


rule ncycdb_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        dmnd="results/05_ANNOTATION/_ncycdb/NCyc_95.dmnd",
        map=lambda wc: os.path.join(config["databases"]["ncycdb"], "id2gene.map")
    output:
        hits="results/05_ANNOTATION/{sample}/{domain}/ncycdb/{sample}_ncycdb_hits.tsv",
        annot="results/05_ANNOTATION/{sample}/{domain}/ncycdb/{sample}_ncycdb_annotations.tsv"
    params:
        extra=config["params"].get("ncycdb", "-k 1 -e 0.0001")
    threads: config["threads"]["ncycdb"]
    conda: "../envs/diamond.yaml"
    log: "logs/annotation/{sample}_{domain}_ncycdb.log"
    shell:
        """
        diamond blastp -q {input.faa} -d {input.dmnd} --threads {threads} {params.extra} \
            --outfmt 6 qseqid sseqid pident length evalue bitscore -o {output.hits} > {log} 2>&1
        awk 'BEGIN{{FS=OFS="\\t"}} FNR==NR{{map[$1]=$2; next}} {{gene=($2 in map ? map[$2]: "NA"); print $0, gene}}' \
            {input.map} {output.hits} > {output.annot}
        """


# MCycDB (methane-cycling genes, Qian et al. 2022) -- optional extra, same
# design/lab lineage as NCycDB/SCycDB (github.com/qichao1984/MCycDB), most
# relevant for anoxic/wetland sediments specifically. Same multi-part-zip
# situation as SCycDB (needs `7z` to extract; Info-Zip can't reassemble it),
# verified the same way: downloaded all 5 real parts,
# confirmed 7z extracts the exact expected byte count (380,449,265 bytes),
# confirmed the internal filename (MCycDB_2021.faa) and search params
# (`-k 1 -e 1e-4`, from the database's own MCycDB_FunctionProfiler.PL), and
# ran a real makedb+blastp+join end-to-end. NOTE: some hits legitimately join
# to "NA" -- the FASTA includes homolog sequences (kept to reduce false
# positives) that are deliberately *not* in id2gene.map; confirmed this is
# expected behavior (checked a real "NA" case against the map directly), not
# a join bug -- same behavior the original Perl profiler has (it silently
# drops these; this rule keeps the hit row and marks it "NA" instead, more
# transparent for downstream inspection).
rule mcycdb_index:
    input:
        faa=lambda wc: os.path.join(config["databases"]["mcycdb"], "MCycDB_2021.faa")
    output:
        dmnd="results/05_ANNOTATION/_mcycdb/MCycDB_2021.dmnd"
    params:
        prefix="results/05_ANNOTATION/_mcycdb/MCycDB_2021"
    threads: config["threads"]["mcycdb"]
    conda: "../envs/diamond.yaml"
    log: "logs/annotation/mcycdb_index.log"
    shell:
        "diamond makedb --in {input.faa} --db {params.prefix} --threads {threads} > {log} 2>&1"


rule mcycdb_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        dmnd="results/05_ANNOTATION/_mcycdb/MCycDB_2021.dmnd",
        map=lambda wc: os.path.join(config["databases"]["mcycdb"], "id2gene.map")
    output:
        hits="results/05_ANNOTATION/{sample}/{domain}/mcycdb/{sample}_mcycdb_hits.tsv",
        annot="results/05_ANNOTATION/{sample}/{domain}/mcycdb/{sample}_mcycdb_annotations.tsv"
    params:
        extra=config["params"].get("mcycdb", "-k 1 -e 0.0001")
    threads: config["threads"]["mcycdb"]
    conda: "../envs/diamond.yaml"
    log: "logs/annotation/{sample}_{domain}_mcycdb.log"
    shell:
        """
        diamond blastp -q {input.faa} -d {input.dmnd} --threads {threads} {params.extra} \
            --outfmt 6 qseqid sseqid pident length evalue bitscore -o {output.hits} > {log} 2>&1
        awk 'BEGIN{{FS=OFS="\\t"}} FNR==NR{{map[$1]=$2; next}} {{gene=($2 in map ? map[$2]: "NA"); print $0, gene}}' \
            {input.map} {output.hits} > {output.annot}
        """


# SCycDB (sulfur-cycling genes, Yu et al. 2021) -- optional extra, same
# curated-FASTA-searched-with-DIAMOND design and same lab lineage as NCycDB
# (github.com/qichao1984/SCycDB). Verified downloaded the
# actual multi-part zip (SCycDB_2020Mar.z01-z04 +.zip), confirmed Info-Zip's
# `zip -FF`/`-s 0` can't reassemble it correctly (corrupted output -- "invalid
# compressed data to inflate") but `7z x` extracts it cleanly (confirmed exact
# byte count, 364,058,792 bytes, matches the archive's own listed size) --
# hence the database download here needs p7zip (`7z`) installed. Confirmed the
# exact search params (`-k 1 -e 1e-4`) by reading the database's own
# SCycDB_FunctionProfiler.PL, same as NCycDB's script, and ran a real
# makedb+blastp+join end-to-end against real SCycDB sequences (self-hit test,
# correct gene-family join). id2gene.2020Mar.map has an extra 3rd column
# (source DB, e.g. "UniProt") versus NCycDB's 2-column map -- harmless, the
# join only reads columns 1-2.
rule scycdb_index:
    input:
        faa=lambda wc: os.path.join(config["databases"]["scycdb"], "SCycDB_2020Mar.faa")
    output:
        dmnd="results/05_ANNOTATION/_scycdb/SCycDB_2020Mar.dmnd"
    params:
        prefix="results/05_ANNOTATION/_scycdb/SCycDB_2020Mar"
    threads: config["threads"]["scycdb"]
    conda: "../envs/diamond.yaml"
    log: "logs/annotation/scycdb_index.log"
    shell:
        "diamond makedb --in {input.faa} --db {params.prefix} --threads {threads} > {log} 2>&1"


rule scycdb_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        dmnd="results/05_ANNOTATION/_scycdb/SCycDB_2020Mar.dmnd",
        map=lambda wc: os.path.join(config["databases"]["scycdb"], "id2gene.2020Mar.map")
    output:
        hits="results/05_ANNOTATION/{sample}/{domain}/scycdb/{sample}_scycdb_hits.tsv",
        annot="results/05_ANNOTATION/{sample}/{domain}/scycdb/{sample}_scycdb_annotations.tsv"
    params:
        extra=config["params"].get("scycdb", "-k 1 -e 0.0001")
    threads: config["threads"]["scycdb"]
    conda: "../envs/diamond.yaml"
    log: "logs/annotation/{sample}_{domain}_scycdb.log"
    shell:
        """
        diamond blastp -q {input.faa} -d {input.dmnd} --threads {threads} {params.extra} \
            --outfmt 6 qseqid sseqid pident length evalue bitscore -o {output.hits} > {log} 2>&1
        awk 'BEGIN{{FS=OFS="\\t"}} FNR==NR{{map[$1]=$2; next}} {{gene=($2 in map ? map[$2]: "NA"); print $0, gene}}' \
            {input.map} {output.hits} > {output.annot}
        """


# CANT-HYD (hydrocarbon-degradation marker genes, Khot et al. 2021) --
# optional extra, relevant for petroleum-contaminated soil/sediment sites.
# Unlike NCycDB/SCycDB/MCycDB, this is a curated set of 37 phylogeny-derived
# HMMs (github.com/dgittins/CANT-HYD-HydrocarbonBiodegradation), searched with
# HMMER's `hmmsearch`, not a DIAMOND FASTA reference -- no separate ID-to-gene
# map needed, each HMM's own NAME field *is* the gene call, and each HMM
# ships curated trusted/noise cutoffs (`--cut_tc`/`--cut_nc`) the authors
# recommend using instead of a manual E-value. Verified
# downloaded the actual concatenated CANT-HYD.hmm (real HMMER3/f file, 37
# NAME/TC/NC blocks confirmed), built a real hmmer env, and ran
# `hmmsearch --tblout... --cut_tc CANT-HYD.hmm <query>` end-to-end (all 37
# models processed correctly, confirmed by counting "Query model(s):" blocks
# in the output -- a single `tail` initially looked like only 1 model ran,
# which would have been a real bug if true, so this was checked).
rule canthyd_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep"
    output:
        tblout="results/05_ANNOTATION/{sample}/{domain}/canthyd/{sample}_canthyd_hmmsearch.tblout"
    params:
        hmm=lambda wc: os.path.join(config["databases"]["canthyd"], "CANT-HYD.hmm"),
        extra=config["params"].get("canthyd", "--cut_tc")
    threads: config["threads"]["canthyd"]
    conda: "../envs/hmmer.yaml"
    log: "logs/annotation/{sample}_{domain}_canthyd.log"
    shell:
        "hmmsearch --tblout {output.tblout} --cpu {threads} {params.extra} {params.hmm} {input.faa} > {log} 2>&1"


# FeGenie (iron-cycling genes, Garber et al. 2020) -- optional extra, iron
# is a major redox player in anoxic soil/sediment biogeochemistry alongside
# C/N/S. Unlike every other extra here, FeGenie is a fully self-contained
# bioconda package (`fegenie=1.2`) that ships its own curated HMM database
# inside the conda env itself (confirmed by installing it and
# finding `share/fegenie-1.2/hmms/...` in the env tree) -- so there is no
# separate `databases.fegenie` manifest entry or download option, same as
# how some MAGMA tools need no database config at all.
#
# FeGenie's CLI wants a *directory* of "bins" (`-bin_dir`/`-bin_ext`), not a
# single input file -- same "tool wants its own directory layout" situation
# as Trinity/TransDecoder, solved the same way: a per-sample scratch dir
# holding just this sample's protein file, cleaned up after. `--orfs` tells
# it the input is already-predicted proteins (not raw contigs to call genes
# on itself); `--meta` marks the input as metagenome/metatranscriptome-
# derived; `--nohup` lets it silently overwrite a pre-existing output dir
# instead of prompting interactively (which would hang a pipeline run).
# Verified installed the actual bioconda package, ran
# `FeGenie.py -bin_dir <dir> -bin_ext faa --orfs --meta -out <dir> -t N
# --nohup` end-to-end against a synthetic protein -- completed ("Pipeline
# finished without crashing!!!"), produced the real expected output files
# (FeGenie-geneSummary.csv, FeGenie-geneSummary-clusters.csv,
# FeGenie-heatmap-data.csv).
rule fegenie_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep"
    output:
        summary="results/05_ANNOTATION/{sample}/{domain}/fegenie/FeGenie-geneSummary.csv"
    params:
        bindir="results/05_ANNOTATION/{sample}/{domain}/fegenie_bindir",
        outdir="results/05_ANNOTATION/{sample}/{domain}/fegenie",
        extra=config["params"].get("fegenie", "")
    threads: config["threads"]["fegenie"]
    conda: "../envs/fegenie.yaml"
    log: "logs/annotation/{sample}_{domain}_fegenie.log"
    shell:
        """
        rm -rf {params.bindir} {params.outdir}
        mkdir -p {params.bindir}
        ln -sf "$(readlink -f {input.faa})" "{params.bindir}/{wildcards.sample}.faa"
        FeGenie.py -bin_dir {params.bindir} -bin_ext faa --orfs --meta \
            -out {params.outdir} -t {threads} --nohup {params.extra} > {log} 2>&1
        rm -rf {params.bindir}
        """
