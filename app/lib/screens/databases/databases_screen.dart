import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../models/database.dart';
import '../../widgets/database_card.dart';
import '../../widgets/database_budget.dart';
import '../../widgets/download_all_databases_dialog.dart';
import '../../services/database_download_all_provider.dart';

/// Hub-level database configuration: every reference database across every
/// pipeline, deduplicated by setting_key -- a database MAGMA and SIGMA both
/// use (CheckM2, GTDB-Tk,...) is configured once here instead of separately
/// in each pipeline's own Launch screen, which now just shows a status check.
///
/// The screen is organised around disk space, because that is the binding
/// constraint: the full catalogue is roughly 425 GB across 26 databases, more
/// than most machines have free. A budget bar at the top adds up what is
/// installed and what is ticked, against the real free space from /ws/system,
/// and refuses a batch that does not fit.
class DatabasesScreen extends ConsumerStatefulWidget {
  const DatabasesScreen({super.key});

  @override
  ConsumerState<DatabasesScreen> createState() => _DatabasesScreenState();
}

class _DatabasesScreenState extends ConsumerState<DatabasesScreen> {
  /// Raw `/api/databases` entries, kept so flipping the language toggle can
  /// re-derive [_databases] (description is locale-dependent) without a
  /// network round-trip.
  List<dynamic> _databasesRaw = [];
  Map<String, DatabaseDef> _databases = {};
  bool _loading = true;
  String? _error;

