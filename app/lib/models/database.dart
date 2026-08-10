import 'manifest_i18n.dart';

class DownloadOption {
  final String id;
  final String label;
  final String description;
  final String? url;
  final bool vibrantSetup;

  DownloadOption({
    required this.id,
    required this.label,
    required this.description,
    this.url,
    this.vibrantSetup = false,
  });

  factory DownloadOption.fromJson(Map<String, dynamic> json, [String lang = 'en']) => DownloadOption(
        id: json['id'] as String,
        label: json['label'] as String,
        description: localizedManifestText(json['description'], lang),
        url: json['url'] as String?,
        vibrantSetup: json['vibrant_setup'] as bool? ?? false,
      );
}

class DatabaseDef {
  final String key;
  final String name;
  final String description;
  final String settingKey;
  final String? configKey;
  final num sizeGb;
  final List<DownloadOption> downloadOptions;
  final String? path;
  final bool configured;
  /// Which pipeline IDs reference this database -- only populated from the
  /// Hub-level /api/databases aggregation (null for the per-pipeline
  /// /api/pipelines/{pid}/databases response, which is scoped to one already).
  final List<String>? usedBy;

  DatabaseDef({
    required this.key,
    required this.name,
    required this.description,
    required this.settingKey,
    required this.configKey,
    required this.sizeGb,
    required this.downloadOptions,
    required this.path,
    required this.configured,
    this.usedBy,
  });

  factory DatabaseDef.fromJson(String key, Map<String, dynamic> json, [String lang = 'en']) => DatabaseDef(
        key: key,
        name: json['name'] as String? ?? key,
        description: localizedManifestText(json['description'], lang),
        settingKey: json['setting_key'] as String,
        configKey: json['config_key'] as String?,
        sizeGb: json['size_gb'] as num? ?? 0,
        downloadOptions: (json['download_options'] as List? ?? const []).map((e) => DownloadOption.fromJson(e as Map<String, dynamic>, lang)).toList,
        path: json['path'] as String?,
        configured: json['configured'] as bool? ?? false,
        usedBy: (json['used_by'] as List?)?.map((e) => e.toString).toList,
      );
}
