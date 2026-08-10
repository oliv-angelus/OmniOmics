import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Single-file counterpart to [FolderPickerField] -- used where the input is
/// one specific file (e.g. a single reference genome fasta) rather than a
/// per-sample folder.
class FilePickerField extends ConsumerWidget {
  final String label;
  final String? path;
  final ValueChanged<String> onPicked;
  final List<String> extensions;
  /// The native file-dialog's own type-group label (e.g. macOS/GTK show this
  /// next to the extension filter) -- was hardcoded to 'FASTA' until the
  /// Plots tab needed this same widget for picking a metadata.tsv instead.
  final String typeGroupLabel;

  const FilePickerField({
    super.key,
    required this.label,
    required this.path,
    required this.onPicked,
    this.extensions = const ['fasta', 'fa', 'fna', 'fasta.gz', 'fa.gz', 'fna.gz'],
    this.typeGroupLabel = 'FASTA',
  });

  Future<void> _pick() async {
    final result = await openFile(
      acceptedTypeGroups: [XTypeGroup(label: typeGroupLabel, extensions: extensions)],
    );
    if (result != null) onPicked(result.path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _pick,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.description_outlined, size: 18, color: colors.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    path?.isNotEmpty == true ? path!: ref.t('select_file'),
                    style: TextStyle(
                      color: path?.isNotEmpty == true ? colors.textPrimary: colors.textMuted,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
