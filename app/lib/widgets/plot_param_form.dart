import 'package:flutter/material.dart';
import '../models/plot_analysis.dart';
import '../models/plot_loaded_data.dart';
import '../models/plot_params_state.dart';
import '../theme/app_theme.dart';
import '../l10n/app_strings.dart';
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
          _PlotParamRow(param: p, state: state, loadedData: loadedData,
              shape: analysis.inputShape, onChanged: onChanged),
      ],
    );
  }
}

class _PlotParamRow extends StatelessWidget {
  final PlotParam param;
  final PlotParamsState state;
  final PlotLoadedData loadedData;
  final String shape;
  final VoidCallback onChanged;

  const _PlotParamRow({required this.param, required this.state, required this.loadedData,
      required this.shape, required this.onChanged});

  String get _label => param.flag.replaceFirst(RegExp(r'^--'), '');
  bool get _required =>
      param.defaultValue == '' || param.type == 'column' || param.type == 'level' || param.type == 'sample' || param.type == 'samples';

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
            child: _PlotParamValueInput(param: param, state: state, loadedData: loadedData,
                shape: shape, missing: missing, onChanged: onChanged),
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
  final String shape;
  final bool missing;
  final VoidCallback onChanged;

  const _PlotParamValueInput({
    required this.param,
    required this.state,
    required this.loadedData,
    required this.shape,
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
      return _dropdown(current, loadedData.columnsFor(shape), hintOnEmpty: true);
    }

    if (param.type == 'samples') {
      // Multi-select sibling of "sample": a run can yield dozens of genomes
      // and the interesting ones are usually a handful, so several are picked
      // at once and sent as one comma-separated value. Rendered as a button
      // opening a checkbox dialog rather than an inline list, because the
      // parameter column is only as wide as a dropdown.
      final picked = current.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      return _MultiSampleField(
        options: loadedData.samples,
        selected: picked,
        missing: missing,
        onDone: (values) {
          state.values[param.flag] = values.join(',');
          onChanged();
        },
      );
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
      final levels = (dependsOnValue != null ? loadedData.levelsFor(shape)[dependsOnValue] : null) ?? const <String>[];
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

/// Compact multi-select for PlotParam's "samples" type: shows how many are
/// currently picked and opens a checkbox dialog to change the selection.
/// Kept local to this file because it exists only to serve that one parameter
/// type -- the single-select "sample" case is a plain dropdown above.
class _MultiSampleField extends ConsumerWidget {
  final List<String> options;
  final List<String> selected;
  final bool missing;
  final ValueChanged<List<String>> onDone;

  const _MultiSampleField({
    required this.options,
    required this.selected,
    required this.missing,
    required this.onDone,
  });

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final working = <String>{...selected};
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: Text(ref.t('plots_pick_items'), style: const TextStyle(fontSize: 15)),
          content: SizedBox(
            width: 380,
            child: options.isEmpty
                ? Text(ref.t('plots_no_items'), style: const TextStyle(fontSize: 12))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      // Toggles between select-all and clear-all depending on
                      // the current state, rather than two separate buttons --
                      // a run can have dozens of MAGs, and "mark all then
                      // uncheck a couple" is the common case that motivated
                      // this in the first place.
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: working.length == options.length
                            ? true
                            : (working.isEmpty ? false : null),
                        tristate: true,
                        title: Text(ref.t('plots_select_all'),
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        onChanged: (_) => setLocalState(() {
                          if (working.length == options.length) {
                            working.clear();
                          } else {
                            working
                              ..clear()
                              ..addAll(options);
                          }
                        }),
                      ),
                      const Divider(height: 1),
                      for (final o in options)
                        CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: working.contains(o),
                          title: Text(o, style: const TextStyle(fontSize: 12.5)),
                          onChanged: (v) => setLocalState(() {
                            if (v == true) {
                              working.add(o);
                            } else {
                              working.remove(o);
                            }
                          }),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(ref.t('cancel')),
            ),
            ElevatedButton(
              // Preserve the run's own order rather than click order, so the
              // exported figure's panels stay in a stable, predictable layout.
              onPressed: () => Navigator.of(dialogContext)
                  .pop(options.where(working.contains).toList()),
              child: Text(ref.t('confirm')),
            ),
          ],
        ),
      ),
    );
    if (result != null) onDone(result);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final label = selected.isEmpty
        ? ref.t('plots_pick_items')
        : (selected.length == 1 ? selected.first : '${selected.length} ${ref.t('plots_selected_suffix')}');
    return OutlinedButton(
      onPressed: () => _open(context, ref),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        side: BorderSide(color: missing ? colors.statusError : colors.border),
        alignment: Alignment.centerLeft,
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
