"""Detects which Plots-tab input shapes a folder on disk can actually produce.

Why this exists: the Plots tab lists runs from runs_store, i.e. from
~/.omniomics.json. A results folder that the app never recorded -- a run
produced on another machine, a settings file that was lost or reset, output
copied from a cluster, or a table a user built entirely outside OmniOmics --
is invisible to it, even though the data is sitting right there. This module
is what lets the app look at an arbitrary directory and answer "what can I
plot from this?".

DESIGN CONSTRAINT, and the reason each probe is written the way it is: a
detector must match what the LOADER ACTUALLY OPENS, not merely something that
looks related. Detecting a shape the loader then fails to build is worse than
detecting nothing, because it moves the failure from a clear "nothing usable
here" message to an opaque R error several steps later. So every pattern below
is the same pattern its loader uses (io_helpers.R's find_input_file for the
table-shaped ones, the .discover_* functions in lib/build_*.R for the ones
that walk a directory tree), and any file that must be non-empty to be usable
is checked for that here too.

The scan is deliberately shallow in cost and complete in coverage: one
os.walk of the folder, then every probe answered from that single listing.
"""
import os

# Where a run's real outputs live relative to what the user points at. A
# pipeline run directory contains results/, but a user who points AT the
# results directory itself (or at a bare folder holding one exported table)
# is doing something reasonable, so both are accepted.
_RESULTS_SUBDIR = "results"


def _walk_index(root: str) -> list:
    """Every file under `root`, as (absolute_path, basename, size). One walk,
    reused by every probe -- a results tree can hold tens of thousands of
    files and re-globbing per shape would make the scan visibly slow."""
    out = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            out.append((full, name, size))
    return out


def _find(index, *, name=None, suffix=None, path_contains=None, non_empty=True):
    """First file in `index` matching the given constraints, or None.

    `path_contains` disambiguates the case where a basename genuinely occurs
    more than once in a real run tree -- PRISM writes prism_abundance_table.tsv
    in three places, two of which can be empty placeholders. It mirrors
    find_input_file's own `prefer` argument, except that here a match is
    required rather than preferred, since this function answers "is the file
    the loader will open present", not "which of several to use".
    """
    for full, base, size in index:
        if name is not None and base != name:
            continue
        if suffix is not None and not base.endswith(suffix):
            continue
        if path_contains is not None and path_contains not in full:
            continue
        if non_empty and size == 0:
            continue
        return full
    return None


def _find_preferred(index, *, name, prefer, non_empty=True):
    """find_input_file's real semantics: any match will do, but a path
    containing `prefer` wins. PRISM's select_abundance_table copy is the
    unconditionally-correct one; the denoiser's own copies include an empty
    placeholder for whichever platform did not run."""
    hit = _find(index, name=name, path_contains=prefer, non_empty=non_empty)
    return hit or _find(index, name=name, non_empty=non_empty)


# --- Per-shape probes ------------------------------------------------------
#
# Each returns the path that proves the shape is buildable, or None. Signature
# is (index, root) so a probe can walk directory structure when a single file
# is not enough evidence (magma_mags, sigma_genomes).

def _probe_phyloseq_magma(index, root):
    return _find(index, name="abundance_table_final_RAW.tsv")


def _probe_phyloseq_kaiju(index, root):
    return _find(index, name="abundance_table_final_kaiju_RAW.tsv")


def _probe_phyloseq_prism(index, root):
    return _find_preferred(index, name="prism_abundance_table.tsv",
                           prefer=os.sep + "05_ABUNDANCE_TABLE" + os.sep)


def _probe_phyloseq_custom(index, root):
    """The documented drop-in name for a community table built outside any
    OmniOmics pipeline -- see docs/plot_input_formats.md. Same `tax` + one
    column per sample shape build_phyloseq.R already reads; only the filename
    is a new contract."""
    return _find(index, name="omniomics_abundance_table.tsv")


def _probe_count_matrix(index, root):
    return (_find(index, name="contagem_anotada.tsv")
            or _find(index, name="omniomics_count_matrix.tsv"))


def _probe_dogma(index, root):
    return _find(index, suffix="_transdecoder.pep")


def _probe_sigma(index, root):
    # .discover_sigma_samples keys off CheckM2's per-sample report, under
    # 05_QUALITY specifically -- the basename alone is not enough, MAGMA's
    # CheckM2 output would otherwise match.
    return _find(index, name="quality_report.tsv",
                 path_contains=os.sep + "05_QUALITY" + os.sep)


def _probe_magma_mags(index, root):
    # .discover_mags: the dereplicated pool first, per-sample refinement as
    # the fallback for a run stopped before 07_DEREP.
    hit = _find(index, path_contains=os.sep + "all_hq_mags" + os.sep)
    if hit and hit.endswith((".fa", ".fna", ".fasta")):
        return hit
    for full, base, size in index:
        if os.sep + "06_MAG_REFINEMENT" + os.sep in full and base.endswith((".fa", ".fna", ".fasta")) and size > 0:
            return full
    return None


