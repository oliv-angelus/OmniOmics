import 'manifest_i18n.dart';

/// One parameter of a Plots-tab analysis, from plots/manifest.yaml. Same
/// type/default/min/max/choices/description{en,pt} shape as ToolFlag (see
/// tool.dart) -- deliberately a separate class rather than reusing ToolFlag,
/// since a plot analysis parameter isn't a Snakemake CLI flag toggle (no
/// enabledByDefault-as-checkbox semantics; every parameter here is just a
/// named value passed to Rscript, see plots_engine.build_params_args).
class PlotParam {
  final String flag;
  // int | float | bool | str | choice | column | level | tax_rank | sample -- // the last four are Plots-tab-specific (see plots/manifest.yaml's header
  // comment): "column" is populated from the loaded metadata table's real
  // column names, "level" from the real values found in whichever column is
  // currently selected for [dependsOn], "tax_rank" from the real taxonomic
  // ranks the loaded data actually has (PlotLoadedData.taxRanks) -- not a
  // fixed choices: [...] list, since which ranks exist (Kingdom present or
  // not, Species available or not,...) genuinely depends on the user's own
  // reference database (see load_phyloseq.R's build_phyloseq call).
  // "sample" is populated from the real per-genome/sample identifiers the
  // run actually has (PlotLoadedData.samples) -- for pipelines like SIGMA
  // where an analysis works on ONE selected genome at a time out of
  // however many the run assembled, not a dropdown of metadata VALUES the
  // way "level" is (there's no metadata column being depended on; the
  // sample identity is a fixed fact about the run itself).
  final String type;
  final dynamic defaultValue;
  final String description;
  final num? min;
  final num? max;
  final List<String>? choices;
  /// For type == 'level': the flag of the "column"-type parameter whose
  /// selected value determines this parameter's own choices (e.g.
  /// reference_group depends_on group_var).
  final String? dependsOn;
  /// For type == 'tax_rank' only: prepend a synthetic "all" choice (one
  /// figure per rank at once -- taxonomic_composition's own default) ahead
  /// of the real detected ranks.
  final bool includeAll;
  /// For type == 'tax_rank' only: append a synthetic "ASV" choice (skip
  /// aggregation entirely, plot at the raw ASV/OTU level) after the real
  /// detected ranks.
  final bool includeAsv;

  PlotParam({
    required this.flag,
    required this.type,
    required this.defaultValue,
    required this.description,
    this.min,
    this.max,
    this.choices,
    this.dependsOn,
    this.includeAll = false,
    this.includeAsv = false,
  });

  factory PlotParam.fromJson(Map<String, dynamic> json, [String lang = 'en']) => PlotParam(
        flag: json['flag'] as String,
        type: json['type'] as String? ?? 'str',
        defaultValue: json['default'],
        description: localizedManifestText(json['description'], lang),
        min: json['min'] as num?,
        max: json['max'] as num?,
        choices: (json['choices'] as List?)?.map((e) => e.toString()).toList(),
        dependsOn: json['depends_on'] as String?,
        includeAll: json['include_all'] as bool? ?? false,
        includeAsv: json['include_asv'] as bool? ?? false,
      );
}

class PlotAnalysis {
  final String id;
  final String name;
  final String description;
  final List<String> appliesTo;
  final String inputShape; // phyloseq | count_matrix
  final List<PlotParam> parameters;
  /// False for analyses still backed by _stub_common.R (no real statistics,
  /// no preview.png yet) -- see plots/manifest.yaml's header comment. Drives
  /// the "Em breve" de-emphasized card treatment in the analyses list,
  /// mirroring the Hub's own not-yet-built-pipeline cards.
  final bool implemented;

  PlotAnalysis({
    required this.id,
    required this.name,
    required this.description,
    required this.appliesTo,
    required this.inputShape,
    required this.parameters,
    this.implemented = true,
  });

  factory PlotAnalysis.fromJson(Map<String, dynamic> json, [String lang = 'en']) => PlotAnalysis(
        id: json['id'] as String,
        name: localizedManifestText(json['name'], lang),
        description: localizedManifestText(json['description'], lang),
        appliesTo: (json['applies_to'] as List? ?? const []).map((e) => e.toString()).toList(),
        inputShape: json['input_shape'] as String? ?? 'phyloseq',
        parameters: (json['parameters'] as List? ?? const []).map((e) => PlotParam.fromJson(e as Map<String, dynamic>, lang)).toList(),
        implemented: json['implemented'] as bool? ?? true,
      );
}
