/// Shared picker for manifest-authored text fields (tool/flag/database
/// descriptions in `pipelines/*/pipeline.yaml`) that carry a translation --
/// either a plain string (legacy/not yet translated, shown as-is regardless
/// of [lang]) or a `{"pt": "...", "en": "..."}` object.
String localizedManifestText(dynamic raw, String lang) {
  if (raw is Map) return (raw[lang] as String?) ?? (raw['en'] as String?) ?? '';
  return raw as String? ?? '';
}
