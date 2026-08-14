class PipelineSummary {
  final String id;
  final String name;
  final String description;
  final String category;
  final String icon;
  /// Extra descriptive tags beyond the one omics category -- e.g. SIGMA also
  /// carries "prokaryote" since it isn't scoped by omics layer alone.
  final List<String> tags;

  /// The pipeline's ordered stage names, straight from the manifest's
  /// `categories`. Drives the step track on the Hub card: one segment per
  /// stage, so the depth difference between pipelines (DEFINE 5, SIGMA 14) is
  /// visible at a glance rather than hidden behind a fixed number of icons.
  final List<String> steps;

  const PipelineSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.icon,
    this.tags = const [],
    this.steps = const [],
  });

  factory PipelineSummary.fromJson(Map<String, dynamic> json) => PipelineSummary(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        tags: (json['tags'] as List?)?.map((e) => e as String).toList() ?? const [],
        // Absent on a manifest that predates `categories` -- an empty track is
        // rendered as nothing rather than blocking the card.
        steps: (json['categories'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      );
}
