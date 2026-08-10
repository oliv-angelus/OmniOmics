import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../models/plot_style_state.dart';
import '../theme/app_theme.dart';

/// Background/font/color editing for the Plots tab's "Personalizar" panel --
/// writes straight into a [PlotStyleState] the caller owns (same in-place-
/// mutate-then-call-onChanged pattern PlotParamForm already uses), which
/// gets serialized to style.json and passed to a "Replotar" run via
/// --style_json (see plot_theme.R's resolve_palette/base_theme on the R
/// side, which is what actually applies these).
/// Analyses with no single cartesian X/Y axis pair to hide and no
/// base_theme-driven text size to scale: cooccurrence_network draws a
/// force-directed graph (theme_void), venn_diagram/upset_plot's set
/// diagrams don't have a literal "X axis"/"Y axis" concept either (upset_plot
/// does have axes internally, but they're ComplexUpset's own composed
/// sub-plots, not something base_theme/apply_axis_visibility reaches --
/// see plot_theme.R). Font size + axis visibility controls are hidden for
/// these rather than shown as a checkbox that silently does nothing.
const _kNoAxisControlAnalyses = {'cooccurrence_network', 'venn_diagram', 'upset_plot'};

class PlotStylePanel extends ConsumerWidget {
  final PlotStyleState style;
  final String analysisId;
  final VoidCallback onChanged;

  const PlotStylePanel({super.key, required this.style, required this.analysisId, required this.onChanged});

  Future<void> _pickColor(BuildContext context, WidgetRef ref, String current, ValueChanged<String> onPicked) async {
    Color picked = parseStyleColor(current);
    final cancelLabel = ref.t('cancel');
    // Deliberately NOT "plots_customize_replot" -- this dialog only stores
    // the picked color into the in-memory PlotStyleState (onPicked below),
    // it does not itself trigger a re-run. Reusing the outer panel's
    // "Replotar" label here read as if there were two separate replot
    // actions (one had actually taken effect, the other hadn't) -- a real
    // reported point of confusion, fixed by giving this its own "Salvar"/
    // "Save" label; the one real "Replotar" button stays the single one in
    // PlotWorkspaceScreen's customize panel, below every color/param edit.
    final okLabel = ref.t('plots_color_picker_save');
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: picked,
            onColorChanged: (c) => picked = c,
            enableAlpha: false,
            labelTypes: const [],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop, child: Text(cancelLabel)),
          ElevatedButton(
            onPressed: () {
              // NOT picked.toHexString(...) -- flutter_colorpicker 1.1.0's
              // own extension method has a real upstream bug: it ignores
              // every argument passed to it and hardcodes
              // colorToHex(this, includeHashSign: false, enableAlpha: true,
              // toUpperCase: true) internally (see its utils.dart source),
              // so no matter what we ask for here it always returns an
              // 8-digit ARGB hex with NO leading '#' (e.g. black comes back
              // as "FF000000", not "#000000"). That string then went
              // straight into a style.json palette entry and into
              // ggplot2's scale_color_manual unchanged, which doesn't
              // recognize it as a color at all -- a real reported crash
              // ("Unknown colour name: FF000000") the very first time a
              // replot actually used an edited color. Calling the package's
              // top-level colorToHex function directly instead (same
              // module, but not broken) gets the real "#RRGGBB" this app's
              // R side (plot_theme.R's apply_palette_overrides) expects.
              onPicked(colorToHex(picked, includeHashSign: true, enableAlpha: false));
              Navigator.of(dialogContext).pop;
            },
            child: Text(okLabel),
          ),
        ],
      ),
    );
  }

  Widget _swatch(BuildContext context, WidgetRef ref, String label, String colorValue, ValueChanged<String> onPicked) {
    final colors = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _pickColor(context, ref, colorValue, onPicked),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: parseStyleColor(colorValue),
                shape: BoxShape.circle,
                border: Border.all(color: colors.border),
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(ref.t('plots_customize_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ref.t('plots_customize_background'), style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                  const SizedBox(height: 4),
                  _swatch(context, ref, ref.t('plots_customize_background'), style.background, (v) {
                    style.background = v;
                    onChanged();
                  }),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ref.t('plots_customize_font'), style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    initialValue: style.fontFamily,
                    isDense: true,
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                    items: [
                      DropdownMenuItem(value: 'serif', child: Text(ref.t('plots_font_serif'), style: const TextStyle(fontSize: 12))),
                      DropdownMenuItem(value: 'sans', child: Text(ref.t('plots_font_sans'), style: const TextStyle(fontSize: 12))),
                      DropdownMenuItem(value: 'mono', child: Text(ref.t('plots_font_mono'), style: const TextStyle(fontSize: 12))),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        style.fontFamily = v;
                        onChanged();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!_kNoAxisControlAnalyses.contains(analysisId))...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${ref.t('plots_customize_font_size')} (${style.fontScale.toStringAsFixed(2)}x)',
                        style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: style.fontScale,
                        min: 0.7,
                        max: 1.6,
                        divisions: 18,
                        onChanged: (v) {
                          style.fontScale = v;
                          onChanged();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  value: style.hideXAxis,
                  onChanged: (v) {
                    style.hideXAxis = v ?? false;
                    onChanged();
                  },
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(ref.t('plots_customize_hide_x_axis'), style: const TextStyle(fontSize: 12.5)),
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  value: style.hideYAxis,
                  onChanged: (v) {
                    style.hideYAxis = v ?? false;
                    onChanged();
                  },
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(ref.t('plots_customize_hide_y_axis'), style: const TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),
        ],
        if (style.accentColor != null)...[
          const SizedBox(height: 12),
          Text(ref.t('plots_customize_colors'), style: TextStyle(fontSize: 11, color: colors.textSecondary)),
          const SizedBox(height: 4),
          _swatch(context, ref, ref.t('plots_customize_colors'), style.accentColor!, (v) {
            style.accentColor = v;
            onChanged();
          }),
        ],
        if (style.palette.isNotEmpty)...[
          const SizedBox(height: 12),
          Text(ref.t('plots_customize_colors'), style: TextStyle(fontSize: 11, color: colors.textSecondary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: style.palette.entries.map((e) => _swatch(context, ref, e.key, e.value, (v) {
                      style.palette[e.key] = v;
                      onChanged();
                    })).toList(),
          ),
        ],
      ],
    );
  }
}
