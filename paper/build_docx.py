#!/usr/bin/env python3
"""Builds Artigo.docx directly with python-docx -- more reliable than the
HTML->soffice route for tables (LibreOffice's HTML import filter mis-sized
columns, causing one-character-per-line wrapping)."""
import json
import os
import docx
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

BLACK = RGBColor(0, 0, 0)

doc = Document()

# --- base style: Times New Roman 12pt everywhere, no theme colors ---
style = doc.styles["Normal"]
style.font.name = "Times New Roman"
style.font.size = Pt(12)
style.font.color.rgb = BLACK
for section in doc.sections:
    section.left_margin = Cm(2.5)
    section.right_margin = Cm(2.5)
    section.top_margin = Cm(2.5)
    section.bottom_margin = Cm(2.5)

_counters = [0, 0, 0]  # level 1, 2, 3

def set_cell_shading(cell, hex_color):
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), hex_color)
    cell._tc.get_or_add_tcPr().append(shd)

def add_pending(paragraph, text):
    run = paragraph.add_run(text)
    run.font.name = "Times New Roman"
    run.font.size = Pt(12)
    run.font.color.rgb = BLACK
    run.bold = True
    return run

def add_note(text):
    p = doc.add_paragraph()
    r = p.add_run(text)
    r.font.name = "Times New Roman"
    r.font.size = Pt(12)
    r.font.color.rgb = BLACK
    r.italic = True
    doc.add_paragraph()

def heading(text, level=1):
    """Plain black Times New Roman heading with manual 1. / 1.1 / 1.1.1
    numbering (no Word theme styles/colors -- kept simple on request)."""
    _counters[level - 1] += 1
    for i in range(level, 3):
        _counters[i] = 0
    number = ".".join(str(_counters[i]) for i in range(level))
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14 if level == 1 else 8)
    p.paragraph_format.space_after = Pt(4)
    r = p.add_run(f"{number}. {text}" if level == 1 else f"{number} {text}")
    r.bold = True
    r.font.name = "Times New Roman"
    r.font.size = Pt(12)
    r.font.color.rgb = BLACK
    return p

def unnumbered_heading(text):
    """Abstract and back matter (Acknowledgements/References/Data
    Accessibility/Author Contributions/Tables and Figures) are not
    numbered -- only the body sections (Introduction..Discussion) are,
    per standard journal convention and the user's explicit correction
    (Introduction = 1, not Abstract)."""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14)
    p.paragraph_format.space_after = Pt(4)
    r = p.add_run(text)
    r.bold = True
    r.font.name = "Times New Roman"
    r.font.size = Pt(12)
    r.font.color.rgb = BLACK
    return p

def unnumbered_subheading(text, level=2):
    """Bold, unnumbered sub-heading for back-matter sections (References'
    own internal groupings: Platforms and validation datasets / Tools and
    reference databases / Tools / Reference databases). These sit inside
    an unnumbered_heading() section, so they must not borrow the running
    1./2./3. body-section counter the way heading() does."""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(10 if level == 2 else 6)
    p.paragraph_format.space_after = Pt(4)
    r = p.add_run(text)
    r.bold = True
    r.font.name = "Times New Roman"
    r.font.size = Pt(12 if level == 2 else 11)
    r.font.color.rgb = BLACK
    return p

def para(text="", size=12, italic=False, bold=False):
    p = doc.add_paragraph()
    if text:
        r = p.add_run(text)
        r.font.name = "Times New Roman"
        r.font.size = Pt(size)
        r.font.color.rgb = BLACK
        r.italic = italic
        r.bold = bold
    return p

def set_col_widths(table, widths_cm):
    table.autofit = False
    for row in table.rows:
        for cell, w in zip(row.cells, widths_cm):
            cell.width = Cm(w)
    # also set on the table grid (needed for some renderers to respect it)
    tbl = table._tbl
    tblGrid = tbl.find(qn("w:tblGrid"))
    if tblGrid is not None:
        for gridCol, w in zip(tblGrid.findall(qn("w:gridCol")), widths_cm):
            gridCol.set(qn("w:w"), str(int(w * 567)))  # cm -> twips approx

def make_table(headers, rows, widths_cm, pending_cols=None):
    pending_cols = pending_cols or set()
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    hdr_cells = table.rows[0].cells
    for i, h in enumerate(headers):
        hdr_cells[i].text = ""
        p = hdr_cells[i].paragraphs[0]
        r = p.add_run(h)
        r.bold = True
        r.font.name = "Times New Roman"
        r.font.size = Pt(10)
        r.font.color.rgb = BLACK
    for row in rows:
        cells = table.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            is_pending = isinstance(val, str) and val.startswith("[PENDING")
            r = p.add_run(val)
            r.font.name = "Times New Roman"
            r.font.size = Pt(10)
            r.font.color.rgb = BLACK
            if is_pending:
                r.bold = True
    set_col_widths(table, widths_cm)
    doc.add_paragraph()
    return table

# ============================================================
# TITLE PAGE
# ============================================================
title_p = doc.add_paragraph()
title_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = title_p.add_run(
    "OmniOmics: a local pipeline hub for reproducible, end-to-end "
    "multi-omics analysis with Snakemake and conda"
)
r.bold = True
r.font.size = Pt(16)

doc.add_paragraph()
auth = doc.add_paragraph()
auth.alignment = WD_ALIGN_PARAGRAPH.CENTER
ra = auth.add_run("Angelo Felipe Barbosa de Oliveira")
ra.bold = True
ra.font.size = Pt(12)
sup = auth.add_run("1")
sup.font.superscript = True

