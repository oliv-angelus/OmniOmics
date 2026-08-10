import 'package:flutter/material.dart';
import '../models/plot_analysis.dart';
import '../models/plot_loaded_data.dart';
import '../models/plot_params_state.dart';
import '../theme/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Parameter form for a Plots-tab analysis -- same type-dispatch shape as
/// ToolCategorySection's _FlagRow/_FlagValueInput (tool_category_section.dart)
/// but simpler: every parameter is always sent (no per-flag enable checkbox,
/// see PlotParamsState's docstring), so this is just label + description +
/// value input per row, with a required-field marker for parameters that
/// have no sensible default (empty-string default, or the "column"/"level"
/// types below).
///
/// "column" and "level" parameters (group_var, reference_group,...) are
/// dropdowns fed by [loadedData] -- the real metadata column names and their
/// real detected values, from POST /api/plots/load -- rather than free
/// text: the value has to be one that actually occurs in the table.
class PlotParamForm extends ConsumerWidget {
  final PlotAnalysis analysis;
  final PlotParamsState state;
  final PlotLoadedData loadedData;
  final VoidCallback onChanged;

  const PlotParamForm({
    super.key,
    required this.analysis,
    required this.state,
    required this.loadedData,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in analysis.parameters)
          _PlotParamRow(param: p, state: state, loadedData: loadedData, onChanged: onChanged),
      ],
    );
  }
}

class _PlotParamRow extends StatelessWidget {
  final PlotParam param;
  final PlotParamsState state;
  final PlotLoadedData loadedData;
  final VoidCallback onChanged;

  const _PlotParamRow({required this.param, required this.state, required this.loadedData, required this.onChanged});

  String get _label => param.flag.replaceFirst(RegExp(r'^--'), '');
  bool get _required => param.defaultValue == '' || param.type == 'column' || param.type == 'level' || param.type == 'sample';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final missing = _required && (state.values[param.flag] ?? '').trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                    if (_required) Text(' *', style: TextStyle(fontSize: 12.5, color: colors.statusError, fontWeight: FontWeight.w700)),
                  ],
                ),
                Text(param.description, style: TextStyle(fontSize: 11, color: colors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 180,
            child: _PlotParamValueInput(param: param, state: state, loadedData: loadedData, missing: missing, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class _PlotParamValueInput extends StatelessWidget {
  final PlotParam param;
  final PlotParamsState state;
  final PlotLoadedData loadedData;
  final bool missing;
  final VoidCallback onChanged;

  const _PlotParamValueInput({
    required this.param,
    required this.state,
    required this.loadedData,
    required this.missing,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = state.values[param.flag] ?? param.defaultValue?.toString() ?? '';

    if (param.type == 'bool') {
      final on = current.toLowerCase() == 'true';
      return Align(
        alignment: Alignment.centerRight,
        child: Switch(
          value: on,
          onChanged: (v) {
            state.values[param.flag] = v.toString();
            onChanged();
          },
        ),
      );
    }

    if (param.type == 'column') {
      return _dropdown(current, loadedData.columns, hintOnEmpty: true);
    }

    if (param.type == 'sample') {
      // Real per-genome/sample identifiers this run actually has (see
      // PlotLoadedData.samples's own docstring for why this is a distinct
      // mechanism from "column"/"level" -- no metadata column involved,
      // just "which of the run's own outputs to work with").
      return _dropdown(current, loadedData.samples, hintOnEmpty: true);
    }

    if (param.type == 'level') {
      final dependsOnValue = param.dependsOn != null ? state.values[param.dependsOn]: null;
      final levels = (dependsOnValue != null ? loadedData.columnLevels[dependsOnValue]: null) ?? const <String>[];
      // A previously-picked level survives in `state.values` even after its
      // depended-on column changes underneath it (e.g. group_var edited in
      // the "Personalizar" panel) -- _dropdown below already shows this as
      // blank (options.contains(current) is false), but the STORED value
      // was never actually cleared, so a "Replotar" would silently resend
      // the old, now-invalid level instead of the form correctly demanding
      // a fresh pick. Without this, replotting after changing group_var
      // sends a stale reference_group and the R script's own validation
      // rejects it a few lines into the run. Clearing it
      // (scheduled post-frame -- this runs during build, and
      // onChanged triggers a setState) makes the "required" marker and
      // toApiParameters both see the truth.
      if (current.isNotEmpty && !levels.contains(current)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          state.values[param.flag] = '';
          onChanged();
        });
      }
      return _dropdown(current, levels, hintOnEmpty: true);
    }

    if (param.type == 'choice' && param.choices != null) {
      return _dropdown(current, param.choices!, hintOnEmpty: false);
    }

    if (param.type == 'tax_rank') {
      // Real ranks the loaded data actually has (Domain/Kingdom/.../Species
      // as detected server-side, see PlotLoadedData.taxRanks), not a fixed
      // manifest choices: [...] list -- which levels exist genuinely
      // depends on the user's own reference database. includeAll/includeAsv
      // add the two synthetic, non-taxonomic options some analyses offer
      // alongside the real ranks (see PlotParam's docstring).
      final ranks = [
        if (param.includeAll) 'all',...loadedData.taxRanks,
        if (param.includeAsv) 'ASV',
      ];
      return _dropdown(current, ranks, hintOnEmpty: false);
    }

    return TextFormField(
      key: ValueKey(param.flag),
      initialValue: current,
      style: const TextStyle(fontSize: 12),
      keyboardType: (param.type == 'int' || param.type == 'float') ? const TextInputType.numberWithOptions(decimal: true): TextInputType.text,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        errorText: missing ? '': null,
      ),
      onChanged: (v) {
        state.values[param.flag] = v;
        onChanged();
      },
    );
  }

  Widget _dropdown(String current, List<String> options, {required bool hintOnEmpty}) {
    return DropdownButtonFormField<String>(
      initialValue: options.contains(current) ? current: null,
      isDense: true,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        errorText: missing ? '': null,
      ),
      items: options.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: options.isEmpty
          ? null: (v) {
              if (v != null) {
                state.values[param.flag] = v;
                onChanged();
              }
            },
    );
  }
}
