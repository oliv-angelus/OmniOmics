import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../models/database.dart';
import '../services/api_client.dart';
import '../services/database_download_all_provider.dart';
import '../theme/app_theme.dart';

class _BaseDirChoice {
  final String path;
  final Map<String, String> options;
  final List<String> selected; // db keys the user ticked to download
  const _BaseDirChoice(this.path, this.options, this.selected);
}

/// Entry point: shows the folder + per-database option picker, then (if
/// confirmed) the download-all progress dialog. Reloads database statuses via
/// [onChanged] once the dialog closes, same as every other database-mutating
/// action here.
///
/// The batch itself lives in [downloadAllProvider] (ProviderScope root), not in
/// the dialog -- so if one is already running/finished for this pipeline,
/// reopening reattaches to it instead of starting a second one.
Future<void> showDownloadAllDatabasesDialog({
  required BuildContext context,
  required WidgetRef ref,
  required ApiClient api,
  required String pipelineId,
  required List<DatabaseDef> missing,
  required VoidCallback onChanged,
}) async {
  final notifier = ref.read(downloadAllProvider.notifier);

  // Already a batch for this pipeline (still running, or finished but not yet
  // dismissed)? Reattach to it rather than starting a new one.
  if (ref.read(downloadAllProvider)[pipelineId] != null) {
    notifier.reconnect(pipelineId);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadAllProgressDialog(pipelineId: pipelineId),
    );
    onChanged;
    return;
  }

  // Only databases with an automatic download option are candidates -- the rest
  // need manual setup and can't be bulk-downloaded.
  final downloadable = missing.where((d) => d.downloadOptions.isNotEmpty).toList;
  if (downloadable.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('download_all_none_missing'))));
    return;
  }

  String? baseDir;
  try {
    final res = await api.get('/api/pipelines/$pipelineId/databases/base-dir') as Map<String, dynamic>;
    final saved = res['base_dir'] as String?;
    if (saved != null && saved.isNotEmpty) baseDir = saved;
  } catch (_) {}

  if (!context.mounted) return;
  final confirmed = await showDialog<_BaseDirChoice>(
    context: context,
    builder: (dialogContext) => _PickBaseDirDialog(initialPath: baseDir, candidates: downloadable),
  );
  if (confirmed == null || !context.mounted) return;

  final selectedKeys = confirmed.selected.toSet;
  final targets = [
    for (final d in downloadable)
      if (selectedKeys.contains(d.key)) DbTarget(d.key, d.name),
  ];
  if (targets.isEmpty) return;

  notifier.start(
    pipelineId: pipelineId,
    baseDir: confirmed.path,
    options: confirmed.options,
    targets: targets,
  );

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadAllProgressDialog(pipelineId: pipelineId),
  );
  onChanged;
}

class _PickBaseDirDialog extends ConsumerStatefulWidget {
  final String? initialPath;
  final List<DatabaseDef> candidates;
  const _PickBaseDirDialog({required this.initialPath, required this.candidates});

  @override
  ConsumerState<_PickBaseDirDialog> createState => _PickBaseDirDialogState;
}

class _PickBaseDirDialogState extends ConsumerState<_PickBaseDirDialog> {
  String? _path;
  late final Map<String, String> _selectedOptions;
  late final Set<String> _selected; // db keys ticked to download (all by default)

  @override
  void initState {
    super.initState;
    _path = widget.initialPath;
    // Default every multi-option database to its first option (e.g. Kraken2's
    // Standard-8) -- the dropdown lets the user override.
    _selectedOptions = {
      for (final db in widget.candidates)
        if (db.downloadOptions.isNotEmpty) db.key: db.downloadOptions.first.id,
    };
    _selected = {for (final db in widget.candidates) db.key};
  }

  Future<void> _pick async {
    final result = await getDirectoryPath;
    if (result != null) setState( => _path = result);
  }