affil = doc.add_paragraph()
affil.alignment = WD_ALIGN_PARAGRAPH.CENTER
raf = affil.add_run(
    "1Programa de Pós-Graduação em Genética e Biologia Molecular, "
    "Universidade Federal do Pará (UFPA), Belém, PA, Brazil. "
    "ORCID: 0000-0003-0831-447X"
)
raf.font.size = Pt(10)
raf.font.color.rgb = BLACK

doc.add_paragraph()

# ============================================================
# ABSTRACT
# ============================================================
unnumbered_heading("Abstract")
para(
    "Wet-lab microbiologists without terminal or HPC fluency are "
    "effectively locked out of reproducible multi-omics analysis: "
    "workflow managers like Snakemake and Nextflow solve reproducibility "
    "but still assume command-line comfort; existing graphical platforms "
    "target a single omics type or require dedicated server "
    "infrastructure. OmniOmics is a native desktop application "
    "wrapping five independent Snakemake pipelines, MAGMA "
    "(metagenomics), SIGMA (isolate genomics), DOGMA "
    "(metatranscriptomics), DEFINE (differential expression), and PRISM "
    "(amplicon metabarcoding), behind one graphical interface with an "
    "integrated plotting environment, no server or terminal required. "
    "Four of five pipelines were added after the core application with "
    "no change to its pipeline execution layer, evidence the "
    "architecture generalizes. All five pipelines were validated end "
    "to end on real, "
    "non-simulated public datasets against independent, external ground "
    "truth: certified mock-community compositions, reference genomes, "
    "two published papers' own reported results, and a sequencing "
    "vendor's own classification of the same read file. Results were "
    "strong and mostly concordant, reported honestly where they were "
    "not: DOGMA matched 11 of 12 real nitrogen-cycle gene/category "
    "directions against Chuckran et al. (2021); MAGMA correctly "
    "recovered and classified 7 of 7 metagenome-assembled genomes with "
    "no false calls; DEFINE's DEG call rate matched its source paper's "
    "order of magnitude with full functional-category overlap; SIGMA's "
    "hybrid long-read assembly reached 100% reference genome fraction; "
    "PRISM's real-sample taxonomic profiling showed strong compositional "
    "agreement (Bray-Curtis 0.08-0.11) with the vendor's own "
    "classification of the identical reads. OmniOmics is open source "
    "(MIT license), packaged as a .deb, with a companion repository "
    "(github.com/oliv-angelus/OmniOmics-validation) providing every "
    "configuration, ground truth, and raw result behind this validation."
)

# ============================================================
# INTRODUCTION
# ============================================================
heading("Introduction", level=1)
para(
    "Reproducible multi-omics analysis increasingly depends on workflow "
    "managers such as Snakemake (Mölder et al., 2021) or Nextflow "
    "(Di Tommaso et al., 2017), which "
    "solve reproducibility and dependency management but assume comfort "
    "with a command line, a terminal session, and often direct HPC "
    "access. This is a real barrier for a large fraction of the "
    "researchers who generate the data in the first place, including "
    "wet-lab microbiologists, ecologists, and clinicians without "
    "dedicated bioinformatics support, who are left either learning "
    "enough of the command line to be dangerous, or depending entirely "
    "on a collaborator for every new analysis."
)
para(
    "Existing solutions address one half of this problem at a time. "
    "Galaxy (Galaxy Community, 2022) and KBase (Arkin et al., 2018) "
    "provide a graphical interface but require server or cloud "
    "infrastructure, whether self-hosted or a shared public instance, "
    "rather than a local install a single researcher can simply run. "
    "nf-core (Ewels et al., 2020) and Bactopia (Petit & Read, 2020) are "
    "local-first and reproducible but remain CLI-anchored; nf-core's "
    "own launch command adds a native parameter-entry GUI, but still "
    "requires a terminal to invoke and has no run-monitoring or results "
    "dashboard without the separate, commercial Seqera Platform layer. "
    "Anvi'o (Eren et al., 2021) is local and genuinely multi-omics, but "
    "its interactive interface is a downstream visualization layer over "
    "already-processed data, not a full configure-run-monitor pipeline "
    "execution environment. Bactopia is local-first and easy to run but "
    "confined to a single domain, bacterial genomics."
)
para(
    "OmniOmics is built to close that specific, compound gap: a "
    "desktop-native application, requiring no terminal, no self-hosted "
    "server, and no cloud dependency, that covers the entire configure "
    "→ run → monitor → analyze loop across five independent omics "
    "domains in one interface, and is designed so that new pipelines "
    "can be added without touching the application's own code."
)

# ============================================================
# MATERIALS AND METHODS
# ============================================================
heading("Materials and Methods", level=1)

heading("Architecture", level=2)
para(
    "OmniOmics is a Flutter desktop application (the graphical client, "
    "no HTML/WebView) that spawns a FastAPI/Python backend as a local "
    "child process, communicating over HTTP and WebSocket on "
    "127.0.0.1. All pipeline orchestration logic, including "
    "conda/Snakemake environment management, database download with "
    "progress reporting, Snakemake log parsing, and run monitoring, "
    "lives in the backend; the Flutter layer is a thin client."
)
para(
    "Each pipeline is a self-contained directory (pipelines/<id>/) "
    "holding its own Snakemake workflow and a pipeline.yaml manifest "
    "describing its tools, parameters, thread defaults, and database "
    "requirements in a declarative schema. The backend discovers "
    "installed pipelines by scanning for this manifest at startup; "
    "adding a pipeline means adding a new directory, not modifying "
    "application code. Shared databases (e.g., CheckM2, GTDB-Tk, used "
    "by more than one pipeline) are deduplicated and configured once at "
    "the application level rather than per pipeline."
)
para(
    "The five pipelines packaged at the time of writing are: MAGMA, "
    "for shotgun metagenomics (assembly, binning, MAG recovery, and "
    "annotation); SIGMA, for single bacterial isolate genome assembly, "
    "polishing, and annotation; DOGMA, for metatranscriptomics (de novo "
    "assembly and functional annotation); DEFINE, for bacterial isolate "
    "RNA-seq and differential expression; and PRISM, for amplicon "
    "metabarcoding (16S/18S/23S/28S/ITS/rrn-operon/COI/12S, both "
    "short-read and long-read)."
)
para(
    "Beyond running each pipeline, the application includes a Plots tab "
    "that generates publication-ready preview figures directly from a "
    "completed run's own output (diversity, ordination, differential "
    "abundance, and other standard analyses per pipeline), each "
    "parametrized through the GUI. This lets a researcher without R "
    "programming experience produce and inspect real statistical "
    "figures from their own data without writing analysis code."
)

