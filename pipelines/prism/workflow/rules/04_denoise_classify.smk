import os
import re
import glob
import pandas as pd

samples = pd.read_table(config["samples"]).set_index("sample", drop=False).fillna("")


def _flag_value(params_str, flag, default):
    m = re.search(rf"{re.escape(flag)}\s+(\S+)", params_str)
    return m.group(1) if m else default


def _gene(tool_id):
    """The run-wide amplicon preset is authoritative for which marker gene
    this run is (it also supplies the matching primers and length window -- see config_engine.py's amplicon_preset block for why those three must
    agree). The Tools-tab --gene flag is only consulted when the preset
    declares no gene, i.e. the deliberately-empty "custom" preset, where the
    user is expected to set everything by hand."""
    preset_gene = (config.get("amplicon_preset", {}) or {}).get("gene", "")
    if preset_gene:
        return preset_gene
    return _flag_value(config["params"][tool_id], "--gene", "16S")


def _reference_db(tool_id):
    return _flag_value(config["params"][tool_id], "--reference_db", "gtdb")


def _emu_max_align_len():
    """Emu's own --max-align-len defaults to 2000 bp, tuned for 16S -- it
    silently DISCARDS every alignment longer than that. Real, reproduced
    failure: all 70 reads
    aligned fine, then "Filtered 70 alignments outside aligned query length
    bounds (min_align_len=0, max_align_len=2000)" -> "Mapped read count: 0"
    -> Emu died with "ValueError: 0 reads mapped". The full rrn operon is
    ~4.3-4.9 kb, so every single alignment exceeded the default.

    Derived from the amplicon preset's own length window (which already
    knows how long this amplicon is) plus 20% headroom, rather than adding
    yet another manifest field that could disagree with it. An explicit
    --max-align-len on the Tools tab still wins, and with no preset window
    we leave Emu's own default alone."""
    explicit = _flag_value(config["params"].get("emu_ont", ""), "--max-align-len", "")
    if explicit:
        return explicit
    max_len = (config.get("amplicon_preset", {}) or {}).get("max_length", 0)
    return str(int(max_len * 1.2)) if max_len else ""



# Each PRISM reference database is a single fasta FILE, but config["databases"]
# only ever holds the DIRECTORY the Databases tab was pointed at (databases_engine's
# get_databases_status/detect_databases both resolve to a base_dir, never the file
# inside it -- see its own module docstring) -- the exact kaiju-fmi-glob gotcha
# already handled in the short-read pipelines' *.fmi lookups (e.g.
# magma/workflow/rules/01_qc_tax.smk), just not yet applied here. These patterns
# mirror each database's own "detect_files" fingerprint in pipeline.yaml.
_DB_FILE_PATTERNS = {
    "gtdb_ssu": ["*.fa"],
    "silva_ssu": ["silva_ssu_dada2.fasta"],
    "silva_lsu": ["silva_lsu_dada2.fasta"],
    "unite_its": ["*.fasta"],
    "grond": ["grond_rrn_dada2.fasta"],
}


def _resolve_db_file(db_key):
    """Turns a configured database directory into the actual fasta file path
    dada2_pacbio.R / build_emu_taxonomy.py need. Tolerates a config value that
    is already a file (a manual override pointed straight at it), searches the
    directory itself first, then one level of subdirectories (matching
    validate_database's own one-level fallback) -- and returns "" rather than
    raising if nothing matches, since this runs at DAG-build time even for
    branches that won't actually execute."""
    base = config["databases"].get(db_key, "")
    if not base:
        return ""
    if os.path.isfile(base):
        return base
    if not os.path.isdir(base):
        return ""
    patterns = _DB_FILE_PATTERNS.get(db_key, ["*.fa", "*.fasta"])
    for pattern in patterns:
        hits = glob.glob(os.path.join(base, pattern))
        if hits:
            return sorted(hits)[0]
    for pattern in patterns:
        hits = glob.glob(os.path.join(base, "*", pattern))
        if hits:
            return sorted(hits)[0]
    return ""


