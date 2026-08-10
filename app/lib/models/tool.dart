import 'manifest_i18n.dart';

class ToolFlag {
  final String flag;
  final String type; // int | float | bool | str | choice
  final dynamic defaultValue;
  final bool enabledByDefault;
  final String description;
  final num? min;
  final num? max;
  final List<String>? choices;

  ToolFlag({
    required this.flag,
    required this.type,
    required this.defaultValue,
    required this.enabledByDefault,
    required this.description,
    this.min,
    this.max,
    this.choices,
  });

  factory ToolFlag.fromJson(Map<String, dynamic> json, [String lang = 'en']) => ToolFlag(
        flag: json['flag'] as String,
        type: json['type'] as String? ?? 'str',
        defaultValue: json['default'],
        enabledByDefault: json['enabled'] as bool? ?? false,
        description: localizedManifestText(json['description'], lang),
        min: json['min'] as num?,
        max: json['max'] as num?,
        choices: (json['choices'] as List?)?.map((e) => e.toString()).toList(),
      );
}

/// "At least [min] of [tools] must be active" -- a plain single dependency is
/// {tools: [x], min: 1}; an OR-group ("any assembler") is {tools: [...], min: 1};
/// a threshold group ("at least 2 binners") is {tools: [...], min: 2}.
class RequirementGroup {
  final List<String> tools;
  final int min;
  const RequirementGroup({required this.tools, required this.min});

  factory RequirementGroup.fromJson(Map<String, dynamic> json) => RequirementGroup(
        tools: (json['tools'] as List? ?? const []).map((e) => e.toString()).toList(),
        min: json['min'] as int? ?? 1,
      );

  bool satisfiedBy(Set<String> activeTools) => tools.where(activeTools.contains).length >= min;
}

class ToolDef {
  final String id;
  final String name;
  final String description;
  final String category;
  final String readType; // short | long | hybrid | all
  final List<RequirementGroup> requires;
  final List<String> ruleNames; // actual Snakemake rule name(s), for --omit-from
  final List<ToolFlag> flags;
  /// Track name ("sample" | "mags") -> the rule(s) that make up that track.
  /// Empty for tools that only run on one track (or aren't track-based at
  /// all) -- e.g. Prodigal/antiSMASH/eggNOG run separately on per-sample
  /// contigs *and* on dereplicated MAGs, so each track can be toggled on its
  /// own instead of one blanket switch for both.
  final Map<String, List<String>> tracks;

  /// Whether this tool starts active when the Launch screen opens with no saved
  /// draft. Defaults to true (every tool active) -- set false in the manifest
  /// for tools that should be opt-in, e.g. DOGMA's Trinity (heavy, and its
  /// conda env is fragile), which stays available but off by default so the
  /// working rnaSPAdes+MEGAHIT ensemble is the out-of-the-box path.
  final bool activeByDefault;

  ToolDef({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.readType,
    required this.requires,
    required this.ruleNames,
    required this.flags,
    this.tracks = const {},
    this.activeByDefault = true,
  });

  factory ToolDef.fromJson(Map<String, dynamic> json, [String lang = 'en']) => ToolDef(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        description: localizedManifestText(json['description'], lang),
        category: json['category'] as String? ?? 'Other',
        readType: json['read_type'] as String? ?? 'all',
        requires: (json['requires'] as List? ?? const []).map((e) => RequirementGroup.fromJson(e as Map<String, dynamic>)).toList(),
        ruleNames: (json['rule_names'] as List? ?? const []).map((e) => e.toString()).toList(),
        flags: (json['flags'] as List? ?? const []).map((e) => ToolFlag.fromJson(e as Map<String, dynamic>, lang)).toList(),
        tracks: (json['tracks'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, (v as List).map((e) => e.toString()).toList())),
        activeByDefault: json['active_by_default'] as bool? ?? true,
      );
}

class ToolCategory {
  final String category;
  final List<ToolDef> tools;

  ToolCategory({required this.category, required this.tools});

  factory ToolCategory.fromJson(Map<String, dynamic> json, [String lang = 'en']) => ToolCategory(
        category: json['category'] as String,
        tools: (json['tools'] as List? ?? const []).map((e) => ToolDef.fromJson(e as Map<String, dynamic>, lang)).toList(),
      );
}
