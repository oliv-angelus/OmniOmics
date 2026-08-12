import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// What OmniOmics is, who wrote it, how to cite it, and under what licence.
///
/// Everything here is either about the application or is the minimum academic
/// identification a reviewer needs (name, affiliation, ORCID). Contact details
/// beyond the institutional identifiers are deliberately absent: this screen
/// ships inside a binary that anyone can download, and personal data does not
/// belong in it.
///
/// Links are shown as selectable text with a copy button rather than opened in
/// a browser. Launching a URL would mean another platform-channel dependency
/// for a handful of links, and a copyable ORCID works everywhere -- including
/// on a headless or restricted machine, which is where this tends to run.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  /// Kept in one place so the release, CITATION.cff and this screen cannot
  /// drift apart. Update all three together.
  static const String version = '0.0.1-alpha';
  static const String orcid = 'https://orcid.org/0000-0003-0831-447X';
  static const String repo = 'https://github.com/oliv-angelus/OmniOmics';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(ref.t('about_title'),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: colors.statusRunningBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('${ref.t('about_version_label')} $version',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600,
                            color: colors.statusRunning)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // The alpha caveat sits at the top, not in a footnote: someone
              // deciding whether to trust a result should meet it first.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.statusRunningBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.statusRunning.withValues(alpha: 0.35)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.science_outlined, size: 18, color: colors.statusRunning),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(ref.t('about_alpha_note'),
                          style: TextStyle(fontSize: 12.5, height: 1.5, color: colors.textPrimary)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _Section(
                colors: colors,
                icon: Icons.hub_outlined,
                title: ref.t('about_what'),
                body: ref.t('about_what_body'),
              ),
              const SizedBox(height: 20),

              _Section(
                colors: colors,
                icon: Icons.person_outline,
                title: ref.t('about_author'),
                body: '${ref.t('about_author_name')}\n\n'
                    '${ref.t('about_author_role')}\n\n'
                    '${ref.t('about_author_research')}',
                links: [
                  _Link('ORCID', orcid),
                  _Link(ref.watch(localeProvider).languageCode == 'pt' ? 'Repositório' : 'Repository', repo),
                ],
              ),
              const SizedBox(height: 20),

              _Section(
                colors: colors,
                icon: Icons.format_quote_outlined,
                title: ref.t('about_cite'),
                body: ref.t('about_cite_body'),
              ),
              const SizedBox(height: 20),

              _Section(
                colors: colors,
                icon: Icons.gavel_outlined,
                title: ref.t('about_license'),
                body: ref.t('about_license_body'),
              ),
              const SizedBox(height: 20),

              _Section(
                colors: colors,
                icon: Icons.construction_outlined,
                title: ref.t('about_tools'),
                body: ref.t('about_tools_body'),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _Link {
  final String label;
  final String url;
  const _Link(this.label, this.url);
}

class _Section extends StatelessWidget {
  final AppPalette colors;
  final IconData icon;
  final String title;
  final String body;
  final List<_Link> links;

  const _Section({
    required this.colors,
    required this.icon,
    required this.title,
    required this.body,
    this.links = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: colors.textSecondary),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(body,
              style: TextStyle(fontSize: 13, height: 1.6, color: colors.textPrimary)),
          if (links.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final l in links) _LinkChip(colors: colors, link: l)],
            ),
          ],
        ],
      ),
    );
  }
}

class _LinkChip extends ConsumerWidget {
  final AppPalette colors;
  final _Link link;
  const _LinkChip({required this.colors, required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${link.label}: ',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textSecondary)),
          SelectableText(link.url,
              style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace')),
          const SizedBox(width: 6),
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: link.url));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ref.t('about_copied')), duration: const Duration(seconds: 2)),
              );
            },
            child: Icon(Icons.copy, size: 14, color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
