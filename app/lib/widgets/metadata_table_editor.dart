import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Editable spreadsheet-like preview of a picked metadata.tsv, shown
/// between "pick the file" and "build the phyloseq object from it" -- lets
/// the user fix an obvious mistake (a typo'd group label, a stray value, or
/// a typo'd COLUMN NAME) without leaving the app or re-picking a whole new
/// file, per the user's explicit request. Column headers are editable too
/// (real reported case: "vai que o usuário vê uma letra errada lá") -- they
/// aren't just labels here, every analysis's --group_var/--rank dropdown is
/// populated from them downstream, so a typo there is just as worth fixing
/// in place as a typo'd cell. v1 scope, deliberately: existing cell/header
/// VALUES only, no add/remove row/column -- a structural edit risks
/// producing a table shape that no longer matches the abundance table's own
/// sample set, an easier way to end up with a confusing downstream R error
/// than a typo, and the user's own call when asked was cell-values-only for
/// structural changes. Confirming hands the (possibly edited) TSV text back
/// to the caller, which writes it to its own copy on disk -- the
/// originally-picked file is never touched (see plot_workspace_screen.dart's
/// _confirmMetadata).
class MetadataTableEditor extends ConsumerStatefulWidget {
  final String rawTsv;
  final ValueChanged<String> onConfirm;
  final VoidCallback onCancel;

  const MetadataTableEditor({super.key, required this.rawTsv, required this.onConfirm, required this.onCancel});

  @override
  ConsumerState<MetadataTableEditor> createState() => _MetadataTableEditorState();
}

class _MetadataTableEditorState extends ConsumerState<MetadataTableEditor> {
  static const _colWidth = 170.0;

  List<TextEditingController> _headerControllers = const [];
  List<List<TextEditingController>> _controllers = const [];
  bool _parseError = false;

  @override
  void initState() {
    super.initState();
    _parse(widget.rawTsv);
  }

  @override
  void didUpdateWidget(MetadataTableEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawTsv != widget.rawTsv) {
      _disposeControllers();
      _parse(widget.rawTsv);
    }
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _disposeControllers() {
    for (final c in _headerControllers) {
      c.dispose();
    }
    for (final row in _controllers) {
      for (final c in row) {
        c.dispose();
      }
    }
  }

  void _parse(String raw) {
    // A trailing newline (near-universal on saved TSVs) would otherwise
    // parse as one extra, all-empty row -- dropped explicitly rather than
    // shown as a confusing blank editable row at the bottom.
    final lines = raw.split('\n').map((l) => l.replaceAll('\r', '')).toList();
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (lines.isEmpty) {
      setState(() {
        _parseError = true;
        _headerControllers = const [];
        _controllers = const [];
      });
      return;
    }
    final headerCells = lines.first.split('\t');
    final width = headerCells.length;
    final headerControllers = headerCells.map((h) => TextEditingController(text: h)).toList();
    final controllers = lines.skip(1).map((line) {
      final cells = line.split('\t');
      // A short row (fewer tabs than the header) pads with empty cells
      // instead of an index-out-of-range crash -- real TSVs exported from a
      // spreadsheet sometimes drop trailing empty cells.
      return List.generate(width, (i) => TextEditingController(text: i < cells.length ? cells[i]: ''));
    }).toList();
    setState(() {
      _parseError = width == 0;
      _headerControllers = headerControllers;
      _controllers = controllers;
    });
  }

  String _serialize() {
    final buffer = StringBuffer();
    buffer.writeln(_headerControllers.map((c) => c.text).join('\t'));
    for (final row in _controllers) {
      buffer.writeln(row.map((c) => c.text).join('\t'));
    }
    return buffer.toString();
  }

  Widget _headerCell(TextEditingController controller, AppPalette colors) {
    return SizedBox(
      width: _colWidth,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: TextField(
          controller: controller,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    if (_parseError) {
      return Text(ref.t('plots_metadata_parse_error'), style: TextStyle(color: colors.statusError));
    }

    final totalWidth = _headerControllers.length * _colWidth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(ref.t('plots_metadata_preview_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(ref.t('plots_metadata_preview_hint'), style: TextStyle(fontSize: 12.5, color: colors.textSecondary)),
        const SizedBox(height: 4),
        Text(
          '${_headerControllers.length} ${ref.t('plots_metadata_columns_label')} × ${_controllers.length} ${ref.t('plots_metadata_rows_label')}',
          style: TextStyle(fontSize: 11, color: colors.textMuted),
        ),
        const SizedBox(height: 12),
        Container(
          height: 420,
          decoration: BoxDecoration(border: Border.all(color: colors.border), borderRadius: BorderRadius.circular(8)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: totalWidth,
                  child: Column(
                    children: [
                      // Header row -- editable too (a typo'd column name is
                      // just as real a mistake as a typo'd cell, and these
                      // are exactly the names every analysis's
                      // --group_var/--rank dropdown gets populated from
                      // downstream), visually set apart with the app's
                      // surfaceAlt background so it still reads as "the
                      // header", not just another data row.
                      Container(
                        color: colors.surfaceAlt,
                        child: Row(children: _headerControllers.map((c) => _headerCell(c, colors)).toList()),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _controllers.length,
                          itemBuilder: (context, r) {
                            final row = _controllers[r];
                            return Container(
                              decoration: BoxDecoration(
                                border: Border(bottom: BorderSide(color: colors.border.withValues(alpha: 0.4))),
                                color: r.isOdd ? colors.surfaceAlt.withValues(alpha: 0.35): null,
                              ),
                              child: Row(
                                children: row.map((controller) => SizedBox(
                                          width: _colWidth,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                            child: TextField(
                                              controller: controller,
                                              style: const TextStyle(fontSize: 12.5),
                                              decoration: const InputDecoration(
                                                isDense: true,
                                                border: InputBorder.none,
                                                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                              ),
                                            ),
                                          ),
                                        )).toList(),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: Text(ref.t('plots_change_metadata'))),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () => widget.onConfirm(_serialize()),
              icon: const Icon(Icons.check),
              label: Text(ref.t('plots_metadata_confirm')),
            ),
          ],
        ),
      ],
    );
  }
}
