import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Native, interactive replacement for magma_mag_summary's old static
/// per-MAG report-card image -- per the user's own request: a real summary
/// table (MIMAG completeness/contamination/rRNA/tRNA, taxonomy, abundance)
/// with each MAG's AMR/virulence genes expandable to show the real sequence,
/// rather than a picture that stops being readable past two or three MAGs.
/// Reads magma_mag_summary.R's own `records` list from data.json -- see that
/// script's header comment for exactly what each field means.
class MagSummaryTable extends ConsumerStatefulWidget {
  final List<dynamic> records;

  const MagSummaryTable({super.key, required this.records});

  @override
  ConsumerState<MagSummaryTable> createState() => _MagSummaryTableState();
}

class _MagSummaryTableState extends ConsumerState<MagSummaryTable> {
  final Set<String> _expanded = {};

  Color _tierColor(AppPalette colors, String? tier) {
    if (tier == null) return colors.textMuted;
    if (tier.startsWith('High')) return colors.statusDone;
    if (tier == 'Medium') return colors.statusQueued;
    if (tier == 'Low') return colors.statusError;
    return colors.textMuted;
  }

  String _fmtPct(num? v) => v == null ? '—' : '${v.toStringAsFixed(2)}%';
  String _fmtMb(num? v) => v == null ? '—' : '${(v / 1e6).toStringAsFixed(2)} Mb';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final records = widget.records.cast<Map<String, dynamic>>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in records) _buildMagCard(colors, r),
      ],
    );
  }

  Widget _buildMagCard(AppPalette colors, Map<String, dynamic> r) {
    final mag = r['mag'] as String;
    final tier = r['mimag_quality'] as String?;
    final genes = (r['genes'] as List? ?? const []).cast<Map<String, dynamic>>();
    final abundance = (r['abundance'] as List? ?? const []).cast<Map<String, dynamic>>();
    final lineage = (r['lineage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final isOpen = _expanded.contains(mag);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (isOpen) {
                _expanded.remove(mag);
              } else {
                _expanded.add(mag);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(isOpen ? Icons.expand_less : Icons.expand_more, size: 20, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Text(mag, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  Expanded(
                    child: _statCell(ref.t('plots_mag_completeness'), _fmtPct((r['completeness'] as num?)),
                        colors, null),
                  ),
                  Expanded(
                    child: _statCell(ref.t('plots_mag_contamination'), _fmtPct((r['contamination'] as num?)),
                        colors, null),
                  ),
                  Expanded(
                    child: _statCell(ref.t('plots_mag_size'), _fmtMb((r['genome_size'] as num?)), colors, null),
                  ),
                  Expanded(
                    flex: 2,
                    child: _statCell('MIMAG', tier ?? '—', colors, _tierColor(colors, tier)),
                  ),
                  Expanded(
                    flex: 2,
                    child: _statCell(
                      ref.t('plots_mag_genes'),
                      genes.isEmpty ? ref.t('plots_mag_none') : '${genes.length}',
                      colors,
                      genes.isEmpty ? colors.textMuted : colors.statusError,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  _detailRow(colors, ref.t('plots_mag_sample'), (r['sample'] as String?) ?? '—'),
                  _detailRow(colors, ref.t('plots_mag_dereplicated'),
                      (r['dereplicated'] == true) ? ref.t('yes') : ref.t('no')),
                  _detailRow(colors, ref.t('plots_mag_lineage'), _lineageText(lineage)),
                  _detailRow(colors, ref.t('plots_mag_rrna'), _rrnaText(r)),
                  _detailRow(colors, ref.t('plots_mag_trna'), '${r['trna_types'] ?? '—'}'),
                  // GUNC's chimerism check, shown right alongside MIMAG per
                  // the user's own request -- a separate, complementary
                  // check (Orakov et al. 2021), not folded into the MIMAG
                  // tier itself (see build_magma_mag_table.R).
                  _detailRow(colors, ref.t('plots_mag_gunc'), _guncText(r)),
                  if (abundance.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(ref.t('plots_mag_abundance'),
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textSecondary)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        for (final a in abundance)
                          Text('${a['sample']}: ${(a['rel_abundance'] as num?)?.toStringAsFixed(2) ?? '—'}%',
                              style: TextStyle(fontSize: 11.5, color: colors.textSecondary)),
                      ],
                    ),
                  ],
                  if (genes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(ref.t('plots_mag_genes'),
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textSecondary)),
                    const SizedBox(height: 4),
                    for (final g in genes) _GeneRow(gene: g),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statCell(String label, String value, AppPalette colors, Color? valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 9.5, color: colors.textMuted)),
        Text(value,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: valueColor ?? colors.textPrimary)),
      ],
    );
  }

  Widget _detailRow(AppPalette colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textSecondary)),
          ),
          Expanded(child: Text(value, style: TextStyle(fontSize: 11.5, color: colors.textPrimary))),
        ],
      ),
    );
  }

  String _lineageText(Map<String, dynamic> lineage) {
    final parts = ['phylum', 'class', 'order', 'family', 'genus', 'species']
        .map((k) => (lineage[k] as String?) ?? '')
        .where((v) => v.isNotEmpty)
        .toList();
    return parts.isEmpty ? '—' : parts.join(' > ');
  }

  String _rrnaText(Map<String, dynamic> r) {
    final s5 = r['rrna_5s']; final s16 = r['rrna_16s']; final s23 = r['rrna_23s'];
    if (s5 == null && s16 == null && s23 == null) return ref.t('plots_mag_unavailable');
    return '5S ${s5 ?? '?'} / 16S ${s16 ?? '?'} / 23S ${s23 ?? '?'}';
  }

  String _guncText(Map<String, dynamic> r) {
    final pass = r['gunc_pass'];
    final css = r['gunc_css'] as num?;
    if (pass == null) return ref.t('plots_mag_unavailable');
    final verdict = pass == true ? ref.t('plots_mag_gunc_pass') : ref.t('plots_mag_gunc_fail');
    final cssTxt = css == null ? '' : '  (CSS ${css.toStringAsFixed(2)})';
    return '$verdict$cssTxt';
  }
}

