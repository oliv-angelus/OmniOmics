import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../models/run_record.dart';
import '../../services/pipeline_run_provider.dart';
import '../../widgets/results_file_tree.dart';
import '../../widgets/import_plot_folder_dialog.dart';
import '../../widgets/run_report_panels.dart';
import '../../widgets/database_card.dart' show formatDbSize;

/// Results section (sidebar destination, alongside Pipelines/Resources/About):
/// a run-history list -- across every pipeline, not just the current session's
/// -- and a live file browser for whichever run is selected. Modeled after
/// EPI2ME's runs panel: pick a run, see what it has produced so far.
class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key});

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  List<RunRecord> _runs = [];
  RunRecord? _selected;
  final Set<String> _checkedIds = {};
  bool _loading = true;
  bool _deleting = false;
  String? _error;
  Timer? _pollTimer;
  final _treeKey = GlobalKey<ResultsFileTreeState>();

  /// Files is the default: after a run you go and get the outputs for your own
  /// analysis. The report is periodic-but-high-value, so it belongs one click
  /// away and visibly labelled, not in front.
  bool _showReport = false;
  String _query = '';
  String? _pipelineFilter;

  @override
  void initState() {
    super.initState();
    _loadRuns();
    // Keep the run list itself fresh (statuses/new runs) regardless of which
    // one is selected -- cheap since it's just local JSON, not a big listing.
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _loadRuns(silent: true));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Registers a results folder the app never launched itself. Shares the scan
  /// dialog with the Plots tab: the same folder, the same detection, one record
  /// in the run list that both tabs then see.
  Future<void> _importRun() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const ImportPlotFolderDialog(),
    );
    if (added == true) await _loadRuns();
  }

  /// Re-launches a finished (or stopped/errored) run's exact config/cores/
  /// omit_from -- Snakemake picks up right where it left off, only redoing
  /// what's missing or failed, so this is safe even on a run that actually
  /// succeeded (worst case: a "nothing to be done" no-op). Blocked while a
  /// DIFFERENT run is live in the Monitor tab, since start() unconditionally
  /// replaces whatever pipelineRunProvider is currently tracking -- without
  /// this check, clicking Retry here could silently kill an unrelated
  /// in-progress run instead of just doing nothing useful.
  void _retryRun(RunRecord run) {
    final notifier = ref.read(pipelineRunProvider.notifier);
    if (notifier.isRunning && ref.read(pipelineRunProvider)?.runId != run.id) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('results_retry_blocked'))));
      return;
    }
    notifier.start(
      pipelineId: run.pipelineId,
      pipelineName: run.pipelineName,
      configPath: run.configPath,
      cores: run.cores,
      omitFrom: run.omitFrom,
    );
    ref.read(embeddedMonitorProvider.notifier).state = true;
  }

  Future<void> _loadRuns({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final api = ref.read(apiClientProvider);
      final raw = await api.get('/api/runs') as List;
      final runs = raw.map((e) => RunRecord.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _runs = runs;
        // Keep the same run selected across polls (matched by id); refresh its
        // record (status may have changed) rather than losing the selection.
        if (_selected != null) {
          final match = runs.where((r) => r.id == _selected!.id);
          _selected = match.isEmpty ? _selected: match.first;
        }
        _loading = false;
        _error = null;
      });
      if (_selected?.isRunning ?? false) _treeKey.currentState?.refresh();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 320,
          child: Container(
            decoration: BoxDecoration(border: Border(right: BorderSide(color: colors.border))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(ref.t('results_title'),
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: colors.textPrimary)),
                      ),
                      // A run only reaches this list if the app recorded it when
                      // it was launched. Output produced elsewhere -- on a
                      // cluster, on another machine, or before a settings reset
                      // -- is perfectly valid and otherwise invisible here, so
                      // it can be pointed at directly.
                      if (_checkedIds.isEmpty)
                        TextButton.icon(
                          onPressed: _importRun,
                          style: TextButton.styleFrom(padding: EdgeInsets.zero),
                          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                          label: Text(ref.t('results_add_existing'), style: const TextStyle(fontSize: 12)),
                        ),
                      if (_checkedIds.isNotEmpty)
                        TextButton.icon(
                          onPressed: _deleting
                              ? null: () => _confirmAndDelete(_runs.where((r) => _checkedIds.contains(r.id)).toList()),
                          style: TextButton.styleFrom(foregroundColor: colors.statusError, padding: EdgeInsets.zero),
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: Text('${ref.t('results_delete_selected')} (${_checkedIds.length})', style: const TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 34,
                        child: TextField(
                          onChanged: (q) => setState(() => _query = q.trim().toLowerCase()),
                          style: const TextStyle(fontSize: 12.5),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search, size: 16, color: colors.textMuted),
                            prefixIconConstraints: const BoxConstraints(minWidth: 32),
                            hintText: ref.t('res_search'),
                            hintStyle: TextStyle(fontSize: 12.5, color: colors.textMuted),
                            contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                        ),
                      ),
                      if (_pipelineCounts().length > 1) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            _MiniChip(
                              label: ref.t('db_filter_all'),
                              selected: _pipelineFilter == null,
                              onTap: () => setState(() => _pipelineFilter = null),
                            ),
                            for (final e in _pipelineCounts().entries)
                              _MiniChip(
                                label: e.key.toUpperCase(),
                                count: e.value,
                                selected: _pipelineFilter == e.key,
                                onTap: () => setState(
                                    () => _pipelineFilter = _pipelineFilter == e.key ? null : e.key),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (_runs.any((r) => !r.isRunning))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: InkWell(
                      onTap: () {
                        final deletable = _runs.where((r) => !r.isRunning).map((r) => r.id);
                        setState(() {
                          if (_checkedIds.length == deletable.length) {
                            _checkedIds.clear();
                          } else {
                            _checkedIds..clear()..addAll(deletable);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _checkedIds.isNotEmpty && _checkedIds.length == _runs.where((r) => !r.isRunning).length,
                              tristate: false,
                              onChanged: null,
                            ),
                            Text(ref.t('results_select_all'), style: TextStyle(fontSize: 12, color: colors.textSecondary)),
                          ],
                        ),
                      ),
                    ),
                  ),
                const Divider(height: 1),
                Expanded(child: _buildRunList(colors)),
              ],
            ),
          ),
        ),
        Expanded(
          child: _selected == null
              ? Center(child: Text(ref.t('results_select_hint'), style: TextStyle(color: colors.textMuted))): _buildDetail(colors, _selected!),
        ),
      ],
    );
  }

  Widget _buildRunList(AppPalette colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${ref.t('error_prefix')}: $_error', style: TextStyle(color: colors.statusError)));
    if (_runs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(ref.t('results_none_yet'), style: TextStyle(color: colors.textMuted), textAlign: TextAlign.center),
        ),
      );
    }
    final shown = _runs.where(_matches).toList();
    if (shown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(ref.t('res_no_match'),
              style: TextStyle(color: colors.textMuted), textAlign: TextAlign.center),
        ),
      );
    }

    // Flatten into rows interleaved with their day heading, so one ListView
    // still does the scrolling for a history that can reach 200 entries.
    final rows = <Widget>[];
    String? lastGroup;
    for (final run in shown) {
      final group = _dayGroup(run.startedAtDate);
      if (group != lastGroup) {
        lastGroup = group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(group.toUpperCase(),
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: colors.textMuted)),
        ));
      }
      rows.add(_runTile(colors, run));
    }

    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i],
    );
  }

  Widget _runTile(AppPalette colors, RunRecord run) {
        final selected = run.id == _selected?.id;
        final checked = _checkedIds.contains(run.id);
        return InkWell(
          onTap: () => setState(() => _selected = run),
          child: Container(
            color: selected ? colors.surfaceAlt: null,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Checkbox(
                  value: checked,
                  onChanged: run.isRunning
                      ? null: (v) => setState(() {
                            if (v == true) {
                              _checkedIds.add(run.id);
                            } else {
                              _checkedIds.remove(run.id);
                            }
                          }),
                ),
                _StatusDot(status: run.status),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(run.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), overflow: TextOverflow.ellipsis),
                      // A run whose folder is gone stays listed so it can be
                      // removed deliberately, but says so instead of opening
                      // to an empty tree with no explanation.
                      if (run.isMissing)
                        Row(children: [
                          Icon(Icons.folder_off_outlined, size: 12, color: colors.statusError),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(ref.t('results_output_missing'),
                                style: TextStyle(fontSize: 11, color: colors.statusError),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      Text('${run.pipelineName} · ${_formatWhen(run.startedAtDate)}',
                          style: TextStyle(fontSize: 11, color: colors.textSecondary), overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: run.isRunning ? ref.t('results_delete_running_blocked'): ref.t('results_delete_one_tooltip'),
                  visualDensity: VisualDensity.compact,
                  onPressed: run.isRunning || _deleting ? null: () => _confirmAndDelete([run]),
                ),
              ],
            ),
          ),
        );
  }

  Widget _buildDetail(AppPalette colors, RunRecord run) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(run.name,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => _renameRun(run),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.edit_outlined, size: 15, color: colors.textMuted),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(run.pipelineName, style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
                    const SizedBox(height: 2),
                    Text(run.outputDir, style: TextStyle(fontSize: 12, color: colors.textSecondary), overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              _StatusBadge(status: run.status),
              const SizedBox(width: 8),
              // Imported runs (no config_path -- see RunRecord.isImported) have
              // nothing for Snakemake to redo, and a still-running one is
              // already covered by the Monitor tab's own Retry (shown once it
              // finishes) -- so this only makes sense for a finished launch.
              if (!run.isRunning && !run.isImported)
                IconButton(
                  icon: const Icon(Icons.replay),
                  tooltip: ref.t('retry_run_tooltip'),
                  onPressed: () => _retryRun(run),
                ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: ref.t('review_refresh'),
                onPressed: () => _treeKey.currentState?.refresh(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: _RunTiles(run: run, formatDuration: _formatDuration),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _ViewSwitch(
              // Not just _showReport: the flag is screen-level and survives
              // changing the selection, so picking an imported or running run
              // while it was set left the Report segment lit and disabled over
              // the file tree.
              showReport: _showReport && !run.isRunning && !run.isImported,
              // An imported folder has no configuration to report on, and a
              // running one has not written its report yet -- say which,
              // rather than offering a tab that opens onto an explanation.
              reportEnabled: !run.isRunning && !run.isImported,
              reportTooltip: run.isRunning
                  ? ref.t('res_report_unavailable_running')
                  : ref.t('res_report_unavailable_imported'),
              onChanged: (v) => setState(() => _showReport = v),
            ),
          ),
        ),
        const Divider(height: 1),
        if (_showReport && !run.isRunning && !run.isImported)
          Expanded(child: RunReportPanels(runId: run.id))
        else
        Expanded(
          child: ResultsFileTree(
            key: _treeKey,
            rootPath: run.outputDir,
            missingLabel: ref.t('results_folder_missing'),
            emptyLabel: ref.t('results_folder_empty'),
            nodeEmptyLabel: ref.t('results_node_empty'),
            openWithTooltip: ref.t('results_open_with_tooltip'),
            openWithDialogTitle: ref.t('results_open_with_dialog_title'),
            openWithNoneFound: ref.t('results_open_with_none_found'),
            openWithCustomLabel: ref.t('results_open_with_custom_label'),
            openWithCustomHint: ref.t('results_open_with_custom_hint'),
            openWithOpenButton: ref.t('results_open_with_open_button'),
            openErrorPrefix: ref.t('results_open_error'),
            cancelLabel: ref.t('cancel'),
          ),
        ),
      ],
    );
  }

  bool _matches(RunRecord r) {
    if (_pipelineFilter != null && r.pipelineId != _pipelineFilter) return false;
    if (_query.isEmpty) return true;
    return '${r.name} ${r.pipelineName}'.toLowerCase().contains(_query);
  }

  /// A flat list is fine at five runs and unusable at fifty. Grouping by how
  /// recent something is matches how people actually look for a run -- "the one
  /// from this morning" -- far better than a date column does.
  String _dayGroup(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return ref.t('res_group_today');
    if (diff == 1) return ref.t('res_group_yesterday');
    if (diff < 7) return ref.t('res_group_week');
    return ref.t('res_group_older');
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min';
    return '${d.inSeconds} s';
  }

  Map<String, int> _pipelineCounts() {
    final counts = <String, int>{};
    for (final r in _runs) {
      counts[r.pipelineId] = (counts[r.pipelineId] ?? 0) + 1;
    }
    return Map.fromEntries(counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  String _formatWhen(DateTime dt) {
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  /// Renaming only ever touches the display label (backend keys everything
  /// by the run's id) -- safe to let the user type anything, including a name
  /// that collides with another run's.
  Future<void> _renameRun(RunRecord run) async {
    final controller = TextEditingController(text: run.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ref.t('results_rename_dialog_title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(isDense: true),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(ref.t('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(ref.t('results_rename_save')),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newName?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == run.name || !mounted) return;

    final api = ref.read(apiClientProvider);
    try {
      await api.post('/api/runs/${run.id}/rename', {'name': trimmed});
      await _loadRuns();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${ref.t('error_prefix')}: $e')));
      }
    }
  }

  /// Shared by the per-row trash icon (single run) and the "Apagar
  /// selecionadas" bulk action. Always confirms first and always deletes the
  /// run's actual output folder from disk, not just the history entry --
  /// running runs are filtered out client-side too (belt and suspenders with
  /// the backend's own block).
  Future<void> _confirmAndDelete(List<RunRecord> targets) async {
    final colors = context.colors;
    final deletable = targets.where((r) => !r.isRunning).toList();
    final blockedByRunning = targets.length - deletable.length;
    if (deletable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('results_delete_running_blocked'))));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(deletable.length > 1 ? ref.t('results_delete_confirm_title_many'): ref.t('results_delete_confirm_title')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(deletable.length > 1 ? ref.t('results_delete_confirm_body_many'): ref.t('results_delete_confirm_body_one')),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final r in deletable)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: RichText(
                            text: TextSpan(
                              style: TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: colors.textPrimary),
                              children: [
                                TextSpan(text: '${r.name}  ', style: const TextStyle(fontWeight: FontWeight.w700)),
                                TextSpan(text: '(${r.pipelineName}) — ${r.outputDir}'),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                ref.t('results_delete_confirm_warning'),
                style: TextStyle(color: colors.statusError, fontWeight: FontWeight.w600, fontSize: 12.5),
              ),
              if (blockedByRunning > 0)...[
                const SizedBox(height: 8),
                Text(ref.t('results_delete_running_blocked'), style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(ref.t('cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: colors.statusError, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(ref.t('results_delete_button')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.post('/api/runs/delete', {'run_ids': deletable.map((r) => r.id).toList()}) as Map<String, dynamic>;
      if (!mounted) return;
      // Two different reasons a folder can survive on disk after this call --
      // worded separately so a deliberately-protected path (e.g. the user's
      // own home directory, picked as output_dir by mistake) reads as
      // reassuring ("we left that alone on purpose"), not as an error the way
      // a genuine OS-level delete failure should.
      final protectedDirs = (res['protected_dirs'] as List?) ?? const [];
      final failedDirs = (res['failed_dirs'] as List?) ?? const [];
      if (protectedDirs.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('results_delete_protected_kept'))));
      } else if (failedDirs.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('results_delete_partial_failure'))));
      }
      final deletedIds = ((res['deleted'] as List?) ?? const []).cast<String>().toSet();
      setState(() {
        if (_selected != null && deletedIds.contains(_selected!.id)) _selected = null;
        _checkedIds.removeAll(deletedIds);
      });
      // The "last run" banner at the top of the app tracks its own session
      // state, separate from this history list -- without this it would keep
      // pointing at a run that no longer has anything behind it.
      ref.read(pipelineRunProvider.notifier).dismissIfIdIn(deletedIds);
      await _loadRuns();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }
}

