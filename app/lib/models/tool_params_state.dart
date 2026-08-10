import 'tool.dart';

/// Per-tool editable flag state for the Launch screen's tool cards. Mutable
/// and held by reference in LaunchScreen -- child widgets mutate it in place
/// and call a callback to trigger a rebuild, avoiding threading a dozen
/// granular callbacks down through the widget tree.
class ToolParamsState {
  final Set<String> enabledFlags = {};
  final Map<String, String> flagValues = {};
  String extraParams = '';
  bool showAdvanced = false;
  bool expanded = false;

  ToolParamsState.fromDefaults(ToolDef tool) {
    for (final flag in tool.flags) {
      if (flag.enabledByDefault) enabledFlags.add(flag.flag);
      if (flag.defaultValue != null) flagValues[flag.flag] = flag.defaultValue.toString;
    }
  }
}

/// Mirrors the backend's tools_engine.build_params_string exactly, so the
/// assembled CLI string the user sees matches what config.yaml will contain.
String buildToolParamsString(ToolDef tool, ToolParamsState state) {
  final parts = <String>[];
  for (final flag in tool.flags) {
    if (!state.enabledFlags.contains(flag.flag)) continue;
    if (flag.type == 'bool') {
      parts.add(flag.flag);
    } else {
      final val = state.flagValues[flag.flag] ?? flag.defaultValue?.toString ?? '';
      if (val.isNotEmpty) parts.add('${flag.flag} $val');
    }
  }
  final assembled = parts.join(' ');
  final extra = state.extraParams.trim;
  return [assembled, extra].where((s) => s.isNotEmpty).join(' ');
}