/// One AMR/virulence gene hit, with its real sequence revealed on tap --
/// selectable/copyable text, wrapped in a monospace scroll view since a
/// protein sequence routinely runs past what a fixed-width row can show.
class _GeneRow extends ConsumerStatefulWidget {
  final Map<String, dynamic> gene;
  const _GeneRow({required this.gene});

  @override
  ConsumerState<_GeneRow> createState() => _GeneRowState();
}

class _GeneRowState extends ConsumerState<_GeneRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final g = widget.gene;
    final sequence = g['sequence'] as String?;
    final hasSeq = sequence != null && sequence.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasSeq ? () => setState(() => _open = !_open): null,
            child: Row(
              children: [
                if (hasSeq) Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: colors.textMuted),
                if (!hasSeq) const SizedBox(width: 16),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: (g['source'] == 'amrfinder' ? colors.statusError: colors.statusQueued).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text((g['source'] as String? ?? '').toUpperCase(),
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
                          color: g['source'] == 'amrfinder' ? colors.statusError: colors.statusQueued)),
                ),
                const SizedBox(width: 6),
                Text(g['gene'] as String? ?? '—', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                if (g['product'] != null) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(g['product'] as String, style: TextStyle(fontSize: 11, color: colors.textSecondary),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
                if (g['pct_identity'] != null)
                  Text('${(g['pct_identity'] as num).toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 10.5, color: colors.textMuted)),
              ],
            ),
          ),
          if (_open && hasSeq)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 4, bottom: 6, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    g['sequence_type'] == 'protein' ? ref.t('plots_mag_sequence_protein'): ref.t('plots_mag_sequence_nucleotide'),
                    style: TextStyle(fontSize: 10, color: colors.textMuted),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colors.surfaceAlt,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colors.border),
                    ),
                    child: SelectableText(
                      sequence,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
