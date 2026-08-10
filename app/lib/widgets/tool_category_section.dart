import 'package:flutter/material.dart';
import '../models/tool.dart';
import '../models/tool_params_state.dart';
import '../logic/tool_dependency_graph.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ToolCategorySection extends ConsumerWidget {
  final ToolCategory category;
  final Set<String> activeTools;
  final Map<String, Set<String>> activeTracks;
  final DependencyGraph graph;
  final Map<String, ToolParamsState> toolParams;
  final ValueChanged<String> onToggle;
  final void Function(String toolId, String track) onToggleTrack;
  final VoidCallback onParamsChanged;

  const ToolCategorySection({
    super.key,
    required this.category,
    required this.activeTools,
    required this.activeTracks,
    required this.graph,
    required this.toolParams,
    required this.onToggle,
    required this.onToggleTrack,
    required this.onParamsChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requiresLabel = ref.t('requires_label');
    final english = ref.watch(localeProvider).languageCode == 'en';
    final trackLabels = {'sample': ref.t('track_sample_label'), 'mags': ref.t('track_mags_label')};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(category.category, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 8),...category.tools.map((tool) {
              final active = activeTools.contains(tool.id);
              final blocked = !active && !graph.canEnable(tool.id, activeTools, activeTracks);
              final tracksOn = activeTracks[tool.id] ?? const <String>{};
              final trackCanEnable = {
                for (final t in tool.tracks.keys) t: graph.canEnableTrack(tool.id, t, activeTools, activeTracks),
              };
              return _ToolRow(
                tool: tool,
                active: active,
                blocked: blocked,
                activeTracks: tracksOn,
                trackCanEnable: trackCanEnable,
                trackLabels: trackLabels,
                missingLabel:
                    blocked ? graph.missingRequirementLabel(tool.id, activeTools, activeTracks, english: english): '',
                requiresLabel: requiresLabel,
                params: toolParams[tool.id],
                onToggle: () => onToggle(tool.id),
                onToggleTrack: (track) => onToggleTrack(tool.id, track),
                onParamsChanged: onParamsChanged,
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  final ToolDef tool;
  final bool active;
  final bool blocked;
  final Set<String> activeTracks;
  final Map<String, bool> trackCanEnable;
  final Map<String, String> trackLabels;
  final String missingLabel;
  final String requiresLabel;
  final ToolParamsState? params;
  final VoidCallback onToggle;
  final ValueChanged<String> onToggleTrack;
  final VoidCallback onParamsChanged;

  const _ToolRow({
    required this.tool,
    required this.active,
    required this.blocked,
    required this.activeTracks,
    required this.trackCanEnable,
    required this.trackLabels,
    required this.missingLabel,
    required this.requiresLabel,
    required this.params,
    required this.onToggle,
    required this.onToggleTrack,
    required this.onParamsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final p = params;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: (p?.expanded ?? false) ? colors.surfaceAlt: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: p == null ? null : () {
              p.expanded = !p.expanded;
              onParamsChanged();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Opacity(
                opacity: blocked ? 0.5: 1,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                              if (tool.readType != 'all')...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(4)),
                                  child: Text(tool.readType, style: TextStyle(fontSize: 10, color: colors.textMuted)),
                                ),
                              ],
                              if (p != null)...[
                                const SizedBox(width: 6),
                                Icon(p.expanded ? Icons.expand_less: Icons.expand_more, size: 16, color: colors.textMuted),
                              ],
                            ],
                          ),
                          Text(tool.description, style: TextStyle(fontSize: 12, color: colors.textSecondary)),
                          if (blocked && missingLabel.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text('$requiresLabel: $missingLabel',
                                  style: TextStyle(fontSize: 11, color: colors.statusError, fontStyle: FontStyle.italic)),
                            ),
                        ],
                      ),
                    ),
                    if (tool.tracks.isEmpty)
                      Switch(value: active, onChanged: blocked ? null: (_) => onToggle)
                    else
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final track in tool.tracks.keys)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: FilterChip(
                                label: Text(trackLabels[track] ?? track, style: const TextStyle(fontSize: 11)),
                                selected: activeTracks.contains(track),
                                onSelected: (activeTracks.contains(track) || (trackCanEnable[track] ?? true))
                                    ? (_) => onToggleTrack(track): null,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          if ((p?.expanded ?? false) && p != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: _ToolFlagEditor(tool: tool, state: p, onChanged: onParamsChanged),
            ),
        ],
      ),
    );
  }
}