  final Set<String> _selected = {};
  /// setting_key -> the size that row is currently counting, which follows the
  /// download option the user picked rather than the database's headline figure.
  final Map<String, num> _sizes = {};
  String _query = '';
  String? _pipelineFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Only the very first load blanks the screen with a spinner. Reloads
    // triggered afterwards (e.g. `onChanged` from validating/picking a path
    // on one card) must not unmount the whole list -- doing so tears down
    // every DatabaseCard, including ones with an in-progress download,
    // and their dispose closes that download's WebSocket.
    final isInitialLoad = _databasesRaw.isEmpty;
    if (isInitialLoad) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final api = ref.read(apiClientProvider);
      final raw = await api.get('/api/databases') as List;
      if (!mounted) return;
      setState(() {
        _databasesRaw = raw;
        _databases = _buildDatabasesMap(raw);
        _loading = false;
        // A database that just finished downloading is no longer a candidate.
        _selected.removeWhere((k) => _databases[k]?.configured ?? false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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
      // Keyed by setting_key (not source_key) so each shared database is one row.
      map[entry['setting_key'] as String] = def;
    }
    return map;
  }

  Future<void> _detectInFolder() async {
    final baseDir = await getDirectoryPath();
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
    await _load();
    if (!mounted) return;
    final names = found.keys.map((settingKey) => _databases[settingKey]?.name ?? settingKey).join(', ');
    final message = found.isEmpty ? ref.t('detect_none_found') : names;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Hands the ticked rows to the batch downloader that already exists -- it
  /// has always accepted a subset, but until now the only way in was a dialog
  /// offering "everything missing", with no way to choose against free space.
  Future<void> _downloadSelected() async {
    final targets = _selected
        .map((k) => _databases[k])
        .whereType<DatabaseDef>()
        .where((d) => !d.configured)
        .toList();
    if (targets.isEmpty) return;
    await showDownloadAllDatabasesDialog(
      context: context,
      ref: ref,
      api: ref.read(apiClientProvider),
      pipelineId: kHubDownloadBatchId,
      missing: targets,
      onChanged: _load,
    );
  }

  num get _installedGb => _databases.values
      .where((d) => d.configured)
      .fold<num>(0, (sum, d) => sum + (_sizes[d.settingKey] ?? d.sizeGb));

  num get _selectedGb => _selected.fold<num>(
      0, (sum, k) => sum + (_sizes[k] ?? _databases[k]?.sizeGb ?? 0));

  num get _catalogGb =>
      _databases.values.fold<num>(0, (sum, d) => sum + (_sizes[d.settingKey] ?? d.sizeGb));

  bool _matches(DatabaseDef d) {
    if (_pipelineFilter != null && !(d.usedBy?.contains(_pipelineFilter) ?? false)) {
      return false;
    }
    if (_query.isEmpty) return true;
    final hay = '${d.name} ${d.description} ${d.usedBy?.join(' ') ?? ''}'.toLowerCase();
    return hay.contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${ref.t('error_prefix')}: $_error'));

    ref.listen(localeProvider, (previous, next) {
      if (previous != next && _databasesRaw.isNotEmpty) {
        setState(() => _databases = _buildDatabasesMap(_databasesRaw));
      }
    });

    final shown = _databases.values.where(_matches).toList();
    // Exactly half the catalogue is shared, and shared databases are the best
    // value per gigabyte -- configure CheckM2 once and both MAGMA and SIGMA
    // have it -- so they lead. This is a fact of the data, not an arrangement:
    // the split comes from used_by, and it moves on its own when a manifest
    // starts or stops referencing something.
    final shared = shown.where((d) => (d.usedBy?.length ?? 0) > 1).toList();
    final single = shown.where((d) => (d.usedBy?.length ?? 0) <= 1).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ref.t('databases_title'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(ref.t('databases_subtitle'), style: TextStyle(color: colors.textSecondary)),
          const SizedBox(height: 20),
          DatabaseBudget(
            installedGb: _installedGb,
            selectedGb: _selectedGb,
            catalogGb: _catalogGb,
            installedCount: _databases.values.where((d) => d.configured).length,
            selectedCount: _selected.length,
            catalogCount: _databases.length,
          ),
          const SizedBox(height: 16),
          _Toolbar(
            query: _query,
            pipelineFilter: _pipelineFilter,
            pipelines: _pipelineCounts(),
            selectedCount: _selected.length,
            selectedGb: _selectedGb,
            overBudget: isOverBudget(ref, _selectedGb),
            onQuery: (q) => setState(() => _query = q.trim().toLowerCase()),
            onPipeline: (p) => setState(() => _pipelineFilter = p),
            onDetect: _detectInFolder,
            onDownload: _downloadSelected,
          ),
          const SizedBox(height: 18),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                  child: Text(ref.t('db_no_match'), style: TextStyle(color: colors.textMuted))),
            )
          else if (_pipelineFilter != null)
            _Group(
              title: _pipelineFilter!.toUpperCase(),
              hint: ref
                  .t('db_group_pipeline_hint')
                  .replaceAll('@n', '${shown.length}')
                  .replaceAll('@size', formatDbSize(shown.fold<num>(
                      0, (s, d) => s + (_sizes[d.settingKey] ?? d.sizeGb)))),
              onSelectAll: _selectable(shown).isEmpty ? null : () => _toggleGroup(shown),
              allSelected: _selectable(shown).isNotEmpty &&
                  _selectable(shown).every(_selected.contains),
              children: shown.map(_row).toList(),
            )
          else ...[
            if (shared.isNotEmpty)
              _Group(
                title: ref.t('db_group_shared'),
                hint: ref.t('db_group_shared_hint').replaceAll('@n', '${shared.length}'),
                onSelectAll: _selectable(shared).isEmpty ? null : () => _toggleGroup(shared),
                allSelected: _selectable(shared).isNotEmpty &&
                    _selectable(shared).every(_selected.contains),
                children: shared.map(_row).toList(),
              ),
            if (single.isNotEmpty) ...[
              const SizedBox(height: 20),
              _Group(
                title: ref.t('db_group_own'),
                hint: ref.t('db_group_own_hint').replaceAll('@n', '${single.length}'),
                onSelectAll: _selectable(single).isEmpty ? null : () => _toggleGroup(single),
                allSelected: _selectable(single).isNotEmpty &&
                    _selectable(single).every(_selected.contains),
                children: single.map(_row).toList(),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Map<String, int> _pipelineCounts() {
    final counts = <String, int>{};
    for (final d in _databases.values) {
      for (final p in d.usedBy ?? const <String>[]) {
        counts[p] = (counts[p] ?? 0) + 1;
      }
    }
    return Map.fromEntries(counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  /// Keys in [group] that are actually fetchable: not already on disk, and with
  /// an automatic download to run.
  Set<String> _selectable(List<DatabaseDef> group) => group
      .where((d) => !d.configured && d.downloadOptions.isNotEmpty)
      .map((d) => d.settingKey)
      .toSet();

  void _toggleGroup(List<DatabaseDef> group) {
    final keys = _selectable(group);
    if (keys.isEmpty) return;
    setState(() {
      if (keys.every(_selected.contains)) {
        _selected.removeAll(keys);
      } else {
        _selected.addAll(keys);
      }
    });
  }

  Widget _row(DatabaseDef db) => DatabaseCard(
        key: ValueKey(db.settingKey),
        api: ref.read(apiClientProvider),
        pipelineId: db.usedBy?.first ?? '',
        database: db,
        selected: _selected.contains(db.settingKey),
        onSelectedChanged: (v) => setState(() {
          if (v) {
            _selected.add(db.settingKey);
          } else {
            _selected.remove(db.settingKey);
          }
        }),
        onSizeChanged: (size) {
          if (_sizes[db.settingKey] == size) return;
          setState(() => _sizes[db.settingKey] = size);
        },
        onChanged: _load,
      );
}

class _Group extends ConsumerWidget {
  final String title;
  final String hint;
  final List<Widget> children;

  /// Null when nothing in this group can be selected (all configured, or none
  /// has an automatic download). Restores the convenience the old "download
  /// everything missing" card had, without the part where you could not see
  /// what it would cost.
  final VoidCallback? onSelectAll;
  final bool allSelected;

  const _Group({
    required this.title,
    required this.hint,
    required this.children,
    this.onSelectAll,
    this.allSelected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                            color: colors.textSecondary)),
                    Text(hint, style: TextStyle(fontSize: 12, color: colors.textMuted)),
                  ],
                ),
              ),
              if (onSelectAll != null)
                TextButton(
                  onPressed: onSelectAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: colors.primaryDark,
                  ),
                  child: Text(
                      allSelected ? ref.t('results_clear_selection') : ref.t('plots_select_all'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
            ],
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, color: colors.border),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends ConsumerWidget {
  final String query;
  final String? pipelineFilter;
  final Map<String, int> pipelines;
  final int selectedCount;
  final num selectedGb;
  final bool overBudget;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onPipeline;
  final VoidCallback onDetect;
  final VoidCallback onDownload;

  const _Toolbar({
    required this.query,
    required this.pipelineFilter,
    required this.pipelines,
    required this.selectedCount,
    required this.selectedGb,
    required this.overBudget,
    required this.onQuery,
    required this.onPipeline,
    required this.onDetect,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Chip(
              label: ref.t('db_filter_all'),
              selected: pipelineFilter == null,
              onTap: () => onPipeline(null),
            ),
            for (final entry in pipelines.entries)
              _Chip(
                label: entry.key.toUpperCase(),
                count: entry.value,
                selected: pipelineFilter == entry.key,
                onTap: () => onPipeline(pipelineFilter == entry.key ? null : entry.key),
              ),
          ],
        ),
        SizedBox(
          width: 220,
          height: 38,
          child: TextField(
            onChanged: onQuery,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18, color: colors.textMuted),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              hintText: ref.t('db_search'),
              hintStyle: TextStyle(fontSize: 13, color: colors.textMuted),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        // Once a toolbar button rather than a card of its own: an occasional
        // action that was taking the same visual weight as the 26 databases.
        OutlinedButton.icon(
          onPressed: onDetect,
          icon: const Icon(Icons.folder_special_outlined, size: 17),
          label: Text(ref.t('detect_button')),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11)),
        ),
        FilledButton.icon(
          onPressed: (selectedCount == 0 || overBudget) ? null : onDownload,
          icon: const Icon(Icons.download, size: 17),
          label: Text(selectedCount == 0
              ? ref.t('db_download_selected')
              : ref
                  .t('db_download_n')
                  .replaceAll('@n', '$selectedCount')
                  .replaceAll('@size', formatDbSize(selectedGb))),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: selected ? colors.primary : colors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? colors.primary : colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? (Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF0B1416)
                          : Colors.white)
                      : colors.textSecondary,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: (selected
                            ? (Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF0B1416)
                                : Colors.white)
                            : colors.textMuted)
                        .withValues(alpha: 0.75),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
