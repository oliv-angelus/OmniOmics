import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../models/database.dart';
import '../../widgets/database_card.dart';
import '../../widgets/download_all_databases_dialog.dart';
import '../../services/database_download_all_provider.dart';

/// Hub-level database configuration: every reference database across every
/// pipeline, deduplicated by setting_key -- a database MAGMA and SIGMA both
/// use (CheckM2, GTDB-Tk,...) is configured once here instead of separately
/// in each pipeline's own Launch screen, which now just shows a status check.
class DatabasesScreen extends ConsumerStatefulWidget {
  const DatabasesScreen({super.key});

  @override
  ConsumerState<DatabasesScreen> createState => _DatabasesScreenState;
}

class _DatabasesScreenState extends ConsumerState<DatabasesScreen> {
  /// Raw `/api/databases` entries, kept so flipping the language toggle can
  /// re-derive [_databases] (description is locale-dependent) without a
  /// network round-trip.
  List<dynamic> _databasesRaw = [];
  Map<String, DatabaseDef> _databases = {};
  bool _loading = true;
  String? _error;

  @override
  void initState {
    super.initState;
    _load;
  }

  Future<void> _load async {
    // Only the very first load blanks the screen with a spinner. Reloads
    // triggered afterwards (e.g. `onChanged` from validating/picking a path
    // on one card) must not unmount the whole card grid -- doing so tears
    // down every DatabaseCard, including ones with an in-progress download,
    // and their dispose closes that download's WebSocket.
    final isInitialLoad = _databasesRaw.isEmpty;
    if (isInitialLoad) {
      setState( {
        _loading = true;
        _error = null;
      });
    }
    try {
      final api = ref.read(apiClientProvider);
      final raw = await api.get('/api/databases') as List;
      if (!mounted) return;
      setState( {
        _databasesRaw = raw;
        _databases = _buildDatabasesMap(raw);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState( {
        _error = e.toString;
        _loading = false;
      });
    }
  }

  Map<String, DatabaseDef> _buildDatabasesMap(List<dynamic> raw) {
    final lang = ref.read(localeProvider).languageCode;
    final map = <String, DatabaseDef>{};
    for (final e in raw) {
      final entry = e as Map<String, dynamic>;
      final def = DatabaseDef.fromJson(entry['source_key'] as String, entry, lang);
      // Keyed by setting_key (not source_key) so each shared database is one card.
      map[entry['setting_key'] as String] = def;
    }
    return map;
  }

  Future<void> _detectInFolder async {
    final baseDir = await getDirectoryPath;
    if (baseDir == null) return;
    final api = ref.read(apiClientProvider);
    final res = await api.post('/api/databases/detect', {'base_dir': baseDir}) as Map<String, dynamic>;
    final found = (res['found'] as Map<String, dynamic>? ?? {});
    for (final entry in found.entries) {
      final info = entry.value as Map<String, dynamic>;
      await api.post('/api/pipelines/${info['pipeline_id']}/databases/set', {
        'key': info['key'],
        'path': info['path'],
      });
    }
    await _load;
    if (!mounted) return;
    final names = found.keys.map((settingKey) => _databases[settingKey]?.name ?? settingKey).join(', ');
    final message = found.isEmpty ? ref.t('detect_none_found'): names;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _downloadDatabases async {
    // Every not-yet-configured database across all pipelines; the dialog itself
    // filters to the ones with an automatic download option and lets the user
    // pick a subset ("todos ou alguns").
    final missing = _databases.values.where((d) => !d.configured).toList;
    await showDownloadAllDatabasesDialog(
      context: context,
      ref: ref,
      api: ref.read(apiClientProvider),
      pipelineId: kHubDownloadBatchId, // hub-level batch key; databases are shared across pipelines
      missing: missing,
      onChanged: _load,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (_loading) return const Center(child: CircularProgressIndicator);
    if (_error != null) return Center(child: Text('${ref.t('error_prefix')}: $_error'));

    ref.listen(localeProvider, (previous, next) {
      if (previous != next && _databasesRaw.isNotEmpty) {
        setState( => _databases = _buildDatabasesMap(_databasesRaw));
      }
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ref.t('databases_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(ref.t('databases_subtitle'), style: TextStyle(color: colors.textSecondary)),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.folder_special_outlined, color: colors.primaryDark),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ref.t('detect_in_folder'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(ref.t('detect_in_folder_hint'), style: TextStyle(fontSize: 12, color: colors.textSecondary)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(onPressed: _detectInFolder, child: Text(ref.t('detect_button'))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.cloud_download_outlined, color: colors.primaryDark),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ref.t('download_dbs_card_title'),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(ref.t('download_dbs_card_hint'),
                            style: TextStyle(fontSize: 12, color: colors.textSecondary)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Builder(builder: (context) {
                    final batch = ref.watch(downloadAllProvider)[kHubDownloadBatchId];
                    final running = batch?.phase == DownloadAllPhase.running;
                    if (running) {
                      final total = batch!.targets.length;
                      final done = batch.dbStatus.values.where((s) => s == DbBatchState.done || s == DbBatchState.error || s == DbBatchState.skipped).length;
                      return FilledButton.icon(
                        onPressed: _downloadDatabases, // reattaches -> opens progress dialog
                        icon: const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                        label: Text('${ref.t('download_dbs_running')}  ($done/$total)'),
                      );
                    }
                    return FilledButton.icon(
                      onPressed: _downloadDatabases,
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(ref.t('download_dbs_button')),
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final db in _databases.values)
                SizedBox(
                  key: ValueKey(db.settingKey),
                  width: 400,
                  child: DatabaseCard(
                    api: ref.read(apiClientProvider),
                    pipelineId: db.usedBy?.first ?? '',
                    database: db,
                    onChanged: _load,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