def _resolve_ref_path(gene, reference_db):
    """Picks which configured database a --gene/--reference_db combination
    actually resolves to, then resolves that database's directory down to its
    actual fasta file (see _resolve_db_file). 18S/23S/28S only ever have one
    real option (SILVA SSU/LSU respectively -- GTDB never covers them), so
    --reference_db is ignored for those regardless of what it's set to; real
    validation (clear error, not a silent wrong answer) happens inside
    dada2_pacbio.R / the emu_build_db shell block below, not here -- this
    function alone must never raise, since Snakemake evaluates params
    lambdas at DAG-build time even for inactive branches, so an empty string
    is the correct "not configured yet" signal, not a crash.
    """
    gene = (gene or "16S").upper()
    # Full 16S-ITS-23S operon: GROND is the only reference that carries whole
    # operons (~4.3 kb each) -- no SSU/LSU-only database can classify an
    # amplicon that spans both subunits plus the ITS between them, so
    # --reference_db is ignored here the same way it is for ITS/18S/23S/28S.
    if gene == "RRN_OPERON":
        return _resolve_db_file("grond")
    if gene == "ITS":
        return _resolve_db_file("unite_its")
    if gene == "16S":
        return _resolve_db_file("silva_ssu") if reference_db == "silva" \
            else _resolve_db_file("gtdb_ssu")
    if gene == "18S":
        return _resolve_db_file("silva_ssu")
    if gene in ("23S", "28S"):
        return _resolve_db_file("silva_lsu")
    return ""

# ---------------------------------------------------------------------------
# PacBio HiFi path: cohort-level DADA2 (see workflow/scripts/dada2_pacbio.R).
# Runs once per run, not once per sample -- DADA2's own error model is
# learned across the whole cohort, same real practice as its tutorials.
# Touches an empty output when the run's platform isn't PacBio HiFi, the
# same if/else-touch idiom fastp/filtlong already use for their own
# short/long branching.
# ---------------------------------------------------------------------------
rule dada2_pacbio:
    input:
        reads=expand("results/03_CHIMERA/{sample}/{sample}_nonchimeric.fastq.gz", sample=samples.index)
    output:
        table="results/04_DENOISE/dada2/prism_abundance_table.tsv",
        # Real bug caught by a real dry-run: these ASV-level
        # files were being written by dada2_pacbio.R all along but never
        # declared as Snakemake outputs, so the new picrust2 rule (which
        # depends on them) couldn't be wired into the DAG at all
        # (MissingInputException). prism_tree.nwk is deliberately still NOT
        # declared here -- it's conditionally skipped for <3 ASVs even on
        # the real/active branch, so declaring it would break small runs;
        # tree-consuming rules don't exist yet anyway (see task #9).
        asv_fasta="results/04_DENOISE/dada2/prism_asv_sequences.fasta",
        asv_taxonomy="results/04_DENOISE/dada2/prism_asv_taxonomy.tsv",
        asv_counts="results/04_DENOISE/dada2/prism_asv_counts.tsv"
    params:
        gene=_gene("dada2_pacbio"),
        reference_db=_reference_db("dada2_pacbio"),
        max_ee=_flag_value(config["params"]["dada2_pacbio"], "--max_ee", "2.0"),
        min_freq=_flag_value(config["params"]["dada2_pacbio"], "--min_asv_totalfreq", "5"),
        ref_path=lambda wc: _resolve_ref_path(_gene("dada2_pacbio"), _reference_db("dada2_pacbio")),
        sample_list=",".join(samples.index),
        input_list=lambda wc, input: ",".join(input.reads)
    conda: "../envs/dada2.yaml"
    threads: config["threads"]["dada2_pacbio"]
    log: "logs/denoise/dada2_pacbio.log"
    shell:
        """
        if [ "{PLATFORM}" == "pacbio_hifi" ]; then
            Rscript {workflow.basedir}/workflow/scripts/dada2_pacbio.R \
                --input {params.input_list} --samples {params.sample_list} \
                --gene {params.gene} --reference_db {params.reference_db} --ref_path {params.ref_path} \
                --max_ee {params.max_ee} --min_asv_totalfreq {params.min_freq} \
                --out {output.table} > {log} 2>&1
        else
            mkdir -p $(dirname {output.table})
            touch {output.table} {output.asv_fasta} {output.asv_taxonomy} {output.asv_counts}
        fi
        """

