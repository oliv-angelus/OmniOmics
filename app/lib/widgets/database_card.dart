import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/database.dart';
import '../services/api_client.dart';
import '../services/database_download_provider.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'extra_tag.dart';

class DatabaseCard extends ConsumerStatefulWidget {
  final ApiClient api;
  final String pipelineId;
  final DatabaseDef database;
  final VoidCallback onChanged;

  const DatabaseCard({
    super.key,
    required this.api,
    required this.pipelineId,
    required this.database,
    required this.onChanged,
  });

  @override
  ConsumerState<DatabaseCard> createState() => _DatabaseCardState();
}

class _DatabaseCardState extends ConsumerState<DatabaseCard> {
  bool _expanded = false;
  DownloadOption? _selectedOption;
  String? _destDir;
  bool _validating = false;

  String get _downloadKey => databaseDownloadKey(widget.pipelineId, widget.database.key);

  @override
  void initState() {
    super.initState();
    // The download itself lives in databaseDownloadsProvider, independent of
    // this card's lifecycle -- but _destDir/_expanded are still local so a
    // fresh mount (e.g. after navigating away from Databases and back, which
    // tears down and rebuilds every card) needs to pull them back from
    // whatever's already running/errored for this key instead of starting
    // blank with no visible progress bar/cancel/retry controls.
    final existing = ref.read(databaseDownloadsProvider)[_downloadKey];
    if (existing != null) {
      _destDir = existing.destDir;
      _expanded = true;
    }
  }