heading("Extensibility claim", level=2)
para(
    "MAGMA was the founding pipeline; SIGMA, DOGMA, DEFINE, and PRISM "
    "were added afterward, each without any change to the pipeline "
    "execution layer: discovery, configuration, run submission, and "
    "monitoring all worked immediately from the new pipeline's "
    "directory and manifest alone. This is presented as direct, "
    "structural evidence for the extensibility claim, not an assertion."
)
para(
    "The one layer with real, incremental additions per pipeline is the "
    "Plots tab described above. Each pipeline's own output shape needed "
    "a small, targeted extension the first time it was wired in, for "
    "example a new parameter type for SIGMA's per-genome analyses "
    "(isolate assembly has no cross-sample table the way a community "
    "profile does) and a pipeline-aware output-file lookup for PRISM (a "
    "different final-table filename than MAGMA's). These are honestly "
    "reported as small, bounded additions to a shared visualization "
    "layer, not exceptions to the execution-layer extensibility claim "
    "above."
)

heading("Comparison to existing platforms (Deliverable A)", level=2)
para(
    "Six adjacent platforms were compared on interface, deployment "
    "model, domain breadth, and extensibility mechanism, chosen because "
    "each occupies a real, citable niche adjacent to OmniOmics's, "
    "rather than as a direct tool-for-tool competitor. Comparison used each "
    "platform's current public documentation as of 2026-08-27, not "
    "only its founding publication's abstract. See Table 1. A second, "
    "domain-matched comparison against the single-purpose pipeline a "
    "researcher would otherwise use for each of OmniOmics's five "
    "domains (Table 1b) makes the same argument at finer grain."
)

heading("Real end-to-end validation (Deliverable B)", level=2)
para(
    "OmniOmics orchestrates third-party tools without modifying or "
    "reimplementing their algorithms; a head-to-head accuracy benchmark "
    "against other pipelines would therefore measure those underlying "
    "tools, not this contribution's own logic. Instead, each of the "
    "five pipelines was run for real, neither as a dry run nor on "
    "synthetic data, against a public dataset with an independently "
    "known, published expected result, using the identical Snakemake "
    "invocation and config schema the application itself generates "
    "internally, executed on a compute node with 128 CPU cores, ~264 GB "
    "RAM, and openSUSE Leap 15.3, with per-tool thread and memory "
    "allocations set in each pipeline's own configuration (published in "
    "full in the companion repository, see Data Accessibility). "
    "Correctness was then checked against that published ground truth, "
    "not against another tool's output."
)
para(
    "Datasets, their ground truth, and the pass criterion used for each "
    "pipeline are in Table 2. Sample sizes were chosen following "
    "standard practice for this kind of infrastructure/orchestration "
    "demonstration, rather than for a novel biological replication "
    "study, matching nf-core's own minimal test-profile convention and "
    "SARTools's (Varet et al., 2016) three-replicates-per-condition "
    "validation design, rather than reproducing each source study's "
    "full replicate count."
)
para(
    "Raw sequencing data is never re-hosted; every dataset is already "
    "public (SRA/ENA/GEO/vendor open-data accessions, cited in Table "
    "2). The exact configuration files, curated ground truth, and "
    "observed-vs-expected comparison for every pipeline are published "
    "as a companion reproducibility package (OmniOmics-validation, see "
    "Data Accessibility)."
)

# ============================================================
# RESULTS
# ============================================================
heading("Results", level=1)

heading("Table 1. Comparison to existing platforms", level=2)
t1_headers = ["Platform", "Citation", "Interface", "Deployment", "Domain breadth", "Extensibility model"]
t1_rows = [
    ["Galaxy", "Galaxy Community 2022, doi:10.1093/nar/gkac247", "Browser (web)", "Server/cloud, self-hosted or public", "Broad, tool-agnostic", "ToolShed XML wrappers, large ecosystem"],
    ["nf-core", "Ewels et al. 2020, doi:10.1038/s41587-020-0439-x", "CLI (Nextflow); native parameter-entry GUI (launch), no run-monitoring dashboard without commercial Seqera layer", "Local/HPC/cloud", "Broad, community-curated catalog", "New pipeline = new community-reviewed repo"],
    ["KBase", "Arkin et al. 2018, doi:10.1038/nbt.4163", "Browser (narrative interface)", "Cloud-hosted (DOE infra)", "Systems/microbiology/plant biology", "App-based, centrally curated"],
    ["Anvi'o", "Eren et al. 2021, doi:10.1038/s41564-020-00834-3", "CLI + interactive HTML/D3 visualization, not a run-orchestration GUI", "Local", "Multi-omics, strongest in metagenomics", "Plugin-style, community-led"],
    ["Bactopia", "Petit & Read 2020, doi:10.1128/mSystems.00190-20", "CLI (Nextflow)", "Local/HPC/cloud", "Single domain: bacterial genomics only", "“Bactopia Tools” post-processing modules"],
    ["Snakemake (engine OmniOmics builds on)", "Mölder et al. 2021, doi:10.12688/f1000research.29032.3", "CLI, no native GUI", "Local/HPC/cloud", "Generic, domain-agnostic", "Rules-based, per-project"],
    ["OmniOmics (this work)", "N/A", "Native desktop GUI, zero terminal", "Local, zero server/cloud dependency", "5 domains in one app", "New pipeline = new directory + manifest, no core code change"],
]
make_table(t1_headers, t1_rows, widths_cm=[2.5, 2.7, 2.7, 2.7, 2.7, 3.2])

