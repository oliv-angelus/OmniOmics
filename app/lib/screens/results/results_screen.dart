import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../models/run_record.dart';
import '../../services/pipeline_run_provider.dart';
import '../../widgets/results_file_tree.dart';

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
  final _treeKey = GlobalKey<ResultsFileTreeState>;

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
      if (_selected?.isRunning ?? false) _treeKey.currentState()?.refresh;
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
    return ListView.builder(
      itemCount: _runs.length,
      itemBuilder: (context, i) {
        final run = _runs[i];
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
      },
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
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: ref.t('review_refresh'),
                onPressed: () => _treeKey.currentState()?.refresh,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
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
          TextButton(onPressed: () => Navigator.of(dialogContext).pop, child: Text(ref.t('cancel'))),
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
  /// run's actual output folder from disk, not just the history entry -- /// running runs are filtered out client-side too (belt and suspenders with
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
      final failedDirs = (res['failed_dirs'] as List?) ?? const [];
      if (failedDirs.isNotEmpty) {
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
