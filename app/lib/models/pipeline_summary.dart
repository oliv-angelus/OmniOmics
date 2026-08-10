class PipelineSummary {
  final String id;
  final String name;
  final String description;
  final String category;
  final String icon;
  /// Extra descriptive tags beyond the one omics category -- e.g. SIGMA also
  /// carries "prokaryote" since it isn't scoped by omics layer alone.
  final List<String> tags;

  const PipelineSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.icon,
    this.tags = const [],
  });

  factory PipelineSummary.fromJson(Map<String, dynamic> json) => PipelineSummary(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        tags: (json['tags'] as List?)?.map((e) => e as String).toList() ?? const [],
      );
}
