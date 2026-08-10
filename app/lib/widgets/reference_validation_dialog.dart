import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Shown after SIGMA's per-sample reference matching (`reference_dir/<sample>/`
/// by folder name) leaves one or more samples without a match -- forces an
/// explicit choice per sample (skip, or pick a file manually) instead of
/// silently running those samples without a reference. [overrides] and
/// [skipped] are mutated in place as the user resolves each row; the caller
/// just needs to persist/re-check afterwards.
Future<void> showReferenceValidationDialog({
  required BuildContext context,
  required WidgetRef ref,
  required List<String> unmatchedSamples,
  required Map<String, String> overrides,
  required Set<String> skipped,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ReferenceValidationDialog(
      samples: unmatchedSamples,
      overrides: overrides,
      skipped: skipped,
    ),
  );
}

class _ReferenceValidationDialog extends ConsumerStatefulWidget {
  final List<String> samples;
  final Map<String, String> overrides;
  final Set<String> skipped;

  const _ReferenceValidationDialog({
    required this.samples,
    required this.overrides,
    required this.skipped,
  });

  @override
  ConsumerState<_ReferenceValidationDialog> createState() => _ReferenceValidationDialogState();
}

class _ReferenceValidationDialogState extends ConsumerState<_ReferenceValidationDialog> {
  Future<void> _pickFile(String sample) async {
    final result = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'FASTA', extensions: ['fasta', 'fa', 'fna', 'fasta.gz', 'fa.gz', 'fna.gz']),
      ],
    );
    if (result == null) return;
    setState(() {
      widget.skipped.remove(sample);
      widget.overrides[sample] = result.path;
    });
  }

  void _skip(String sample) {
    setState(() {
      widget.overrides.remove(sample);
      widget.skipped.add(sample);
    });
  }

  bool get _allResolved =>
      widget.samples.every((s) => widget.skipped.contains(s) || widget.overrides.containsKey(s));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      title: Text(ref.t('reference_validation_title')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref.t('reference_validation_body'), style: TextStyle(fontSize: 12.5, color: colors.textSecondary)),
              const SizedBox(height: 16),
              for (final sample in widget.samples) _sampleRow(sample, colors),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _allResolved ?  => Navigator.of(context).pop: null,
          child: Text(ref.t('reference_validation_done')),
        ),
      ],
    );
  }

  Widget _sampleRow(String sample, dynamic colors) {
    final overridePath = widget.overrides[sample];
    final isSkipped = widget.skipped.contains(sample);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  overridePath != null
                      ? Icons.check_circle: isSkipped
                          ? Icons.block: Icons.help_outline,
                  size: 16,
                  color: overridePath != null
                      ? colors.statusDone: isSkipped
                          ? colors.textMuted: colors.statusError,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(sample, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
              ],
            ),
            if (overridePath != null)...[
              const SizedBox(height: 4),
              Text(overridePath, style: TextStyle(fontSize: 11.5, color: colors.textSecondary), overflow: TextOverflow.ellipsis),
            ] else if (isSkipped)...[
              const SizedBox(height: 4),
              Text(ref.t('reference_validation_skipped'),
                  style: TextStyle(fontSize: 11.5, color: colors.textMuted, fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(onPressed: () => _skip(sample), child: Text(ref.t('reference_validation_skip_button'))),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _pickFile(sample), child: Text(ref.t('reference_validation_pick_button'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
