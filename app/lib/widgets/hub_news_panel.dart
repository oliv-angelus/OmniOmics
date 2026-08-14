import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../models/manifest_i18n.dart';
import '../screens/hub/hub_screen.dart' show changelogProvider;

/// Release notes on the Hub, from docs/changelog.yaml via /api/changelog.
///
/// A file shipped with the app rather than a remote feed: it has to work on a
/// machine with no internet, and nothing about a user's install should leave
/// their computer to fetch news.
class HubNewsPanel extends ConsumerWidget {
  const HubNewsPanel({super.key});

  /// Enough to show the current release and a glimpse of the previous one
  /// without the panel outgrowing the recent-jobs list beside it.
  static const int maxEntries = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final lang = ref.watch(localeProvider).languageCode;
    final async = ref.watch(changelogProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ref.t('hub_news'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                    child: SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
              // A missing or unreadable changelog is not worth an error state on
              // the Hub -- the panel is context around the pipelines, not the
              // point of the screen.
              error: (_, _) => _empty(ref, colors),
              data: (releases) {
                final rows = <Widget>[];
                for (final release in releases) {
                  if (rows.length >= maxEntries) break;
                  final r = release as Map<String, dynamic>;
                  // An entry the app does not yet identify as: CITATION.cff is
                  // the single source for the version, and announcing a number
                  // ahead of it would have the news panel contradict the About
                  // tab, the generated citation and the .deb.
                  final version = r['unreleased'] == true
                      ? ref.t('hub_news_unreleased')
                      : 'v${r['version'] as String? ?? ''}';
                  for (final entry in (r['entries'] as List? ?? const [])) {
                    if (rows.length >= maxEntries) break;
                    final text = localizedManifestText(entry, lang);
                    if (text.isEmpty) continue;
                    rows.add(_Entry(version: version, text: text, colors: colors));
                  }
                }
                if (rows.isEmpty) return _empty(ref, colors);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0) const SizedBox(height: 11),
                      rows[i],
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(WidgetRef ref, AppPalette colors) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 26),
        child: Center(
          child: Text(ref.t('hub_no_news'),
              style: TextStyle(fontSize: 12.5, color: colors.textMuted)),
        ),
      );
}

class _Entry extends StatelessWidget {
  final String version;
  final String text;
  final AppPalette colors;
  const _Entry({required this.version, required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            color: colors.primarySoft,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            version,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: colors.primaryDark,
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(child: _MarkdownBold(text: text, colors: colors)),
      ],
    );
  }
}

/// The changelog leans on `**bold**` and `` `code` `` for the few words that
/// carry each entry. Pulling in a markdown package for two inline spans would
/// be more dependency than the feature is worth, so this renders exactly those
/// two and leaves everything else as written.
class _MarkdownBold extends StatelessWidget {
  final String text;
  final AppPalette colors;
  const _MarkdownBold({required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: 12.5, height: 1.45, color: colors.textSecondary);
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');
    var index = 0;

    for (final m in pattern.allMatches(text)) {
      if (m.start > index) {
        spans.add(TextSpan(text: text.substring(index, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: m.group(1),
          style: TextStyle(fontWeight: FontWeight.w600, color: colors.textPrimary),
        ));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: colors.textPrimary),
        ));
      }
      index = m.end;
    }
    if (index < text.length) spans.add(TextSpan(text: text.substring(index)));

    return RichText(text: TextSpan(style: base, children: spans));
  }
}