# ---------------------------------------------------------------------------
# Nanopore path: Emu (expectation-maximization against a reference DB, see
# Curry et al. 2022 -- ASV-calling doesn't work at ONT's error rate). Build
# the custom reference-formatted database once (keyed by --gene, shared
# across every sample in the run), then classify per sample and join.
# ---------------------------------------------------------------------------
rule emu_build_db:
    # Real, tested pipeline: the prep files (fasta/seq2tax/taxonomy
    # this script builds *for* `emu build-database`) live under a `_prep/`
    # subdirectory, deliberately never named `species_taxid.fasta` --
    # `emu build-database` itself writes its OWN real `species_taxid.fasta`/
    # `taxonomy.tsv` directly into `db_{gene}/`, and a first version of this
    # rule had the prep fasta collide with that exact filename in that same
    # directory, a real bug caught by actually running it. `output:` below
    # is Emu's own real generated files, not the prep inputs -- the correct
    # thing for downstream rules to depend on.
    output:
        seqs="results/04_DENOISE/emu/db_{gene}/species_taxid.fasta",
        tax="results/04_DENOISE/emu/db_{gene}/taxonomy.tsv"
    params:
        ref=lambda wc: _resolve_ref_path(wc.gene, _reference_db("emu_ont")),
        prep_dir="results/04_DENOISE/emu/db_{gene}/_prep"
    conda: "../envs/emu.yaml"
    log: "logs/denoise/emu_build_db_{gene}.log"
    shell:
        """
        if [ "{PLATFORM}" == "ont" ]; then
            if [ -z "{params.ref}" ]; then
                echo "No reference database configured for --gene {wildcards.gene} (checked GTDB/SILVA SSU/SILVA LSU/UNITE as appropriate) -- configure it on the Databases tab first." > {log}
                exit 1
            fi
            mkdir -p {params.prep_dir}
            python3 {workflow.basedir}/workflow/scripts/build_emu_taxonomy.py \
                --ref {params.ref} \
                --out_fasta {params.prep_dir}/sequences.fasta \
                --out_seq2tax {params.prep_dir}/seq2tax.tsv \
                --out_taxonomy {params.prep_dir}/taxonomy.tsv > {log} 2>&1
            emu build-database results/04_DENOISE/emu/db_{wildcards.gene} \
                --sequences {params.prep_dir}/sequences.fasta \
                --seq2tax {params.prep_dir}/seq2tax.tsv \
                --taxonomy-list {params.prep_dir}/taxonomy.tsv >> {log} 2>&1
        else
            mkdir -p $(dirname {output.seqs})
            touch {output.seqs} {output.tax}
        fi
        """

rule emu_classify:
    input:
        long="results/03_CHIMERA/{sample}/{sample}_nonchimeric.fastq.gz",
        db_seqs=lambda wc: f"results/04_DENOISE/emu/db_{_gene('emu_ont')}/species_taxid.fasta"
    output:
        table="results/04_DENOISE/emu/{sample}/{sample}_rel-abundance.tsv"
    params:
        gene=_gene("emu_ont"),
        min_abundance=_flag_value(config["params"]["emu_ont"], "--min-abundance", "0.0001"),
        max_align_len=_emu_max_align_len(),
        db_dir=lambda wc: f"results/04_DENOISE/emu/db_{_gene('emu_ont')}"
    conda: "../envs/emu.yaml"
    threads: config["threads"]["emu_ont"]
    log: "logs/denoise/emu_{sample}.log"
    shell:
        """
        if [ "{PLATFORM}" == "ont" ]; then
            MAXLEN=""
            if [ -n "{params.max_align_len}" ]; then MAXLEN="--max-align-len {params.max_align_len}"; fi
            emu abundance {input.long} --db {params.db_dir} --min-abundance {params.min_abundance} \
                $MAXLEN \
                --keep-counts --threads {threads} --output-dir results/04_DENOISE/emu/{wildcards.sample} \
                --output-basename {wildcards.sample} > {log} 2>&1
        else
            mkdir -p $(dirname {output.table})
            touch {output.table}
        fi
        """

