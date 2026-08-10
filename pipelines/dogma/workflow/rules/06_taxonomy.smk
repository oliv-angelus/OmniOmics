import pandas as pd
import os

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")

# ── Phase 2, step 4: taxonomic assignment ──────────────────────────────────────
# EUKulele (Krinos & Alexander, same AlexanderLabWHOI group behind PMC9983209 /
# eukrhythmic, whose assembly-dedup design DOGMA already follows -- see
# DOGMA) classifies TransDecoder's predicted proteins against a marine
# microbial eukaryote reference, for the eukaryotic path. CAT/BAT (below)
# covers the prokaryotic path -- Kraken2/Kaiju already screen raw reads
# pre-assembly, but this is a separate, later stage: re-classifying the
# assembled, ORF-called transcripts themselves against a prokaryote-focused
# protein reference (GTDB or NCBI nr).
#
# Real CLI/behavior verified by installing eukulele=2.1.2 # and reading its actual source (not just --help, which hangs for a long time
# on this machine for reasons not investigated -- the argparse definitions in
# EUKulele_main.py and the database-management logic in manage_steps.py /
# download_database.py are authoritative and were read directly):
# - `-m mets` (metatranscriptome mode, required), `-x proteins --p_ext.pep`
# (protein-only input, matching TransDecoder's .pep extension directly --
# no rename needed, just point --p_ext at it).
# - `-s <dir>` wants a *directory* of protein files, not a single file --
# same "tool wants its own directory" shape as Trinity/TransDecoder/
# FeGenie, solved the same way (per-sample scratch dir with a symlink).
# - Sample name is derived by stripping the extension from the filename
# Snakemake dir, so naming the symlink "{sample}.pep" makes EUKulele's
# own sample name exactly match DOGMA's -- confirmed by reading
# `getSamples` in manage_steps.py.
# - Output: `{out_dir}/taxonomy_estimation/{sample}-estimated-taxonomy.out`
# (confirmed in manage_steps.py from docs -- the hosted docs
# site didn't have this level of detail).
# - `--no_busco` (default here): BUSCO completeness scoring is bundled but
# needs its own separate lineage-dataset download for a feature orthogonal
# to basic taxonomy assignment; left off by default, available via the
# `eukulele` params string if a user wants it later.
# - Default database `marmmetsp` (MMETSP+MarRef combined) matches the
# literature decision already on record (see DOGMA, # research: "EUKulele (vs MMETSP/MarRef)").
#
# Database handling is deliberately different from every other DOGMA
# database: EUKulele bundles its own downloader (wget, confirmed present in
# its conda env) and builds the DIAMOND index itself (`EUKulele download`),
# reading source URLs from its own maintained `reference_url.yaml` (Dropbox
# links that rotate with EUKulele's own releases) -- replicating that
# multi-step raw-download + taxonomy-table-build + index-build in the app's
# generic downloader (url/extract/post_cmd only) would be fragile and
# duplicate logic EUKulele already tests and maintains itself. So there's no
# `databases.eukulele` download_options entry -- the database directory
# starts empty and `eukulele_setup` below populates it on first pipeline run.
# Confirmed this is safe in this app specifically: neither the
# Launch screen's start-gating nor `generate_config`'s database-path
# pass-through validate that a configured database path already exists, so a
# not-yet-populated `db_eukulele` path doesn't block a run.
EUKULELE_DB = config.get("databases", {}).get("eukulele", "")
EUKULELE_DATABASE_NAME = config.get("params", {}).get("eukulele_database", "marmmetsp")


rule eukulele_setup:
    output:
        tax_table=os.path.join(EUKULELE_DB, EUKULELE_DATABASE_NAME, "tax-table.txt")
    params:
        refdir=EUKULELE_DB,
        database=EUKULELE_DATABASE_NAME,
        outdir="results/05_ANNOTATION/_eukulele_setup"
    threads: config["threads"]["eukulele"]
    conda: "../envs/eukulele.yaml"
    log: "logs/annotation/eukulele_setup.log"
    shell:
        "EUKulele download -d {params.database} --reference_dir {params.refdir} "
        "--alignment_choice diamond -o {params.outdir} --CPUs {threads} > {log} 2>&1"