def _probe_magma_qc(index, root):
    # Either QC tool is enough -- build_magma_qc_table reads whichever ran for
    # each sample's read type, and MetaQuast feeds the assembly half.
    return (_find(index, suffix="_fastp.json")
            or _find(index, name="NanoStats.txt")
            or _find(index, name="transposed_report.tsv",
                     path_contains=os.sep + "02_ASSEMBLY" + os.sep))


def _probe_magma_functional(index, root):
    return _find(index, suffix="_annotations.emapper.annotations",
                 path_contains=os.sep + "09_ANNOTATION" + os.sep)


# Ordered so the most specific pipeline signature is tested first. A folder is
# attributed to exactly ONE pipeline -- the analyses offered come from that
# pipeline's applies_to, and mixing two pipelines' outputs in one folder is
# not a real situation worth guessing at.
PIPELINE_PROBES = [
    ("sigma",  _probe_sigma,          "CheckM2 per-genome quality report under 05_QUALITY"),
    ("dogma",  _probe_dogma,          "TransDecoder ORF predictions (*_transdecoder.pep)"),
    ("define", _probe_count_matrix,   "annotated count table (contagem_anotada.tsv)"),
    ("magma",  _probe_phyloseq_magma, "consolidated community table (abundance_table_final_RAW.tsv)"),
    ("prism",  _probe_phyloseq_prism, "amplicon abundance table (prism_abundance_table.tsv)"),
]

# Which shapes to probe once a pipeline has been identified. Keyed the same way
# main.py's INPUT_SHAPE_INFO is, so the result feeds straight into the existing
# load flow with no translation.
SHAPE_PROBES = {
    "magma": {
        "phyloseq": _probe_phyloseq_magma,
        "phyloseq_kaiju": _probe_phyloseq_kaiju,
        "magma_mags": _probe_magma_mags,
        "magma_qc": _probe_magma_qc,
        "magma_functional": _probe_magma_functional,
    },
    "prism":  {"phyloseq": _probe_phyloseq_prism},
    "dogma":  {"dogma_annotated": _probe_dogma},
    "define": {"count_matrix": _probe_count_matrix},
    "sigma":  {"sigma_genomes": _probe_sigma},
    # Data produced outside any pipeline, via the documented drop-in filenames.
    # Offered MAGMA's phyloseq-shaped analyses, which are the ones that need
    # nothing but a community table.
    "custom": {"phyloseq": _probe_phyloseq_custom, "count_matrix": _probe_count_matrix},
}

# A "custom" folder is not a pipeline, so it has no applies_to of its own.
# These are the pipelines whose analyses each generic shape can serve.
CUSTOM_SHAPE_PIPELINE = {"phyloseq": "prism", "count_matrix": "define"}


def resolve_results_dir(folder: str) -> str:
    """The directory the loaders should actually be pointed at.

    A pipeline run directory holds results/; the loaders are always given that
    subdirectory. Users legitimately point at either level (or at a bare folder
    with one exported table), so both are accepted and normalised here rather
    than being made the user's problem.
    """
    nested = os.path.join(folder, _RESULTS_SUBDIR)
    return nested if os.path.isdir(nested) else folder


def scan_folder(folder: str) -> dict:
    """What can be plotted from `folder`.

    Returns {ok, results_dir, pipeline_id, detected_by, shapes: {name: path},
    missing_shapes: [name], reason} -- `ok` False with a `reason` when nothing
    usable was found, so the caller can show the user why rather than an empty
    list.
    """
    if not folder or not os.path.isdir(folder):
        return {"ok": False, "reason": "not_a_directory", "results_dir": folder}

    results_dir = resolve_results_dir(folder)
    index = _walk_index(results_dir)
    if not index:
        return {"ok": False, "reason": "empty_directory", "results_dir": results_dir}

    pipeline_id, detected_by, detected_path = None, None, None
    for pid, probe, description in PIPELINE_PROBES:
        hit = probe(index, results_dir)
        if hit:
            pipeline_id, detected_by, detected_path = pid, description, hit
            break

    if pipeline_id is None:
        # Fall back to the documented generic filenames before giving up --
        # this is the "I made this table myself" path.
        for shape, probe in SHAPE_PROBES["custom"].items():
            hit = probe(index, results_dir)
            if hit:
                pipeline_id = "custom"
                detected_by = f"OmniOmics generic input ({os.path.basename(hit)})"
                detected_path = hit
                break

    if pipeline_id is None:
        return {"ok": False, "reason": "no_recognised_input", "results_dir": results_dir,
                "n_files": len(index)}

    shapes, missing = {}, []
    for shape, probe in SHAPE_PROBES[pipeline_id].items():
        hit = probe(index, results_dir)
        if hit:
            shapes[shape] = os.path.relpath(hit, results_dir)
        else:
            missing.append(shape)

    return {
        "ok": True,
        "results_dir": results_dir,
        "pipeline_id": pipeline_id,
        "detected_by": detected_by,
        "detected_path": os.path.relpath(detected_path, results_dir),
        "shapes": shapes,
        "missing_shapes": missing,
        "n_files": len(index),
    }
