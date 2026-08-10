import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// Structural placeholder -- author/lab bio and publication list are meant to
/// be filled in later; the sections and layout are real, the copy is not.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ref.t('about_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),
            _Section(
              colors: colors,
              icon: Icons.person_outline,
              title: ref.t('about_author'),
              placeholder: ref.t('about_author_placeholder'),
            ),
            const SizedBox(height: 20),
            _Section(
              colors: colors,
              icon: Icons.groups_outlined,
              title: ref.t('about_lab'),
              placeholder: ref.t('about_lab_placeholder'),
            ),
            const SizedBox(height: 20),
            _Section(
              colors: colors,
              icon: Icons.menu_book_outlined,
              title: ref.t('about_publications'),
              placeholder: ref.t('about_publications_placeholder'),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final AppPalette colors;
  final IconData icon;
  final String title;
  final String placeholder;

  const _Section({required this.colors, required this.icon, required this.title, required this.placeholder});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: colors.primaryDark),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            Text(placeholder, style: TextStyle(color: colors.textMuted, fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }
}