rule eukulele_annotate:
    input:
        faa="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        tax_table=os.path.join(EUKULELE_DB, EUKULELE_DATABASE_NAME, "tax-table.txt")
    output:
        tax="results/05_ANNOTATION/{sample}/{domain}/eukulele/taxonomy_estimation/{sample}-estimated-taxonomy.out"
    params:
        sampledir="results/05_ANNOTATION/{sample}/{domain}/eukulele_sampledir",
        outdir="results/05_ANNOTATION/{sample}/{domain}/eukulele",
        refdir=EUKULELE_DB,
        database=EUKULELE_DATABASE_NAME,
        extra=config["params"].get("eukulele", "--no_busco")
    threads: config["threads"]["eukulele"]
    conda: "../envs/eukulele.yaml"
    log: "logs/annotation/{sample}_{domain}_eukulele.log"
    shell:
        """
        rm -rf {params.sampledir} {params.outdir}
        mkdir -p {params.sampledir}
        ln -sf "$(readlink -f {input.faa})" "{params.sampledir}/{wildcards.sample}.pep"
        EUKulele -m mets -s {params.sampledir} --reference_dir {params.refdir} \
            -d {params.database} -o {params.outdir} --p_ext.pep -x proteins \
            --CPUs {threads} {params.extra} > {log} 2>&1
        rm -rf {params.sampledir}
        """


# CAT/BAT (CAT_pack, MGXlab -- successor to the original dutilh-lab/CAT) --
# prokaryotic path of taxonomic assignment. Classifies assembled contigs by
# DIAMOND-searching their translated ORFs against a reference and taking an
# LCA vote across ORFs -- the same "search translated proteins, LCA to a
# taxon" shape EUKulele uses for eukaryotes, just prokaryote-focused (GTDB or
# NCBI nr). No parallel step exists in eukrhythmic/PMC9983209 to follow here
# (that pipeline is eukaryote-only throughout, confirmed by real research
# before choosing a tool) -- this is DOGMA's own addition, not inherited.
#
# Real CLI/behavior verified by installing cat=6.0.1 and reading
# its actual source (contigs.py, prepare.py, download.py, shared.py):
# - `contigs -c <nt fasta> -p <protein fasta> -d <db dir> -t <tax dir>
# -o <prefix>` skips CAT's own Prodigal gene-calling when `-p` is given,
# reusing TransDecoder's ORFs directly.
# - **Real header-format incompatibility found and fixed
# away:** CAT_pack derives each ORF's parent contig by
# `ORF_id.rsplit("_", 1)[0]` (confirmed in `shared.py`'s `import_ORFs`)
# -- i.e. it expects `{contig}_{ORFnumber}`. TransDecoder instead names
# ORFs `{contig}.p{N}` (a period + "p", not a trailing underscore+digit),
# which `rsplit("_", 1)` would parse *wrong*, silently corrupting the
# contig-to-ORF mapping. Fixed with a header-only `sed` pass
# (`{contig}.p{N}` -> `{contig}_{N}`) before handing proteins to CAT_pack.
# Verified with a tiny synthetic DIAMOND+taxdump database and
# matching synthetic contigs/proteins: without the fix this would
# misattribute ORFs; with it, `CAT_pack contigs` correctly classified
# 2/2 synthetic contigs against their planted taxids end-to-end.
# - Real output filename confirmed from source (`contigs.py`):
# `{out_prefix}.contig2classification.txt` (not the `.CAT.` infix an
# initial docs skim suggested -- checked).
# - `CAT_pack contigs -o <prefix>` does **not** create the parent
# directory for its own output prefix (`mkdir -p` needed first --
# caught by the same synthetic test above, which failed until added).
#
# Database handling follows the same pattern as `eukulele_setup` above, for
# the same reason: `CAT_pack download --db (nr|GTDB)` only fetches raw
# files and *prints* the `CAT_pack prepare` command needed to actually build
# the DIAMOND index + taxonomy files -- doesn't run it. So `cat_setup`
# chains both real subcommands in one rule, bridging them with the same
# glob patterns CAT_pack's own suggested-command message uses internally
# (`*nr.gz`, `*names.dmp`, etc. for nr; fixed names for GTDB). Also pins
# `--common_prefix dogma` explicitly -- confirmed from source
# (`shared.py`) that `prepare`'s default common_prefix is
# `"{today's date}_CAT_pack"`, which would make output filenames change
# every day and break Snakemake's ability to track completion.
#
# **Database size -- deliberately not size-optimized, both real tiers
# offered as user-selectable alternatives instead of picking one "small"
# default** (explicit user decision, this app targets
# workstations/HPC as much as this laptop, so don't over-index on this
# machine's constraints). Verified real sizes via HTTP HEAD before
# committing to this framing: GTDB's representative-genomes
# protein tarball (`gtdb_proteins_aa_reps.tar.gz`) is ~123 GiB compressed;
# NCBI nr.gz is ~186 GiB compressed (plus taxdump/accession2taxid on top of
# both). There is no smaller official tier for either -- CAT_pack only
# supports exactly these two `--db` choices. Selected via `cat_database`
# param (`"GTDB"` default or `"nr"`), same plain-top-level-params-key
# pattern as `eukulele_database` (not a Tools-tab UI dropdown yet -- would
# need a Flutter-side change not made in earlier work; switch via
# config.yaml today, see DOGMA).
CAT_DB = config.get("databases", {}).get("cat", "")
CAT_DATABASE_CHOICE = config.get("params", {}).get("cat_database", "GTDB")