class _ToolFlagEditor extends ConsumerWidget {
  final ToolDef tool;
  final ToolParamsState state;
  final VoidCallback onChanged;

  const _ToolFlagEditor({required this.tool, required this.state, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final common = tool.flags.where((f) => f.enabledByDefault).toList();
    final advanced = tool.flags.where((f) => !f.enabledByDefault).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: colors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (common.isEmpty && advanced.isEmpty)
            Text(ref.t('no_configurable_flags'), style: TextStyle(fontSize: 12, color: colors.textMuted, fontStyle: FontStyle.italic)),
          for (final flag in common) _FlagRow(flag: flag, state: state, onChanged: onChanged),
          if (advanced.isNotEmpty)...[
            const Divider(height: 20),
            InkWell(
              onTap: () {
                state.showAdvanced = !state.showAdvanced;
                onChanged();
              },
              child: Row(
                children: [
                  Icon(state.showAdvanced ? Icons.expand_less: Icons.tune, size: 14, color: colors.primaryDark),
                  const SizedBox(width: 6),
                  Text('${ref.t('advanced_flags_label')} (${advanced.length})',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.primaryDark)),
                ],
              ),
            ),
            if (state.showAdvanced)...[
              const SizedBox(height: 4),
              for (final flag in advanced) _FlagRow(flag: flag, state: state, onChanged: onChanged),
            ],
          ],
          const Divider(height: 20),
          Text(ref.t('extra_params_manual'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textSecondary)),
          const SizedBox(height: 4),
          TextFormField(
            initialValue: state.extraParams,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              isDense: true,
              hintText: ref.t('extra_params_hint'),
            ),
            onChanged: (v) {
              state.extraParams = v;
              onChanged();
            },
          ),
        ],
      ),
    );
  }
}

class _FlagRow extends StatelessWidget {
  final ToolFlag flag;
  final ToolParamsState state;
  final VoidCallback onChanged;

  const _FlagRow({required this.flag, required this.state, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = state.enabledFlags.contains(flag.flag);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: enabled,
            onChanged: (v) {
              if (v == true) {
                state.enabledFlags.add(flag.flag);
              } else {
                state.enabledFlags.remove(flag.flag);
              }
              onChanged();
            },
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(flag.flag, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                  Text(flag.description, style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                ],
              ),
            ),
          ),
          if (flag.type != 'bool')...[
            const SizedBox(width: 8),
            SizedBox(
              width: 140,
              child: _FlagValueInput(flag: flag, state: state, enabled: enabled, onChanged: onChanged),
            ),
          ],
        ],
      ),
    );
  }
}

class _FlagValueInput extends StatelessWidget {
  final ToolFlag flag;
  final ToolParamsState state;
  final bool enabled;
  final VoidCallback onChanged;

  const _FlagValueInput({required this.flag, required this.state, required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final current = state.flagValues[flag.flag] ?? flag.defaultValue?.toString() ?? '';

    if (flag.type == 'choice' && flag.choices != null) {
      return DropdownButtonFormField<String>(
        initialValue: flag.choices!.contains(current) ? current: null,
        isDense: true,
        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
        items: flag.choices!.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 12)))).toList(),
        onChanged: !enabled ? null: (v) {
          if (v != null) {
            state.flagValues[flag.flag] = v;
            onChanged();
          }
        },
      );
    }

    return TextFormField(
      key: ValueKey(flag.flag),
      initialValue: current,
      enabled: enabled,
      style: const TextStyle(fontSize: 12),
      keyboardType: (flag.type == 'int' || flag.type == 'float') ? const TextInputType.numberWithOptions(decimal: true): TextInputType.text,
      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
      onChanged: (v) {
        state.flagValues[flag.flag] = v;
        onChanged();
      },
    );
  }
}
