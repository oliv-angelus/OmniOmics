/// Result of POST /api/plots/load: the cached data object built once for a
/// run + metadata combination, plus the metadata's real column names and
/// each column's detected values -- lets the parameter form render
/// group_var/reference_group as real dropdowns (see PlotParam's "column"/
/// "level" types) instead of free-text boxes. Every analysis run against
/// this run then reuses [dataRds] instead of re-parsing the raw tables.
///
/// [dataRds] is deliberately generic, not "phyloseqRds" -- which loader
/// actually built it (and what kind of R object it is) depends on the
/// parent run's pipeline (see plots_engine.get_input_shape_for_pipeline):
/// MAGMA-family runs get a real phyloseq object, DEFINE runs get a plain
/// counts+annotation+coldata bundle. The Flutter side never opens the file
/// itself -- it's just a path handed back to whichever analysis script
/// needs it -- so one field name covers both.
class PlotLoadedData {
  final String dataRds;
  final List<String> columns;
  final Map<String, List<String>> columnLevels;
  /// The real taxonomic ranks THIS data actually has, in real hierarchical
  /// order (e.g. Domain/Phylum/.../Species for GTDB, or with Kingdom too
  /// for Kraken2/NCBI -- see load_phyloseq.R's build_phyloseq call) -- /// lets --rank parameters (PlotParam's "tax_rank" type) render every
  /// level the user's own data supports instead of a fixed, potentially
  /// incomplete hardcoded list. Always empty for count_matrix-shaped runs
  /// (DEFINE) -- genes aren't taxonomically ranked.
  final List<String> taxRanks;
  /// The real per-genome/sample identifiers THIS run actually has -- e.g.
  /// SIGMA's own genome names, one per isolate assembled in the run. Lets
  /// --genome-style parameters (PlotParam's "sample" type) render a real
  /// dropdown of what genomes exist in this specific run, since (unlike
  /// group_var/reference_group, which pick among a user-supplied metadata
  /// column's values) there is no metadata column to depend on here -- the
  /// sample/genome identity is a fixed, always-available fact about the run
  /// itself, not something the user's own metadata.tsv defines. Empty for
  /// every pipeline that doesn't need a "which one of several run outputs"
  /// picker (MAGMA/PRISM/DOGMA/DEFINE all analyze every sample together).
  final List<String> samples;

  PlotLoadedData({
    required this.dataRds,
    required this.columns,
    required this.columnLevels,
    required this.taxRanks,
    this.samples = const [],
  });

  factory PlotLoadedData.fromJson(Map<String, dynamic> json) => PlotLoadedData(
        dataRds: json['data_rds'] as String,
        columns: (json['columns'] as List).map((e) => e.toString).toList,
        columnLevels: (json['column_levels'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as List).map((e) => e.toString).toList),
        ),
        taxRanks: (json['tax_ranks'] as List? ?? const []).map((e) => e.toString).toList,
        samples: (json['samples'] as List? ?? const []).map((e) => e.toString).toList,
      );
}