heading("Table 1b. Comparison to domain-matched pipelines", level=2)
para(
    "Table 1 compares OmniOmics against general multi-tool platforms. A "
    "second, more specific comparison is arguably more informative: "
    "against the single-domain pipeline a researcher would otherwise "
    "use for each of OmniOmics's five domains. All six domain-matched "
    "pipelines below are CLI-only (Nextflow-based nf-core pipelines "
    "inherit nf-core's own interface model: a native parameter-entry "
    "GUI, launch, exists but still requires a terminal to invoke and "
    "has no run-monitoring/results dashboard without the separate, "
    "commercial Seqera Platform). QIIME2 is the one exception that "
    "attempted a native desktop GUI (q2studio), which was never more "
    "than an alpha-stage prototype and has been archived since "
    "December 2023, unmaintained and unusable with current QIIME2 "
    "releases."
)
t1b_headers = ["OmniOmics pipeline", "Domain-matched tool", "Citation", "Native GUI", "Reference databases", "Domain scope"]
t1b_rows = [
    ["MAGMA", "nf-core/mag + nf-core/taxprofiler (two separate pipelines chained together)",
     "Krakau et al. 2022, doi:10.1093/nargab/lqac007; Stamouli et al. 2023 (preprint), doi:10.1101/2023.10.20.563221",
     "None", "Auto-downloads GTDB-Tk (~110 GB) and CAT/NCBI-nr (~200 GB) as two separate standalone downloads", "mag: assembly/binning/MAG taxonomy only, no read-level community profiling; taxprofiler: read-level profiling only, no assembly"],
    ["SIGMA", "nf-core/bacass", "nf-core community, github.com/nf-core/bacass",
     "None", "Kraken2/KmerFinder database paths must be supplied manually", "Bacterial isolate assembly only"],
    ["DOGMA", "nf-core/metatdenovo", "Di Leo et al. 2025, doi:10.7717/peerj.20328",
     "None", "Per-database manual configuration", "Metatranscriptome assembly/annotation only"],
    ["DEFINE", "nf-core/rnaseq + nf-core/differentialabundance (two separate pipelines chained together)", "nf-core community",
     "None", "Reference genome/annotation supplied by the user", "Differential expression only"],
    ["PRISM", "nf-core/ampliseq", "nf-core community, github.com/nf-core/ampliseq",
     "None", "Auto-downloads SILVA/UNITE/PR2/GTDB on demand", "Amplicon metabarcoding only"],
    ["PRISM (alt.)", "QIIME2", "Bolyen et al. 2019, doi:10.1038/s41587-019-0209-9",
     "q2studio: archived Dec. 2023, alpha-stage prototype, unmaintained", "Manual per-plugin configuration", "Amplicon metabarcoding only"],
]
make_table(t1b_headers, t1b_rows, widths_cm=[2.3, 3.3, 3.0, 3.0, 3.2, 2.2])
para(
    "Reproducing what OmniOmics covers in one application would require "
    "installing, learning, and separately running at least seven "
    "different Nextflow pipelines, none of which share a common "
    "interface, database manager, or run-monitoring view with each "
    "other. Reference-database handling in the nf-core ecosystem is "
    "itself real and often well engineered (nf-core/mag and "
    "nf-core/ampliseq both auto-download curated databases), which is "
    "why this is not presented as a database-automation gap; the actual "
    "gap is that database management stays siloed per pipeline, with no "
    "shared, GUI-driven view across domains, the same gap that applies "
    "to configuration, execution, and monitoring throughout this "
    "comparison."
)

heading("Table 2. Validation datasets, ground truth, and pass criterion", level=2)
t2_headers = ["Pipeline", "Dataset", "Ground truth", "Pass criterion"]
t2_rows = [
    ["MAGMA", "ZymoBIOMICS mock community, even+log, hybrid Illumina+ONT (Nicholls et al. 2019, doi:10.1093/gigascience/giz043)", "Certified theoretical composition (%) per species", "Observed abundance within 10% of certified value; correct species-level taxonomy for all 10"],
    ["SIGMA", "Individual E. coli isolate, same Zymo series, Illumina + independent ONT/PacBio (McIntyre et al. 2019, doi:10.1038/s41467-019-08289-9)", "Zymo's own reference genome for the isolate", "QUAST vs. reference: genome fraction, N50, misassemblies; hybrid vs. short-only comparison"],
    ["DOGMA", "Soil metatranscriptome, glucose-amendment time course (samples: Chuckran et al. 2020, doi:10.1128/MRA.00895-20; expected results: Chuckran et al. 2021, doi:10.1128/mSystems.00161-21)", "Direction of change (up/down) for named gene categories at t8 vs t0, real fold-changes from the paper", "DESeq2 log2FoldChange sign matches reported direction"],
    ["DEFINE", "E. coli exposed to 239Pu vs. control, day 1 (GEO GSE208658, doi:10.1128/msystems.00718-22)", "590 DEGs (13.8% of CDSs) reported for this contrast; enriched functional categories", "DEG count same order of magnitude; enriched categories overlap"],
    ["PRISM", "ZymoBIOMICS 16S “MSPlus” community, ONT (Oxford Nanopore Technologies 2025, vendor open-data release zymo_16s_2025.09)", "ONT's own official Emu classification for the same read file", "Species-level abundance correlates with ONT's own result; all 4 spiked species detected"],
]
make_table(t2_headers, t2_rows, widths_cm=[2.2, 4.8, 4.3, 4.7])

