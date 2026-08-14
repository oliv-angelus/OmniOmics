import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// The run's provenance report, fetched as data rather than parsed out of
/// run_report.txt. Null id yields nothing.
final runReportProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, runId) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/api/runs/$runId/report') as Map<String, dynamic>;
});

/// The report as four copyable panels: the drafted Methods paragraph, the tool
/// and version table, the numbered references with DOIs, and the database
/// fingerprints.
///
/// This is the most valuable thing the app produces for someone writing a
/// paper, and until now it was a .txt in the file tree that opened in an
/// external editor -- when it was written at all (it never was; see
/// tool_versions.py's rule scan).
class RunReportPanels extends ConsumerWidget {
  final String runId;
  const RunReportPanels({super.key, required this.runId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final async = ref.watch(runReportProvider(runId));

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(32),
        child: Text('${ref.t('error_prefix')}: $e',
            style: TextStyle(color: colors.statusError, fontSize: 13)),
      ),
      data: (data) {
        if (data['available'] != true) {
          return Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                data['reason'] == 'imported'
                    ? ref.t('res_report_unavailable_imported')
                    : ref.t('res_report_unavailable_running'),
                style: TextStyle(color: colors.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final methods = (data['methods'] as List? ?? const []).cast<String>();
        final tools = (data['tools'] as List? ?? const []).cast<Map<String, dynamic>>();
        final refs = (data['references'] as List? ?? const []).cast<Map<String, dynamic>>();
        final dbs = (data['databases'] as List? ?? const []).cast<Map<String, dynamic>>();

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          children: [
            _Panel(
              title: ref.t('res_methods'),
              hint: ref.t('res_methods_hint'),
              copyText: methods.join('\n\n'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: colors.statusRunningBg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 16, color: colors.statusRunning),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(ref.t('res_methods_note'),
                              style: TextStyle(fontSize: 11.5, height: 1.45, color: colors.textSecondary)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 13),
                  for (final p in methods)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 11),
                      child: SelectableText(p,
                          style: const TextStyle(fontSize: 13, height: 1.6)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _Panel(
              title: ref.t('res_tools_title'),
              hint: '${tools.length}',
              // Tab-separated, so it pastes into a spreadsheet or a
              // supplementary table rather than needing to be retyped.
              copyText: [
                '${ref.t('res_col_tool')}\t${ref.t('res_col_version')}\t${ref.t('res_col_stage')}\t${ref.t('res_col_params')}',
                ...tools.map((t) =>
                    '${t['name']}\t${t['version']}\t${t['category']}\t${t['parameters']}'),
              ].join('\n'),
              child: _ToolsTable(tools: tools),
            ),
            const SizedBox(height: 14),
            _Panel(
              title: ref.t('res_refs_title'),
              hint: '${refs.length}',
              copyText: refs
                  .map((r) => '[${r['n']}] ${r['text']}'
                      '${r['doi'] != null ? ' https://doi.org/${r['doi']}' : ''}')
                  .join('\n'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in refs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text('[${r['n']}]',
                                style: TextStyle(fontSize: 12, color: colors.textMuted)),
                          ),
                          Expanded(
                            child: SelectableText.rich(
                              TextSpan(
                                style: TextStyle(
                                    fontSize: 12, height: 1.5, color: colors.textSecondary),
                                children: [
                                  TextSpan(text: r['text'] as String? ?? ''),
                                  if (r['doi'] != null)
                                    TextSpan(
                                      text: '  https://doi.org/${r['doi']}',
                                      style: TextStyle(color: colors.primaryDark),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (dbs.isNotEmpty) ...[
              const SizedBox(height: 14),
              _Panel(
                title: ref.t('res_dbs_title'),
                hint: ref.t('res_dbs_hint'),
                copyText: dbs
                    .map((d) => '${d['name']}\n'
                        '  ${ref.t('res_db_path')}: ${d['path']}\n'
                        '  ${ref.t('res_db_version')}: ${d['version'] ?? '-'}\n'
                        '  ${ref.t('res_db_fingerprint')}: ${d['fingerprint']}')
                    .join('\n'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final d in dbs) _DbRow(db: d, colors: colors),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ToolsTable extends ConsumerWidget {
  final List<Map<String, dynamic>> tools;
  const _ToolsTable({required this.tools});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final head = TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.9, color: colors.textMuted);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 26,
        horizontalMargin: 0,
        headingRowHeight: 30,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 46,
        dividerThickness: 0.6,
        columns: [
          DataColumn(label: Text(ref.t('res_col_tool').toUpperCase(), style: head)),
          DataColumn(label: Text(ref.t('res_col_version').toUpperCase(), style: head)),
          DataColumn(label: Text(ref.t('res_col_stage').toUpperCase(), style: head)),
          DataColumn(label: Text(ref.t('res_col_params').toUpperCase(), style: head)),
        ],
        rows: [
          for (final t in tools)
            DataRow(cells: [
              DataCell(Text(t['name'] as String? ?? '',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              DataCell(Text(t['version'] as String? ?? '',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary))),
              DataCell(Text(t['category'] as String? ?? '',
                  style: TextStyle(fontSize: 12, color: colors.textMuted))),
              DataCell(ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(t['parameters'] as String? ?? '',
                    style: TextStyle(
                        fontSize: 11.5, fontFamily: 'monospace', color: colors.textSecondary)),
              )),
            ]),
        ],
      ),
    );
  }
}

class _DbRow extends ConsumerWidget {
  final Map<String, dynamic> db;
  final AppPalette colors;
  const _DbRow({required this.db, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget kv(String k, String v, {bool mono = false}) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: colors.textMuted)),
              ),
              Expanded(
                child: SelectableText(v,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: mono ? 'monospace' : null,
                        color: colors.textSecondary)),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(db['name'] as String? ?? '',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          kv(ref.t('res_db_path'), db['path'] as String? ?? '', mono: true),
          kv(
            ref.t('res_db_version'),
            db['version'] as String? ??
                (db['version_known'] == true ? '-' : ref.t('res_db_version_unknown')),
          ),
          kv(ref.t('res_db_fingerprint'), db['fingerprint'] as String? ?? '', mono: true),
        ],
      ),
    );
  }
}

class _Panel extends ConsumerStatefulWidget {
  final String title;
  final String hint;
  final String copyText;
  final Widget child;
  const _Panel({
    required this.title,
    required this.hint,
    required this.copyText,
    required this.child,
  });

  @override
  ConsumerState<_Panel> createState() => _PanelState();
}

class _PanelState extends ConsumerState<_Panel> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.copyText));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                Text(widget.title.toUpperCase(),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: colors.textSecondary)),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(widget.hint,
                      style: TextStyle(fontSize: 11, color: colors.textMuted)),
                ),
                OutlinedButton.icon(
                  onPressed: _copy,
                  icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
                  label: Text(_copied ? ref.t('res_copied') : ref.t('res_copy')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _copied ? colors.statusDone : colors.textPrimary,
                    side: BorderSide(color: _copied ? colors.statusDone : colors.border),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(16), child: widget.child),
        ],
      ),
    );
  }
}