rule join_emu:
    input:
        tables=expand("results/04_DENOISE/emu/{sample}/{sample}_rel-abundance.tsv", sample=samples.index)
    output:
        table="results/04_DENOISE/emu/prism_abundance_table.tsv",
        # tax_id-resolution table (not lineage-collapsed) # feeds build_emu_tree.R below, which needs to know exactly which
        # reference tax_ids were detected across the cohort. Always produced
        # (even if empty/header-only, same as `table` above), unlike the tree
        # itself which is conditionally skipped for <3 detected species.
        species="results/04_DENOISE/emu/prism_species_counts.tsv"
    params:
        pairs=lambda wc, input: [f"{s}:{t}" for s, t in zip(samples.index, input.tables)]
    log: "logs/denoise/join_emu.log"
    shell:
        "python3 {workflow.basedir}/workflow/scripts/join_emu_tables.py "
        "--inputs {params.pairs} --out {output.table} --out_species {output.species} > {log} 2>&1"

# ---------------------------------------------------------------------------
# ONT/Emu path's phylogenetic tree -- Emu is reference-only EM classification
# (no per-sample consensus sequence, unlike DADA2's ASVs), so there is
# nothing to align/tree per-sample. Instead this builds a "closed-reference"
# tree from the actual REFERENCE sequences Emu matched reads to across the
# whole cohort (extracted from the Emu database's own species_taxid.fasta by
# the tax_ids that appear in prism_species_counts.tsv), reusing the exact
# same DECIPHER/phangorn method as the PacBio/DADA2 path (see
# lib/build_tree.R and build_emu_tree.R). Like dada2_pacbio's prism_tree.nwk,
# the tree + filtered taxonomy files are NOT declared as Snakemake outputs --
# build_emu_tree.R conditionally skips them for <3 detected species, so a
# hard file-existence contract would break small/sparse runs; a flag file is
# the only thing this rule promises to produce every time it actually runs.
# ---------------------------------------------------------------------------
rule emu_tree:
    input:
        species_counts="results/04_DENOISE/emu/prism_species_counts.tsv",
        ref_seqs=lambda wc: f"results/04_DENOISE/emu/db_{_gene('emu_ont')}/species_taxid.fasta",
        ref_tax=lambda wc: f"results/04_DENOISE/emu/db_{_gene('emu_ont')}/taxonomy.tsv"
    output:
        flag="results/04_DENOISE/emu/tree_done.flag"
    params:
        out_dir="results/04_DENOISE/emu"
    conda: "../envs/dada2.yaml"  # reuses the same DECIPHER/phangorn/Biostrings/optparse stack already pinned there, not a separate env
    log: "logs/denoise/emu_tree.log"
    shell:
        """
        if [ "{PLATFORM}" == "ont" ]; then
            Rscript {workflow.basedir}/workflow/scripts/build_emu_tree.R \
                --species_counts {input.species_counts} --ref_fasta {input.ref_seqs} \
                --taxonomy {input.ref_tax} --out_dir {params.out_dir} > {log} 2>&1
        else
            echo "emu_tree: skipped (platform={PLATFORM})" > {log}
        fi
        touch {output.flag}
        """

# ---------------------------------------------------------------------------
# Final: whichever engine actually ran (dada2 vs emu) produced a real,
# non-empty table; the other is the empty touch-placeholder. Pick the
# non-empty one so downstream (Plots tab) always reads from one stable path
# regardless of platform.
# ---------------------------------------------------------------------------
rule select_abundance_table:
    input:
        dada2="results/04_DENOISE/dada2/prism_abundance_table.tsv",
        emu="results/04_DENOISE/emu/prism_abundance_table.tsv"
    output:
        table="results/05_ABUNDANCE_TABLE/prism_abundance_table.tsv"
    log: "logs/denoise/select_abundance_table.log"
    shell:
        """
        mkdir -p $(dirname {output.table})
        if [ -s {input.dada2} ]; then
            cp {input.dada2} {output.table}
        elif [ -s {input.emu} ]; then
            cp {input.emu} {output.table}
        else
            echo "select_abundance_table: neither engine produced output (platform={PLATFORM})" > {log}
            touch {output.table}
        fi
        """