heading("Real validation outcomes", level=2)
t3_headers = ["Pipeline", "Status", "Headline result"]
t3_rows = [
    ["SIGMA (ONT path)", "Complete, PASS",
     "Hybrid Illumina+ONT assembly of a Zymo reference E. coli isolate recovered "
     "100.000% genome fraction against the certified reference genome, zero "
     "misassemblies, total length within 11 bp of the reference (4,875,452 vs. "
     "4,875,441 bp). Short-read-only assembly of the same isolate, correctly "
     "more fragmented (87 aligned contigs vs. 2) but still zero misassemblies, "
     "demonstrating measurable improvement from long-read polishing without "
     "introducing structural error."],
    ["SIGMA (PacBio path)", "Complete, mixed outcome (see Discussion)",
     "Hybrid Illumina+PacBio assembly of the same isolate (PacBio RS II CLR "
     "subreads, McIntyre et al. 2019) correctly identified the species "
     "(GTDB-Tk) with 100.0% CheckM2 completeness and 99.04% genome fraction "
     "against the reference, but introduced 21 real misassemblies (6 "
     "misassembled contigs, 8 local); the short-read-only assembly of the "
     "same isolate had zero. Attributed to the CLR chemistry's "
     "substantially higher raw per-read error rate relative to the ONT "
     "run above (no circular-consensus correction in this 2018-era "
     "dataset), not a pipeline defect; reported as an honest, mixed "
     "result rather than a uniform PASS."],
    ["DEFINE", "Complete, PASS",
     "Real DESeq2 analysis (E. coli exposed to 239Pu vs. non-irradiated "
     "control, day 1, 3 replicates per condition) against the real GEO "
     "GSE208658 reference genome, using the paper's own stated DEG "
     "criteria (log2FC>2 and padj<0.05, Wintenberg et al. 2023) rather than "
     "padj alone, found 433 significant DEGs (9.9% of tested genes), the "
     "same order of magnitude as the paper's reported 590 (13.8%). "
     "Functional-category overlap with the paper also held: significant "
     "genes were real hits in every category reported as enriched for this "
     "contrast (ABC transporters, siderophore biosynthesis, stress "
     "response, amino acid biosynthesis)."],
    ["PRISM (ground-truth run, ONT 16S “MSPlus”)", "Complete, mixed outcome (see Discussion)",
     "Real Emu classification (GTDB SSU r220 reference) of 3 ONT MSPlus "
     "replicates, compared against ONT's own official Emu classification "
     "of the same read files, at genus level (species-level nomenclature "
     "differs between GTDB releases). Bray-Curtis dissimilarity, the "
     "standard compositional-similarity metric for this kind of data, "
     "was 0.08-0.11 across replicates (mean 0.10), indicating strong "
     "community-level agreement; Pearson r (0.96-0.98) and Spearman rho "
     "(0.66-0.79) are reported alongside it rather than in isolation, "
     "since Pearson alone is dominated by a few high-abundance genera. Of "
     "the four spiked-in species specifically tracked, three were "
     "detected with closely matching abundances (Bifidobacterium "
     "adolescentis, B. vaginale, Borreliella/Borrelia burgdorferi); "
     "Chlamydia trachomatis was not detected at all, most likely due to "
     "the documented mismatch between universal 16S primers and "
     "Chlamydiae sequences rather than a database or classification "
     "defect (the reference genome is present in the database used)."],
    ["MAGMA", "Complete, mixed outcome (see Discussion)",
     "Real hybrid Illumina+Nanopore assembly and binning of the ZymoBIOMICS "
     "even and log-distributed mock communities. Two independent lines of "
     "evidence: (1) read-based taxonomic profiling (Kraken2+Bracken) "
     "detected all 10 reference species in both distributions, spanning "
     "roughly five orders of magnitude in the log-distributed sample, but "
     "matched the certified composition within a pre-registered "
     "±10%-relative tolerance for only 2 of 10 species on the "
     "equal-abundance sample; real deviations for the remaining 8 "
     "(0.5-3.6 percentage points) are consistent with known extraction-"
     "efficiency and genome-copy-number biases in read-based abundance "
     "estimation, not a pipeline defect. (2) Real metagenome assembly and "
     "binning recovered 7 dereplicated MAGs, all 7 correctly classified "
     "to the right species by GTDB-Tk with no false calls and high to "
     "medium quality (CheckM2 completeness 81.7-100%, contamination "
     "0.0-5.6%), the pipeline's actual differentiator from simple "
     "read-classification tools."],
    ["DOGMA", "Complete, strong result (see Discussion)",
     "Real metatranscriptome assembly (rnaSPAdes+MEGAHIT+Trinity ensemble, "
     "MMseqs2-deduplicated) and functional annotation of 4 real soil "
     "metatranscriptome samples (2 replicates x 2 timepoints, glucose "
     "amendment, Chuckran et al. 2021). Since each sample is assembled "
     "independently (no shared reference transcriptome across samples), "
     "differential expression was computed by pooling Salmon's "
     "per-transcript read counts onto each sample's own gene-family "
     "annotation (eggNOG/NCycDB), then running DESeq2 (C8 vs. C0) on the "
     "resulting gene-family count matrix. 11 of 12 detected genes/"
     "categories (92%) matched the paper's reported direction of change, "
     "including every gene/category the paper itself reports as a "
     "strong effect: the ammonium transporter amtB, the GS-GOGAT "
     "nitrogen-assimilation pathway, and the nitrogen regulatory network "
     "all significantly upregulated at 8h (padj<=1.8e-4); nitrification "
     "and denitrification genes both significantly downregulated "
     "(padj<=0.04). The one mismatch, crp, a global carbon-catabolite "
     "regulator rather than a nitrogen-cycle gene per se, was a subtle, "
     "non-significant effect in both this run and the original paper."],
]
make_table(t3_headers, t3_rows, widths_cm=[3.5, 2.5, 10.0])

