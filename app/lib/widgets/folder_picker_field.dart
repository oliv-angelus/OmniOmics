import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

class FolderPickerField extends ConsumerWidget {
  final String label;
  final String? path;
  final ValueChanged<String> onPicked;

  const FolderPickerField({
    super.key,
    required this.label,
    required this.path,
    required this.onPicked,
  });

  Future<void> _pick async {
    final result = await getDirectoryPath;
    if (result != null) onPicked(result);
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
                Icon(Icons.folder_open, size: 18, color: colors.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    path?.isNotEmpty == true ? path!: ref.t('select_folder'),
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
