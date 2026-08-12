import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Registers a results folder the app never produced, so it appears in the
/// Plots tab like any run launched here.
///
/// This exists because the Plots tab lists runs from the app's own settings
/// file, which means a perfectly good results folder is invisible to it
/// whenever the app has no record of the run: output produced on another
/// machine or a cluster, a settings file that was reset, or a table built
/// entirely outside OmniOmics by someone who only wants the plotting.
///
/// Deliberately two steps, scan then confirm: the scan is read-only and
/// reports exactly which inputs were recognised and which analyses they
/// unlock, so a folder that holds nothing usable costs the user a message
/// instead of a dead entry in the run list.
class ImportPlotFolderDialog extends ConsumerStatefulWidget {
  const ImportPlotFolderDialog({super.key});

  @override
  ConsumerState<ImportPlotFolderDialog> createState() => _ImportPlotFolderDialogState();
}

class _ImportPlotFolderDialogState extends ConsumerState<ImportPlotFolderDialog> {
  String? _folder;
  Map<String, dynamic>? _scan;
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    setState(() { _folder = path; _scan = null; _error = null; });
    await _scanFolder();
  }

  Future<void> _scanFolder() async {
    if (_folder == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.post('/api/plots/scan_folder', {'folder': _folder}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() { _scan = res; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  Future<void> _import() async {
    setState(() { _busy = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      await api.post('/api/plots/import_folder', {'folder': _folder});
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  /// Why the scan found nothing, in the user's own terms. The backend's
  /// `reason` is a machine token; a bare "no_recognised_input" tells someone
  /// staring at a folder full of files precisely nothing about what to do.
  String _reasonText() {
    switch (_scan?['reason']) {
      case 'not_a_directory':
        return ref.t('plots_import_reason_not_dir');
      case 'empty_directory':
        return ref.t('plots_import_reason_empty');
      default:
        return ref.t('plots_import_reason_unrecognised');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scan = _scan;
    final ok = scan != null && scan['ok'] == true;

    return AlertDialog(
      title: Text(ref.t('plots_import_title')),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref.t('plots_import_hint'), style: TextStyle(color: colors.textSecondary, fontSize: 12.5)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        color: colors.surfaceAlt,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(_folder ?? ref.t('plots_import_no_folder'),
                          style: TextStyle(fontSize: 12, color: _folder == null ? colors.textMuted : colors.textPrimary),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: Text(ref.t('plots_import_choose')),
                    onPressed: _busy ? null : _pick,
                  ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text('${ref.t('error_prefix')}: $_error', style: TextStyle(color: colors.statusError, fontSize: 12)),
              ],
              if (scan != null && !_busy) ...[
                const SizedBox(height: 16),
                if (!ok)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.statusError.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(_reasonText(), style: TextStyle(color: colors.statusError, fontSize: 12.5)),
                  )
                else
                  _buildResult(colors, scan),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(ref.t('cancel'))),
        FilledButton(
          onPressed: (ok && !_busy) ? _import : null,
          child: Text(ref.t('plots_import_confirm')),
        ),
      ],
    );
  }

  Widget _buildResult(AppPalette colors, Map<String, dynamic> scan) {
    final analyses = (scan['analyses'] as List? ?? const []).cast<Map<String, dynamic>>();
    final unavailable = (scan['analyses_unavailable'] as List? ?? const []).cast<Map<String, dynamic>>();
    final shapes = (scan['shapes'] as Map? ?? const {}).cast<String, dynamic>();
    final lang = ref.watch(localeProvider).languageCode;

    String analysisName(Map<String, dynamic> a) {
      final n = a['name'];
      if (n is Map) return (n[lang] ?? n['en'] ?? a['id']).toString();
      return (n ?? a['id']).toString();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: colors.statusDone),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${scan['pipeline_name']} — ${scan['detected_by']}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('${ref.t('plots_import_inputs_found')} (${shapes.length})',
            style: TextStyle(fontSize: 11, color: colors.textSecondary)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in shapes.entries)
              Tooltip(
                message: entry.value.toString(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.surfaceAlt,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: colors.border),
                  ),
                  child: Text(entry.key, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('${ref.t('plots_import_analyses_available')} (${analyses.length})',
            style: TextStyle(fontSize: 11, color: colors.textSecondary)),
        const SizedBox(height: 4),
        Text(analyses.map(analysisName).join(' · '), style: const TextStyle(fontSize: 12)),
        // Naming what is NOT available matters as much as what is: it is the
        // difference between "this folder is incomplete" and "the app is
        // broken" when an expected card fails to appear later.
        if (unavailable.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('${ref.t('plots_import_analyses_missing')} (${unavailable.length})',
              style: TextStyle(fontSize: 11, color: colors.textSecondary)),
          const SizedBox(height: 4),
          Text(unavailable.map(analysisName).join(' · '),
              style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ],
      ],
    );
  }
}
