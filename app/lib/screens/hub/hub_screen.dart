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
              const SizedBox(height: 18),
              _HubStats(pipelineCount: pipelines.length),
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

    final titleColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(ref.t('hub_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(ref.t('hub_subtitle'), style: TextStyle(color: colors.textSecondary)),
      ],
    );

    final chips = Wrap(
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
    );

    // A Wrap only ever sizes itself to its own content, so the chip row used
    // to sit wherever that content happened to land -- centred, short of the
    // right edge -- instead of reaching it. Expanded is what actually claims
    // the row's remaining width; Align then has real space to push the chips
    // flush against it.
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 760) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [titleColumn, const SizedBox(height: 14), chips],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleColumn,
          const SizedBox(width: 24),
          Expanded(child: Align(alignment: Alignment.centerRight, child: chips)),
        ],
      );
    });
  }
}

/// A quick-glance stat band under the Hub's title -- the same role
/// DatabaseBudget plays on the Databases screen (a real number right under a
/// plain title, instead of the title standing alone with nothing behind it).
/// Every number here is live: pipelines is the catalogue this session
/// actually loaded, the other two come straight off the same run list
/// [HubRecentJobs] renders below.
class _HubStats extends ConsumerWidget {
  final int pipelineCount;
  const _HubStats({required this.pipelineCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final runsAsync = ref.watch(recentRunsProvider);
    final running = runsAsync.value?.where((r) => r.isRunning).length;
    final total = runsAsync.value?.length;

    final items = [
      (ref.t('hub_stat_pipelines'), '$pipelineCount'),
      (ref.t('hub_stat_running'), running == null ? '—' : '$running'),
      (ref.t('hub_stat_runs'), total == null ? '—' : '$total'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(width: 1, height: 32, color: colors.border),
                ),
              _Stat(label: items[i].$1, value: items[i].$2),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: colors.textPrimary)),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: colors.textSecondary,
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