  void _toggleAll(bool? on) {
    setState( {
      _selected.clear;
      if (on ?? false) _selected.addAll(widget.candidates.map((d) => d.key));
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final allSelected = _selected.length == widget.candidates.length;
    final noneSelected = _selected.isEmpty;

    return AlertDialog(
      title: Text(ref.t('download_all_dialog_title')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref.t('download_all_dialog_body'), style: TextStyle(color: colors.textSecondary, fontSize: 13)),
              const SizedBox(height: 16),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _pick,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    children: [
                      Icon(Icons.folder_open, size: 18, color: colors.textMuted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _path?.isNotEmpty == true ? _path!: ref.t('download_all_dialog_pick'),
                          style:
                              TextStyle(color: _path?.isNotEmpty == true ? colors.textPrimary: colors.textMuted, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 28),
              // Select-all header + per-database checkboxes ("todos ou alguns").
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(ref.t('download_all_select_dbs'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: allSelected ? true: (noneSelected ? false: null),
                        tristate: true,
                        onChanged: (_) => _toggleAll(!allSelected),
                      ),
                      Text(ref.t('download_all_select_all'), style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final db in widget.candidates) _dbRow(db, colors),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed:  => Navigator.of(context).pop, child: Text(ref.t('cancel'))),
        ElevatedButton(
          onPressed: (_path?.isNotEmpty == true && _selected.isNotEmpty)
              ?  => Navigator.of(context).pop(_BaseDirChoice(_path!, _selectedOptions, _selected.toList)): null,
          child: Text(ref.t('download_all_dialog_start')),
        ),
      ],
    );
  }

  Widget _dbRow(DatabaseDef db, dynamic colors) {
    final checked = _selected.contains(db.key);
    final sizeLabel = db.sizeGb > 0 ? ' (~${db.sizeGb} GB)': '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap:  => setState( => checked ? _selected.remove(db.key): _selected.add(db.key)),
            child: Row(
              children: [
                Checkbox(
                  value: checked,
                  onChanged: (v) => setState( => (v ?? false) ? _selected.add(db.key): _selected.remove(db.key)),
                ),
                Expanded(
                  child: Text('${db.name}$sizeLabel',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                ),
              ],
            ),
          ),
          // Option dropdown only for multi-option databases, and only while the
          // database is actually selected.
          if (checked && db.downloadOptions.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 6),
              child: DropdownButtonFormField<String>(
                initialValue: _selectedOptions[db.key],
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10)),
                items: db.downloadOptions.map((opt) => DropdownMenuItem(
                          value: opt.id,
                          child: Text('${opt.label} — ${opt.description}',
                              style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                        )).toList,
                onChanged: (v) => setState( => _selectedOptions[db.key] = v!),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pure view over [downloadAllProvider]: the batch's lifetime is owned by the
/// provider (and the detached backend task), so this dialog can be closed and
/// reopened freely without stopping anything. "Fechar" leaves the batch running
/// in the background; "Cancelar" actually stops it.
class _DownloadAllProgressDialog extends ConsumerWidget {
  final String pipelineId;

  const _DownloadAllProgressDialog({required this.pipelineId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final st = ref.watch(downloadAllProvider)[pipelineId];
    // A dismissed/cancelled batch leaves no state -- treat as finished so the
    // dialog offers a close button instead of getting stuck.
    final finished = st == null || st.phase != DownloadAllPhase.running;
    final targets = st?.targets ?? const <DbTarget>[];
    final dbStatus = st?.dbStatus ?? const <String, DbBatchState>{};
    final log = st?.log ?? const <String>[];

    return AlertDialog(
      title: Text(ref.t('download_all_progress_title')),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: targets.map((t) => _DbChip(name: t.name, state: dbStatus[t.key] ?? DbBatchState.pending)).toList,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
                child: ListView.builder(
                  itemCount: log.length,
                  itemBuilder: (context, i) => Text(
                    log[i],
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: colors.textSecondary),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!finished)...[
          TextButton(
            onPressed:  => Navigator.of(context).pop,
            child: Text(ref.t('download_all_close_keep')),
          ),
          TextButton(
            onPressed:  {
              ref.read(downloadAllProvider.notifier).cancel(pipelineId);
              Navigator.of(context).pop;
            },
            child: Text(ref.t('cancel')),
          ),
        ] else
          ElevatedButton(
            onPressed:  {
              ref.read(downloadAllProvider.notifier).dismiss(pipelineId);
              Navigator.of(context).pop;
            },
            child: Text(ref.t('download_all_done')),
          ),
      ],
    );
  }
}

class _DbChip extends ConsumerWidget {
  final String name;
  final DbBatchState state;
  const _DbChip({required this.name, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final (bg, fg, icon) = switch (state) {
      DbBatchState.pending => (colors.surfaceAlt, colors.textMuted, Icons.schedule),
      DbBatchState.running => (colors.statusRunningBg, colors.statusRunning, null),
      DbBatchState.done => (colors.statusDoneBg, colors.statusDone, Icons.check_circle),
      DbBatchState.error => (colors.statusErrorBg, colors.statusError, Icons.error),
      DbBatchState.skipped => (colors.surfaceAlt, colors.textMuted, Icons.block),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon == null)
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
          else
            Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            state == DbBatchState.skipped ? '$name (${ref.t('download_all_skipped_manual')})': name,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}