  /// Sets the destination for a *fresh* download from inside the expanded
  /// options section -- distinct from the header folder icon, which (once
  /// `configured`) instead re-points the existing setting straight away with
  /// no download involved. Needed because that shortcut never touches
  /// `_destDir`, so without this the Baixar button below would stay
  /// permanently disabled for an already-configured database.
  Future<void> _pickDownloadDestDir() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    setState(() => _destDir = path);
  }

  Future<void> _pickPath() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    if (widget.database.configured) {
      // Already have a database -- picking a new path re-points the setting directly.
      await widget.api.post('/api/pipelines/${widget.pipelineId}/databases/set', {
        'key': widget.database.key,
        'path': path,
      });
      widget.onChanged();
    } else {
      // Not configured yet -- this is the destination for the upcoming download.
      // Auto-expand so the validate/download controls (only rendered while
      // expanded) are immediately visible instead of leaving the user
      // staring at just the "Destino:..." line with no button under it.
      setState(() {
        _destDir = path;
        _expanded = true;
      });
    }
  }

  Future<void> _validate() async {
    if (_destDir == null || _validating) return;
    setState(() => _validating = true);
    try {
      final res = await widget.api.post(
        '/api/pipelines/${widget.pipelineId}/databases/${widget.database.key}/validate',
        {'path': _destDir},
      ) as Map<String, dynamic>;
      if (res['valid'] == true) {
        await widget.api.post('/api/pipelines/${widget.pipelineId}/databases/set', {
          'key': widget.database.key,
          'path': res['path'],
        });
        widget.onChanged();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('validate_db_success'))));
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('validate_db_failed'))));
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  void _download() {
    if (_selectedOption == null || _destDir == null) return;
    ref.read(databaseDownloadsProvider.notifier).start(
          pipelineId: widget.pipelineId,
          dbKey: widget.database.key,
          dbName: widget.database.name,
          optionId: _selectedOption!.id,
          destDir: _destDir!,
        );
  }

  void _cancelDownload() {
    ref.read(databaseDownloadsProvider.notifier).cancel(widget.pipelineId, widget.database.key);
  }

  /// Four real states, not the generic queued/running/done/error trio used
  /// elsewhere: a database that simply hasn't been obtained yet is not
  /// "queued" (nothing is pending for it), so it gets its own neutral label
  /// distinct from "downloading".
  (RunStatus, String) _statusTag(DatabaseDownloadState? dl) {
    if (widget.database.configured) return (RunStatus.done, ref.t('db_validated'));
    if (dl?.phase == DownloadPhase.running) return (RunStatus.running, ref.t('db_downloading'));
    if (dl?.phase == DownloadPhase.error) return (RunStatus.error, ref.t('db_download_error'));
    return (RunStatus.queued, ref.t('db_absent'));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final db = widget.database;
    final dl = ref.watch(databaseDownloadsProvider)[_downloadKey];
    final downloading = dl?.phase == DownloadPhase.running;
    final (status, label) = _statusTag(dl);
    final english = ref.watch(localeProvider).languageCode == 'en';

    // Refresh the card list (flips `configured` -> true) exactly once when
    // this download transitions into "done" -- watching the map above
    // re-triggers build on every change, so this can't just be inline
    // logic in build without firing repeatedly.
    ref.listen(databaseDownloadsProvider, (previous, next) {
      final wasDone = previous?[_downloadKey]?.phase == DownloadPhase.done;
      final isDone = next[_downloadKey]?.phase == DownloadPhase.done;
      if (isDone && !wasDone) widget.onChanged();
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: status.bg(colors), borderRadius: BorderRadius.circular(6)),
                  child: Text(label, style: TextStyle(color: status.fg(colors), fontSize: 11, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(db.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Text('~${db.sizeGb} GB', style: TextStyle(color: colors.textMuted, fontSize: 12)),
                const SizedBox(width: 4),
                Tooltip(
                  message: ref.t('choose_db_path_tooltip'),
                  child: IconButton(
                    icon: const Icon(Icons.folder_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: _pickPath,
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Icon(_expanded ? Icons.expand_less: Icons.expand_more, color: colors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(db.description, style: TextStyle(color: colors.textSecondary, fontSize: 13)),
            if (db.usedBy != null && db.usedBy!.isNotEmpty)...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final pid in db.usedBy!) ExtraTag(tag: pid, english: english),
                ],
              ),
            ],
            if (db.configured)...[
              const SizedBox(height: 8),
              Text(db.path ?? '', style: TextStyle(fontSize: 12, color: colors.textSecondary), overflow: TextOverflow.ellipsis),
            ] else if (_destDir != null)...[
              const SizedBox(height: 8),
              Text('${ref.t('destination_prefix')}: $_destDir',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary), overflow: TextOverflow.ellipsis),
            ],
            if (_expanded)...[
              const Divider(height: 24),
              // Shown even once configured -- otherwise there's no way back
              // into these controls to fetch a different option (or the same
              // one again, into a different folder) short of picking a
              // whole separate folder icon flow that isn't obviously "start
              // a download" to begin with.
              Text(ref.t('download_options'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 4),
              // Card sizes to its content in a Wrap-based grid, so a long option
              // list simply grows the card instead of overflowing/getting hidden
              // behind neighboring cards.
              ...db.downloadOptions.map((opt) => RadioListTile<DownloadOption>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: opt,
                    groupValue: _selectedOption,
                    onChanged: (v) => setState(() => _selectedOption = v),
                    title: Text(opt.label, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(opt.description, style: const TextStyle(fontSize: 11.5)),
                  )),
              const SizedBox(height: 8),
              if (!downloading)...[
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _pickDownloadDestDir,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Icon(Icons.folder_open, size: 16, color: colors.textMuted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _destDir ?? ref.t('choose_destination'),
                            style: TextStyle(
                                fontSize: 12, color: _destDir != null ? colors.textPrimary: colors.textMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (downloading)
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                            value: (dl!.percent > 0) ? dl.percent / 100: null, minHeight: 8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _cancelDownload, child: Text(ref.t('cancel'))),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_destDir != null)...[
                      Tooltip(
                        message: ref.t('validate_db_tooltip'),
                        child: OutlinedButton.icon(
                          onPressed: _validating ? null: _validate,
                          icon: _validating
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ): const Icon(Icons.check, size: 16),
                          label: Text(ref.t('validate_button')),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    ElevatedButton(
                      onPressed: (_selectedOption != null && _destDir != null) ? _download: null,
                      child: Text(ref.t('download_button')),
                    ),
                  ],
                ),
              if (downloading)...[
                const SizedBox(height: 4),
                Text(dl!.progressText, style: TextStyle(fontSize: 11, color: colors.textMuted)),
              ],
              if (dl?.phase == DownloadPhase.error)...[
                const SizedBox(height: 4),
                Text('${ref.t('error_prefix')}: ${dl!.errorText ?? ''}',
                    style: TextStyle(fontSize: 11, color: colors.statusError)),
              ],
              if (dl != null && dl.log.isNotEmpty)...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  height: 100,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
                  child: ListView.builder(
                    itemCount: dl.log.length,
                    itemBuilder: (context, i) => Text(dl.log[i],
                        style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: colors.textSecondary)),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