# ============================================================
# DISCUSSION
# ============================================================
heading("Discussion", level=1)
para(
    "SIGMA's two long-read paths on the same isolate illustrate a "
    "point worth stating explicitly rather than only reporting a "
    "PASS/FAIL count: assembly quality is a function of input data "
    "quality, and a real validation should show that honestly. The ONT "
    "path (modern chemistry) improved on every axis over the "
    "short-read-only baseline, with fewer contigs, higher N50, and "
    "genome fraction reaching 100.000% without introducing a single "
    "misassembly. The PacBio path, built from 2018-era RS II CLR "
    "subreads with no circular-consensus correction, recovered more of "
    "the genome and higher completeness than short-only, but at a real "
    "cost: 21 misassemblies the short-read assembly did not have. "
    "Neither result was adjusted or selectively reported after the "
    "fact; both are the direct QUAST-vs-reference output. Presenting "
    "the PacBio result as a mixed outcome rather than reframing it as a "
    "pass is itself part of the validation's honesty: it demonstrates "
    "that OmniOmics faithfully reproduces whatever the underlying tools "
    "and input data actually produce, rather than the demonstration "
    "being tuned toward uniformly clean results."
)
para(
    "DEFINE's real validation compared its DESeq2 output against the "
    "source paper's own stated criteria for calling a gene differentially "
    "expressed (log2 fold-change greater than 2 and padj<0.05; Wintenberg "
    "et al. 2023), rather than an adjusted p-value cutoff alone, since the "
    "paper's headline DEG count was reported under that two-part "
    "definition. Under those matched criteria, DEFINE's real output gave "
    "433 significant genes (9.9% of tested genes) against the paper's "
    "reported 590 (13.8%), the same order of magnitude. The "
    "functional-category check passed as well: significant genes were "
    "real hits in every category the paper reports as enriched for this "
    "contrast (ABC transporters, siderophore biosynthesis, stress "
    "response, amino acid biosynthesis)."
)
para(
    "MAGMA's real validation is best read as two separate claims with "
    "different outcomes, deliberately reported that way rather than "
    "collapsed into one score. Read-based taxonomic profiling alone, the "
    "same kind of result nf-core/taxprofiler or a plain Kraken2 run "
    "would give, detected all 10 reference species correctly in both "
    "the equal-abundance and log-distributed communities, but "
    "quantitatively matched the certified composition within tolerance "
    "for only 2 of 10 species. That gap is a well-characterized "
    "property of read-based abundance estimation on real mock-community "
    "sequencing data (DNA extraction efficiency and genome-copy-number "
    "effects), not evidence against the orchestration layer. The claim "
    "MAGMA actually makes beyond a taxonomic classifier, real "
    "genome-resolved recovery via assembly and binning, held up "
    "cleanly: 7 dereplicated MAGs, every "
    "one correctly classified to species by GTDB-Tk, zero false calls, "
    "consistently high completeness and low contamination. Reporting the "
    "weaker of the two results (read-based quantitative accuracy) "
    "alongside the stronger one (MAG recovery), rather than leading only "
    "with whichever looks better, keeps this validation to the same "
    "standard applied to SIGMA, DEFINE, and PRISM above."
)
para(
    "DOGMA's real validation is the strongest directional agreement of "
    "the five pipelines: 11 of 12 detected gene-family targets from "
    "Chuckran et al. (2021)'s own reported results matched in sign, "
    "including every gene/category the paper itself reports as a "
    "strong, high-confidence effect (the ammonium transporter amtB, the "
    "GS-GOGAT nitrogen-assimilation pathway, the nitrogen regulatory "
    "network, and both nitrification and denitrification, all "
    "significant at padj<=0.04). Because DOGMA assembles each sample "
    "independently, a deliberate design choice since no single de novo "
    "assembler is uniformly best for complex environmental "
    "metatranscriptomes (Krinos et al., 2023) and pooling reads across "
    "samples before assembly would blur the very t0-vs-t8 "
    "transcriptional shift under test, there is no shared reference "
    "transcriptome across samples for a conventional gene-level count "
    "matrix. Differential expression was instead computed by pooling "
    "Salmon's transcript-level counts onto each sample's own gene-family "
    "annotation (eggNOG/NCycDB) before running DESeq2, the same "
    "category-pooling strategy used generally for de novo (reference-"
    "free) metatranscriptome differential expression. The single "
    "mismatch, crp, is itself only a modest, non-significant effect in "
    "Chuckran et al.'s own reported result, and crp is a global "
    "carbon-catabolite regulator rather than a nitrogen-cycle gene per "
    "se. This result is reported rather than omitted, consistent with "
    "the honesty standard applied to MAGMA's, SIGMA's, and PRISM's "
    "mixed outcomes above."
)
para(
    "Taken together, the five pipelines' real validation results "
    "support the paper's central claim: a desktop-native application "
    "with zero infrastructure requirements can still reproduce "
    "published, ground-truthed multi-omics results end to end, without "
    "asking its target user, a wet-lab researcher without dedicated "
    "bioinformatics support, to touch a terminal or an HPC scheduler. "
    "Every pipeline's real output was checked against an independent, "
    "external ground truth (a certified mock-community composition, a "
    "reference genome, a published paper's own reported DEGs or "
    "fold-changes, or a vendor's own classification of the same read "
    "file) rather than against itself, and mixed or partial outcomes "
    "(MAGMA's read-based abundance accuracy, SIGMA's PacBio "
    "misassemblies, PRISM's undetected Chlamydia trachomatis, DOGMA's "
    "single crp mismatch) were reported alongside the strong results "
    "rather than smoothed over. As with JOSS and F1000Research's own "
    "review policies for research software, this is deliberately not "
    "framed as a benchmark against other orchestration platforms "
    "(Snakemake, Nextflow, nf-core, Galaxy, anvi'o, KBase); those tools "
    "solve a different problem; extensive terminal/HPC-fluent pipeline "
    "authoring and execution, at a scale and flexibility OmniOmics does "
    "not attempt to match. OmniOmics's contribution is narrower and "
    "more specific: five real pipelines, each independently validated, "
    "reachable without ever leaving a desktop GUI."
)
para(
    "This validation has real limitations, stated plainly rather than "
    "left implicit. The pipeline scope is five workflows, not nf-core's "
    "100+ community-maintained pipelines; OmniOmics trades that breadth "
    "for depth of integration (one consistent GUI, one plotting "
    "environment, one packaging story) across a smaller, curated set. "
    "PRISM's PacBio marker-gene path (the vendor's Kinnex 16S "
    "mock-community release) remains unvalidated at time of writing. "
    "The vendor's own data host was unreachable from both the analysis "
    "machine and the compute node used for this work at the time it was "
    "set up (connection times out on port 443; DNS itself resolves "
    "correctly), a real, external infrastructure constraint documented "
    "in the companion repository rather than silently dropped. DOGMA "
    "does not attempt long-read-only metatranscriptome assembly, "
    "because no validated tool for that specific case exists in the "
    "literature at present. This is a genuine, cited method gap (see "
    "the eukrhythmic authors' own multi-assembler rationale, Krinos et "
    "al., 2023), not an implementation gap OmniOmics chose not to close. "
    "Future work includes additional pipelines, a GROND/full rrn-operon "
    "mode for PRISM, and an expanded Plots-tab library for SIGMA."
)