rule cat_setup:
    output:
        dmnd=os.path.join(CAT_DB, "db", "dogma.dmnd")
    params:
        downloaddir=os.path.join(CAT_DB, "raw"),
        dbdir=CAT_DB,
        dbchoice=CAT_DATABASE_CHOICE
    threads: config["threads"]["cat"]
    conda: "../envs/cat.yaml"
    log: "logs/annotation/cat_setup.log"
    shell:
        """
        mkdir -p {params.downloaddir}
        CAT_pack download --db {params.dbchoice} -o {params.downloaddir} --no_log > {log} 2>&1
        if [ "{params.dbchoice}" = "nr" ]; then
            fasta=$(ls {params.downloaddir}/*nr.gz | head -1)
            names=$(ls {params.downloaddir}/*names.dmp | head -1)
            nodes=$(ls {params.downloaddir}/*nodes.dmp | head -1)
            acc2tax=$(ls {params.downloaddir}/*accession2taxid.FULL.gz | head -1)
        else
            fasta=$(ls {params.downloaddir}/gtdb_seqs.fa.gz | head -1)
            names=$(ls {params.downloaddir}/names.dmp | head -1)
            nodes=$(ls {params.downloaddir}/nodes.dmp | head -1)
            acc2tax=$(ls {params.downloaddir}/prot.accession2taxid.txt.gz | head -1)
        fi
        CAT_pack prepare --db_fasta "$fasta" --names "$names" --nodes "$nodes" --acc2tax "$acc2tax" \
            --db_dir {params.dbdir} --common_prefix dogma -n {threads} >> {log} 2>&1
        """


rule cat_annotate:
    input:
        contigs="results/03_ASSEMBLY/{sample}/{domain}/{sample}_transcripts_mad.fasta",
        proteins="results/04_ORF_CALLING/{sample}/{domain}/{sample}_transdecoder.pep",
        dmnd=os.path.join(CAT_DB, "db", "dogma.dmnd")
    output:
        classification="results/05_ANNOTATION/{sample}/{domain}/cat/{sample}.contig2classification.txt"
    params:
        dbdir=os.path.join(CAT_DB, "db"),
        taxdir=os.path.join(CAT_DB, "tax"),
        proteins_fixed="results/05_ANNOTATION/{sample}/{domain}/cat/{sample}_proteins_catfmt.faa",
        out_prefix="results/05_ANNOTATION/{sample}/{domain}/cat/{sample}",
        extra=config["params"].get("cat", "")
    threads: config["threads"]["cat"]
    conda: "../envs/cat.yaml"
    log: "logs/annotation/{sample}_{domain}_cat.log"
    shell:
        """
        mkdir -p $(dirname {params.out_prefix})
        sed -E '/^>/s/^>([^ ]+)\\.p([0-9]+)/>\\1_\\2/' {input.proteins} > {params.proteins_fixed}
        CAT_pack contigs -c {input.contigs} -d {params.dbdir} -t {params.taxdir} \
            -p {params.proteins_fixed} -o {params.out_prefix} -n {threads} --force {params.extra} > {log} 2>&1
        """
