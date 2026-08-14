import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/category_colors.dart';
import '../../models/pipeline_summary.dart';
import '../../models/run_record.dart';
import '../../widgets/hub_pipeline_card.dart';
import '../../widgets/hub_recent_jobs.dart';
import '../../widgets/hub_news_panel.dart';

final pipelinesProvider = FutureProvider<List<PipelineSummary>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final raw = await api.get('/api/pipelines') as List;
  return raw.map((e) => PipelineSummary.fromJson(e as Map<String, dynamic>)).toList();
});

/// Every run ever started, newest first -- the same list the Results tab shows.
/// Refreshed on a timer by the recent-jobs panel so a running job's progress
/// stays current without the Hub owning a socket.
final recentRunsProvider = FutureProvider.autoDispose<List<RunRecord>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final raw = await api.get('/api/runs') as List;
  return raw.map((e) => RunRecord.fromJson(e as Map<String, dynamic>)).toList();
});

final changelogProvider = FutureProvider<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/api/changelog') as List;
});

/// Scope filters, in the order they help a newcomer most.
///
/// Isolate vs. community leads because it is the biggest "which pipeline do I
/// actually need" fork -- see the note on those two tags in category_colors.dart.
/// The list below is only a *preference order*: the chips actually shown are
/// derived from the tags present on real pipelines and placeholders, so a new
/// tag in a manifest gets a working filter without touching this file.
const _tagOrder = [
  'isolate',
  'community',
  'prokaryote',
  'eukaryote',
  'hybrid',
  'short_only',
  'pangenome',
  'genotyping',
];

class HubScreen extends ConsumerStatefulWidget {
  const HubScreen({super.key});

  @override
  ConsumerState<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends ConsumerState<HubScreen> {
  /// null means "Todos".
  String? _filter;

  @override
  Widget build(BuildContext context) {
    final pipelinesAsync = ref.watch(pipelinesProvider);
    final colors = context.colors;

    return pipelinesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('${ref.t('hub_load_error')}: $err')),
      data: (pipelines) {
        // placeholderCategories is the full "coming soon" wishlist -- filter
        // out whichever ones a real pipeline already covers (e.g. DOGMA ships
        // metatranscriptomics today), so a real pipeline's card never sits
        // next to a redundant "coming soon" placeholder for the same layer.
        final realCategoryIds = pipelines.map((p) => p.category).toSet();
        final visiblePlaceholders =
            placeholderCategories.where((c) => !realCategoryIds.contains(c.id)).toList();

        final tags = _availableTags(pipelines, visiblePlaceholders);
        final shownPipelines = pipelines.where((p) => _matches(p.tags)).toList();
        final shownPlaceholders = visiblePlaceholders
            .where((c) => _matches(placeholderExtraTags[c] ?? const []))
            .toList();

        return SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(colors: colors, tags: tags, selected: _filter, onSelect: (t) {
                setState(() => _filter = t);
              }),
              const SizedBox(height: 24),
              if (shownPipelines.isEmpty && shownPlaceholders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Text(ref.t('hub_no_match'), style: TextStyle(color: colors.textMuted)),
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: shownPipelines.length + shownPlaceholders.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    // Taller than before: the card now carries tags, the step
                    // track and a full-width action button under the
                    // description.
                    maxCrossAxisExtent: 340,
                    mainAxisExtent: 300,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemBuilder: (context, i) {
                    if (i < shownPipelines.length) {
                      return HubPipelineCard(pipeline: shownPipelines[i]);
                    }
                    return HubPlaceholderCard(category: shownPlaceholders[i - shownPipelines.length]);
                  },
                ),
              const SizedBox(height: 28),
              LayoutBuilder(builder: (context, constraints) {
                // Side by side while there is room for both to stay readable;
                // stacked below that rather than squeezed.
                if (constraints.maxWidth < 900) {
                  return const Column(
                    children: [
                      HubRecentJobs(),
                      SizedBox(height: 16),
                      HubNewsPanel(),
                    ],
                  );
                }
                return const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: HubRecentJobs()),
                    SizedBox(width: 16),
                    Expanded(flex: 5, child: HubNewsPanel()),
                  ],
                );
              }),
            ],
          ),
        );
      },
    );
  }

  bool _matches(List<String> tags) => _filter == null || tags.contains(_filter);

  /// Union of every tag in play, ordered by [_tagOrder] with anything
  /// unrecognised appended alphabetically -- so an unknown tag still gets a
  /// chip instead of silently becoming unfilterable.
  List<String> _availableTags(List<PipelineSummary> pipelines, List<PipelineCategory> placeholders) {
    final present = <String>{
      for (final p in pipelines) ...p.tags,
      for (final c in placeholders) ...(placeholderExtraTags[c] ?? const []),
    };
    final ordered = _tagOrder.where(present.contains).toList();
    final extra = (present.toList()..sort()).where((t) => !_tagOrder.contains(t));
    return [...ordered, ...extra];
  }
}

class _Header extends ConsumerWidget {
  final AppPalette colors;
  final List<String> tags;
  final String? selected;
  final ValueChanged<String?> onSelect;

  const _Header({
    required this.colors,
    required this.tags,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final english = ref.watch(localeProvider).languageCode == 'en';
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 24,
      runSpacing: 14,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ref.t('hub_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(ref.t('hub_subtitle'), style: TextStyle(color: colors.textSecondary)),
          ],
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Wrap(
            spacing: 7,
            runSpacing: 7,
            alignment: WrapAlignment.end,
            children: [
              _Chip(
                label: ref.t('hub_filter_all'),
                selected: selected == null,
                onTap: () => onSelect(null),
              ),
              for (final tag in tags)
                _Chip(
                  label: tag.extraTagLabel(english),
                  selected: selected == tag,
                  onTap: () => onSelect(selected == tag ? null : tag),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: selected ? colors.primary : colors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? colors.primary : colors.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected
                  ? (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF0B1416)
                      : Colors.white)
                  : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

