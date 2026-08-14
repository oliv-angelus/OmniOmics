import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/database.dart';
import '../services/api_client.dart';
import '../services/database_download_provider.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'extra_tag.dart';

/// Formats a size for the Databases screen, where the values span four orders
/// of magnitude -- CANT-HYD at 8 MB, CAT/BAT at 123 GB. Showing "0.008 GB" for
/// the first is technically right and useless.
String formatDbSize(num gb) {
  if (gb >= 100) return '${gb.round()} GB';
  if (gb >= 1) return '${gb.toStringAsFixed(gb == gb.roundToDouble() ? 0 : 1)} GB';
  return '${(gb * 1024).round()} MB';
}

class DatabaseCard extends ConsumerStatefulWidget {
  final ApiClient api;
  final String pipelineId;
  final DatabaseDef database;
  final VoidCallback onChanged;

  /// Whether this row is ticked for the batch download. Null [onSelectedChanged]
  /// hides the checkbox entirely -- the per-pipeline Launch screen reuses this
  /// widget as a read-only status check, where selecting means nothing.
  final bool selected;
  final ValueChanged<bool>? onSelectedChanged;

  /// Reports the size the row is currently counting, so the screen's budget can
  /// follow a changed download option without re-reading every row.
  final ValueChanged<num>? onSizeChanged;

  const DatabaseCard({
    super.key,
    required this.api,
    required this.pipelineId,
    required this.database,
    required this.onChanged,
    this.selected = false,
    this.onSelectedChanged,
    this.onSizeChanged,
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

  /// What this database will actually cost on disk: the selected option's own
  /// size where the manifest states one, otherwise the database's headline
  /// figure. The two are frequently far apart -- Kraken2 declares 16 GB while
  /// its options run 5.2 to 164 -- which is the whole reason size_gb exists per
  /// option.
  num get _effectiveSizeGb {
    // Already on disk: report what was actually downloaded, not what the row
    // would pick if you started now. The two differ by an order of magnitude
    // for Kraken2 (11 GB default, 164 GB for PlusPFP Full), and this figure is
    // what the disk budget sums as "installed".
    if (widget.database.configured) {
      final chosen = widget.database.downloadChoice;
      if (chosen != null) {
        final option =
            widget.database.downloadOptions.where((o) => o.id == chosen).firstOrNull;
        if (option?.sizeGb != null) return option!.sizeGb!;
      }
      // Set manually or detected, so the build is unknown -- the database's own
      // headline figure is the least wrong thing available.
      return widget.database.sizeGb;
    }
    return _selectedOption?.sizeGb ?? widget.database.sizeGb;
  }

  /// The option a maintainer marked with ★ in its label, or the first one.
  ///
  /// Selecting it up front is what lets the row show a real number and the disk
  /// budget add up before the user has expanded anything. It also means Baixar
  /// is enabled as soon as a destination is chosen, instead of silently
  /// requiring a radio click the interface never asked for.
  DownloadOption? get _defaultOption {
    final options = widget.database.downloadOptions;
    if (options.isEmpty) return null;
    return options.firstWhere((o) => o.label.contains('★'), orElse: () => options.first);
  }

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
    _selectedOption = _defaultOption;
    if (widget.onSizeChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSizeChanged!(_effectiveSizeGb);
      });
    }
  }

  @override
  void didUpdateWidget(DatabaseCard old) {
    super.didUpdateWidget(old);
    // The screen's _load() rebuilds every DatabaseDef and DownloadOption from
    // JSON, and DownloadOption declares no ==, so the instance held here stops
    // matching anything in the new list: RadioListTile's groupValue finds no
    // equal value and the expanded row renders with nothing selected, while the
    // collapsed row still shows a size and Baixar stays enabled. Re-resolve by
    // id, which is stable across rebuilds.
    if (!identical(old.database, widget.database)) {
      final id = _selectedOption?.id;
      _selectedOption = widget.database.downloadOptions
              .where((o) => o.id == id)
              .firstOrNull ??
          _defaultOption;
    }
  }

  void _selectOption(DownloadOption? option) {
    setState(() => _selectedOption = option);
    widget.onSizeChanged?.call(_effectiveSizeGb);
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

    return Container(
      color: widget.selected ? colors.primary.withValues(alpha: 0.08) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // One row rather than a 400px card: 26 databases share the same
            // five attributes, and things with the same attributes get
            // compared, not browsed. Everything below the fold is unchanged --
            // expanding a row reveals exactly the controls the card had.
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.onSelectedChanged != null)
                    SizedBox(
                      width: 34,
                      child: Checkbox(
                        value: widget.selected,
                        // Nothing to fetch for a database with no automatic
                        // download, and no point selecting one already on disk.
                        onChanged: (db.configured || db.downloadOptions.isEmpty)
                            ? null
                            : (v) => widget.onSelectedChanged!(v ?? false),
                      ),
                    ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: status.fg(colors), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 7,
                          runSpacing: 4,
                          children: [
                            Text(db.name,
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                            if (db.usedBy != null)
                              for (final pid in db.usedBy!) ExtraTag(tag: pid, english: english),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          db.description,
                          style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (downloading)
                    SizedBox(
                      width: 104,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                            value: (dl!.percent > 0) ? dl.percent / 100 : null, minHeight: 5),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: status.bg(colors), borderRadius: BorderRadius.circular(6)),
                      child: Text(label,
                          style: TextStyle(
                              color: status.fg(colors), fontSize: 10.5, fontWeight: FontWeight.w600)),
                    ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 84,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatDbSize(_effectiveSizeGb),
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                        if (db.downloadOptions.length > 1)
                          Text('${db.downloadOptions.length} ${ref.t('db_versions')}',
                              style: TextStyle(fontSize: 10, color: colors.textMuted)),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: ref.t('choose_db_path_tooltip'),
                    child: IconButton(
                      icon: const Icon(Icons.folder_outlined, size: 17),
                      visualDensity: VisualDensity.compact,
                      onPressed: _pickPath,
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: colors.textMuted),
                ],
              ),
            ),
            if (db.configured)...[
              const SizedBox(height: 6),
              Padding(
                padding: EdgeInsets.only(left: widget.onSelectedChanged != null ? 54 : 20),
                child: Text(db.path ?? '',
                    style: TextStyle(fontSize: 11.5, color: colors.textSecondary, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
              ),
            ] else if (_destDir != null)...[
              const SizedBox(height: 6),
              Padding(
                padding: EdgeInsets.only(left: widget.onSelectedChanged != null ? 54 : 20),
                child: Text('${ref.t('destination_prefix')}: $_destDir',
                    style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
                    overflow: TextOverflow.ellipsis),
              ),
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
                    onChanged: _selectOption,
                    title: Text(opt.label, style: const TextStyle(fontSize: 13)),
                    secondary: opt.sizeGb != null
                        ? Text(formatDbSize(opt.sizeGb!),
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: colors.textSecondary))
                        : null,
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