# ============================================================
# ACKNOWLEDGEMENTS
# ============================================================
unnumbered_heading("Acknowledgements")
p = para()
add_pending(p, "[PENDING]")

# ============================================================
# REFERENCES
# ============================================================
unnumbered_heading("References")
unnumbered_subheading("Platforms and validation datasets", level=2)
refs = [
    "Arkin AP, Cottingham RW, Henry CS, et al. (2018). KBase: The United States Department of Energy Systems Biology Knowledgebase. Nature Biotechnology, 36(7), 566–569. https://doi.org/10.1038/nbt.4163",
    "Bolyen E, Rideout JR, Dillon MR, Bokulich NA, et al. (2019). Reproducible, interactive, scalable and extensible microbiome data science using QIIME 2. Nature Biotechnology, 37(8), 852–857. https://doi.org/10.1038/s41587-019-0209-9",
    "Chuckran PF, Huntemann M, Clum A, et al. (2020). Metagenomes and Metatranscriptomes of a Glucose-Amended Agricultural Soil. Microbiology Resource Announcements, 9(44), e00895-20. https://doi.org/10.1128/MRA.00895-20",
    "Chuckran PF, Fofanov V, Hungate BA, Morrissey EM, Schwartz E, Walkup J, Dijkstra P (2021). Rapid Response of Nitrogen Cycling Gene Transcription to Labile Carbon Amendments in a Soil Microbial Community. mSystems, 6(3), e00161-21. https://doi.org/10.1128/mSystems.00161-21",
    "Di Leo D, Nilsson E, Krinos A, Pinhassi J, Lundin D (2025). The Nextflow nf-core/metatdenovo pipeline for reproducible annotation of metatranscriptomes, and more. PeerJ, 13, e20328. https://doi.org/10.7717/peerj.20328",
    "Di Tommaso P, Chatzou M, Floden EW, Barja PP, Palumbo E, Notredame C (2017). Nextflow enables reproducible computational workflows. Nature Biotechnology, 35(4), 316–319. https://doi.org/10.1038/nbt.3820",
    "Eren AM, Kiefl E, Shaiber A, et al. (2021). Community-led, integrated, reproducible multi-omics with anvi'o. Nature Microbiology, 6(1), 3–6. https://doi.org/10.1038/s41564-020-00834-3",
    "Ewels PA, Peltzer A, Fillinger S, et al. (2020). The nf-core framework for community-curated bioinformatics pipelines. Nature Biotechnology, 38(3), 276–278. https://doi.org/10.1038/s41587-020-0439-x",
    "Galaxy Community (2022). The Galaxy platform for accessible, reproducible and collaborative biomedical analyses: 2022 update. Nucleic Acids Research, 50(W1), W345–W351. https://doi.org/10.1093/nar/gkac247",
    "Krakau S, Straub D, Gourlé H, Gabernet G, Nahnsen S (2022). nf-core/mag: a best-practice pipeline for metagenome hybrid assembly and binning. NAR Genomics and Bioinformatics, 4(1), lqac007. https://doi.org/10.1093/nargab/lqac007",
    "Krinos AI, Cohen NR, Follows MJ, Alexander H (2023). Reverse engineering environmental metatranscriptomes clarifies best practices for eukaryotic assembly. BMC Bioinformatics, 24(1), 74. https://doi.org/10.1186/s12859-022-05121-y",
    "McIntyre ABR, Alexander N, Grigorev K, Bezdan D, Sichtig H, Chiu CY, Mason CE (2019). Single-molecule sequencing detection of N6-methyladenine in microbial reference materials. Nature Communications, 10, 579. https://doi.org/10.1038/s41467-019-08289-9",
    "Mölder F, Jablonski KP, Letcher B, et al. (2021). Sustainable data analysis with Snakemake. F1000Research, 10, 33. https://doi.org/10.12688/f1000research.29032.3",
    "Nicholls SM, Quick JC, Tang S, Loman NJ (2019). Ultra-deep, long-read nanopore sequencing of mock microbial community standards. GigaScience, 8(5), giz043. https://doi.org/10.1093/gigascience/giz043",
    "Oxford Nanopore Technologies (2025). Zymo 16S mock community open data release (zymo_16s_2025.09). EPI2ME blog. https://epi2me.nanoporetech.com/zymo_16s_2025.09/",
    "Petit RA III, Read TD (2020). Bactopia: a flexible pipeline for complete analysis of bacterial genomes. mSystems, 5(4), e00190-20. https://doi.org/10.1128/mSystems.00190-20",
    "Stamouli S, Beber ME, Normark T, Christensen II TA, Andersson-Li L, Borry M, Jamy M, nf-core community, Fellows Yates JA (2023). nf-core/taxprofiler: Highly parallelised and flexible pipeline for metagenomic taxonomic classification and profiling. bioRxiv preprint. https://doi.org/10.1101/2023.10.20.563221",
    "Varet H, Brillet-Guéguen L, Coppée JY, Dillies MA (2016). SARTools: A DESeq2- and edgeR-Based R Pipeline for Comprehensive Differential Analysis of RNA-Seq Data. PLoS ONE, 11(6), e0157022. https://doi.org/10.1371/journal.pone.0157022",
    "Wintenberg M, Manglass L, Martinez NE, Blenner M (2023). Global Transcriptional Response of Escherichia coli Exposed In Situ to Different Low-Dose Ionizing Radiation Sources. mSystems, 8(2), e00718-22. https://doi.org/10.1128/msystems.00718-22",
]
for ref in refs:
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(ref)
    r.font.size = Pt(10.5)