class _StatusDot extends StatelessWidget {
  final String status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = switch (status) {
      'running' => colors.statusRunning,
      'done' => colors.statusDone,
      'error' => colors.statusError,
      _ => colors.textMuted,
    };
    if (status == 'running') {
      return SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2, color: color));
    }
    return Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

class _StatusBadge extends ConsumerWidget {
  final String status;
  const _StatusBadge({required this.status});

  String _label(WidgetRef ref) => switch (status) {
        'running' => ref.t('results_status_running'),
        'done' => ref.t('results_status_done'),
        'error' => ref.t('results_status_error'),
        'stopped' => ref.t('results_status_stopped'),
        _ => status,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final color = switch (status) {
      'running' => colors.statusRunning,
      'done' => colors.statusDone,
      'error' => colors.statusError,
      _ => colors.textMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(_label(ref), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

/// Compact filter chip for the 320px run list, where the Databases screen's
/// chip would not fit next to three others.
class _MiniChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  const _MiniChip({required this.label, this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onSelected = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0B1416)
        : Colors.white;
    return Material(
      color: selected ? colors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? colors.primary : colors.border),
          ),
          child: Text(
            count == null ? label : '$label $count',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: selected ? onSelected : colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Duration, cores, output size and reference count for the selected run.
///
/// Everything but the size comes from the run record and its config; the size
/// is measured once when the run finishes and kept on the record, because
/// walking a finished metagenome's output on every listing would not be free.
class _RunTiles extends ConsumerWidget {
  final RunRecord run;
  final String Function(Duration) formatDuration;
  const _RunTiles({required this.run, required this.formatDuration});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final tiles = <(String, String)>[
      (ref.t('res_tile_duration'),
          run.duration != null ? formatDuration(run.duration!) : '—'),
      (ref.t('res_tile_cores'), run.cores > 0 ? '${run.cores}' : '—'),
      (
        ref.t('res_tile_size'),
        run.outputSizeBytes != null ? formatDbSize(run.outputSizeBytes! / (1024 * 1024 * 1024)) : '—'
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) Container(width: 1, height: 40, color: colors.border),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tiles[i].$1.toUpperCase(),
                        style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: colors.textMuted)),
                    const SizedBox(height: 2),
                    Text(tiles[i].$2,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ViewSwitch extends ConsumerWidget {
  final bool showReport;
  final bool reportEnabled;
  final String reportTooltip;
  final ValueChanged<bool> onChanged;
  const _ViewSwitch({
    required this.showReport,
    required this.reportEnabled,
    required this.reportTooltip,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    Widget seg(String label, bool active, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
            color: active ? colors.primarySoft : Colors.transparent,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: onTap == null
                    ? colors.textMuted.withValues(alpha: 0.5)
                    : (active ? colors.primaryDark : colors.textSecondary),
              ),
            ),
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg(ref.t('res_view_files'), !showReport, () => onChanged(false)),
            Container(width: 1, height: 34, color: colors.border),
            Tooltip(
              message: reportEnabled ? '' : reportTooltip,
              child: seg(ref.t('res_view_report'), showReport,
                  reportEnabled ? () => onChanged(true) : null),
            ),
          ],
        ),
      ),
    );
  }
}
