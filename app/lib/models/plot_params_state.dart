import 'plot_analysis.dart';

/// Per-analysis editable parameter values for the Plots tab's run form.
/// Simpler than ToolParamsState (tool_params_state.dart): every analysis
/// parameter in plots/manifest.yaml is always "enabled" (there's no opt-in
/// CLI-flag toggle like a pipeline tool's flags have -- see plots_engine.py's
/// build_params_args, which still accepts an `enabled` field per state for
/// symmetry with tools_engine's schema, but this form always sends true).
class PlotParamsState {
  final Map<String, String> values = {};

  PlotParamsState.fromDefaults(PlotAnalysis analysis) {
    for (final p in analysis.parameters) {
      if (p.defaultValue != null) values[p.flag] = p.defaultValue.toString;
    }
  }

  /// Matches the shape plots_engine.build_params_args expects: a list of
  /// {flag, enabled, value} states.
  List<Map<String, dynamic>> toApiParameters(PlotAnalysis analysis) {
    return analysis.parameters.map((p) => {
              'flag': p.flag,
              'enabled': true,
              'value': values[p.flag] ?? p.defaultValue?.toString ?? '',
            }).toList;
  }

  /// A parameter with an empty-string default (legacy free-text required
  /// fields) or of type "column"/"level" (always dropdown-selected, never
  /// defaulted -- see PlotParam's docstring) is treated as required. True
  /// once every such parameter has been filled in.
  bool isComplete(PlotAnalysis analysis) {
    for (final p in analysis.parameters) {
      final required = p.defaultValue == '' || p.type == 'column' || p.type == 'level';
      if (required && (values[p.flag] ?? '').trim.isEmpty) return false;
    }
    return true;
  }
}