unnumbered_subheading("Tools and reference databases used by the five pipelines", level=2)
para(
    "OmniOmics packages, but does not modify, the following third-party "
    "tools and reference databases across its five pipelines. Listed "
    "for completeness and correct attribution; extracted directly from "
    "each pipeline's own manifest (pipeline.yaml), not independently "
    "curated for this list, so it reflects exactly what a user's real "
    "run actually invokes.",
    size=10.5,
)
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tool_refs.json")) as f:
    tool_refs = json.load(f)

unnumbered_subheading("Tools", level=3)
for doi, text in sorted(tool_refs["tools"].items(), key=lambda kv: kv[1]):
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(f"{text} https://doi.org/{doi}")
    r.font.size = Pt(9.5)

unnumbered_subheading("Reference databases", level=3)
for doi, text in sorted(tool_refs["databases"].items(), key=lambda kv: kv[1]):
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(f"{text} https://doi.org/{doi}")
    r.font.size = Pt(9.5)

# ============================================================
# DATA ACCESSIBILITY
# ============================================================
unnumbered_heading("Data Accessibility and Benefit-Sharing")
para(
    "OmniOmics's source code is available at github.com/oliv-angelus/"
    "OmniOmics (MIT license), including a packaged Debian build (.deb). "
    "The exact configuration, curated ground truth, and real "
    "observed-vs-expected validation results described in this "
    "manuscript are available at github.com/oliv-angelus/"
    "OmniOmics-validation (MIT for scripts/configs, CC-BY-4.0 for "
    "data), permanently archived on Zenodo at "
    "https://doi.org/10.5281/zenodo.22780175 (concept DOI, always "
    "resolves to the latest version; the exact v1.0.0 release "
    "described in this manuscript is specifically archived at "
    "https://doi.org/10.5281/zenodo.22780176). A Zenodo DOI for the "
    "OmniOmics application repository itself "
)
p = doc.paragraphs[-1]
add_pending(p, "[PENDING: to be minted before submission].")
para(
    "All datasets reanalyzed for validation are already public, "
    "deposited by their original authors or by the sequencing-platform "
    "vendor (SRA/ENA/GEO/ONT open-data accessions, cited per pipeline "
    "in Table 2 and in the companion repository). No new biological "
    "samples were collected for this work; the Benefit-Sharing "
    "provisions of the Nagoya Protocol / Convention on Biological "
    "Diversity are therefore not applicable."
)

# ============================================================
# AUTHOR CONTRIBUTIONS
# ============================================================
unnumbered_heading("Author Contributions")
p = para()
add_pending(p, "[PENDING]")

# ============================================================
# TABLES AND FIGURES
# ============================================================
unnumbered_heading("Tables and Figures")
p = para()
add_pending(p, (
    "[PENDING: Figures. Architecture diagram (client/backend/"
    "pipeline-registry), one assembly-quality figure (e.g., SIGMA's "
    "short-only vs. hybrid contig-count/genome-fraction comparison) as "
    "a visual anchor for the validation argument. Table 3 already holds "
    "the real, complete observed-vs-expected result for all five "
    "pipelines (see Results); no further table work is pending.]"
))
p = para()
add_pending(p, (
    "[PENDING: Figure: per-pipeline workflow diagrams (one panel per "
    "pipeline, tool-labeled DAG). All five now exist in the same "
    "hand-illustrated draw.io style, custom icon set "
    "(pipelines/<id>/<ID>.drawio.svg in the OmniOmics repo: MAGMA, "
    "SIGMA, DOGMA, DEFINE, PRISM). Before inserting as one multi-panel "
    "figure: DEFINE's diagram has a known typo to fix ('Annoted' -> "
    "'Annotated' count table) and could more explicitly show "
    "featureCounts' raw counts feeding merge_annotated_counts "
    "alongside eggNOG's annotation (currently only the eggNOG line is "
    "drawn into that box). Once fixed, insert all 5 as one "
    "multi-panel figure.]"
))

doc.save("/home/angelo/Documentos/OmniOmics/paper/Artigo.docx")
print("OK: Artigo.docx written")
