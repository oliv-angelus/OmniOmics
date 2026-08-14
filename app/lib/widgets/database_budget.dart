import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../services/system_info_provider.dart';
import 'database_card.dart' show formatDbSize;

/// Free space on the disk holding the machine's root, or null before the first
/// /ws/system reading arrives.
final freeDiskGbProvider = Provider<num?>((ref) {
  final info = ref.watch(systemInfoProvider);
  final free = info?['disk']?['free_gb'];
  return free is num ? free : null;
});

/// Whether a selection of this size would not fit. False while free space is
/// still unknown -- refusing a download because a reading has not arrived yet
/// would be worse than letting it start.
///
/// A plain function rather than a `Provider.family`: the argument is a running
/// total that changes with every tick of a checkbox, and a family keyed on it
/// would cache one provider per distinct value and never release them.
bool isOverBudget(WidgetRef ref, num selectedGb) {
  final free = ref.watch(freeDiskGbProvider);
  return free != null && selectedGb > free;
}

/// The disk budget for the Databases screen.
///
/// The catalogue is around 425 GB across 26 databases, and most machines have
/// far less free -- so the question the screen has to answer first is not
/// "which databases exist" but "what fits". One bar, scaled to installed plus
/// the real free space, with the overflow in red when a selection does not fit
/// and the download button disabled behind it: better to find out here than
/// eighty gigabytes into a transfer.
class DatabaseBudget extends ConsumerWidget {
  final num installedGb;
  final num selectedGb;
  final num catalogGb;
  final int installedCount;
  final int selectedCount;
  final int catalogCount;

  const DatabaseBudget({
    super.key,
    required this.installedGb,
    required this.selectedGb,
    required this.catalogGb,
    required this.installedCount,
    required this.selectedCount,
    required this.catalogCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final free = ref.watch(freeDiskGbProvider);
    final total = ref.watch(systemInfoProvider)?['disk']?['total_gb'];

    final over = free == null ? 0.0 : (selectedGb - free).clamp(0, double.infinity).toDouble();
    final fits = free == null ? selectedGb : (selectedGb < free ? selectedGb : free);
    // The bar spans installed + the whole free space (+ any overflow), so the
    // empty part of it is literally "what would be left".
    final scale = installedGb + (free ?? selectedGb) + over;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    ref.t('db_budget_title'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (free != null)
                  Text.rich(
                    TextSpan(
                      style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
                      children: [
                        TextSpan(
                          text: formatDbSize(free - fits),
                          style: TextStyle(
                              fontWeight: FontWeight.w600, color: colors.textPrimary),
                        ),
                        TextSpan(text: ' ${ref.t('db_budget_after')}'),
                        if (total is num)
                          TextSpan(text: ' · ${ref.t('db_budget_disk_of')} ${formatDbSize(total)}'),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 20,
                child: Row(
                  children: [
                    if (scale > 0) ...[
                      Expanded(
                        flex: (installedGb / scale * 1000).round().clamp(0, 1000),
                        child: Container(color: colors.statusDone),
                      ),
                      Expanded(
                        flex: (fits / scale * 1000).round().clamp(0, 1000),
                        child: Container(color: colors.primary),
                      ),
                      Expanded(
                        flex: (over / scale * 1000).round().clamp(0, 1000),
                        child: Container(color: colors.statusError),
                      ),
                    ],
                    Expanded(
                      flex: scale > 0
                          ? (((free ?? 0) - fits) / scale * 1000).round().clamp(0, 1000)
                          : 1000,
                      child: Container(color: colors.surfaceAlt),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 11),
            Wrap(
              spacing: 18,
              runSpacing: 7,
              children: [
                _Legend(
                    color: colors.statusDone,
                    label: ref.t('db_budget_installed'),
                    value: '${formatDbSize(installedGb)} ($installedCount)'),
                _Legend(
                    color: colors.primary,
                    label: ref.t('db_budget_selected'),
                    value: '${formatDbSize(selectedGb)} ($selectedCount)'),
                if (free != null)
                  _Legend(
                      color: colors.surfaceAlt,
                      label: ref.t('db_budget_free'),
                      value: formatDbSize((free - selectedGb).clamp(0, double.infinity))),
                _Legend(
                    color: Colors.transparent,
                    label: ref.t('db_budget_catalog'),
                    value: '${formatDbSize(catalogGb)} ($catalogCount)'),
              ],
            ),
            if (over > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 17, color: colors.statusError),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ref.t('db_budget_over').replaceAll('@size', formatDbSize(over)),
                      style: TextStyle(fontSize: 12.5, color: colors.statusError),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  const _Legend({required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (color != Colors.transparent) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 7),
        ],
        Text('$label ', style: TextStyle(fontSize: 11.5, color: colors.textSecondary)),
        Text(value,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textPrimary)),
      ],
    );
  }
}
