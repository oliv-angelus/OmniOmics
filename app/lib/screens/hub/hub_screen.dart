import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/category_colors.dart';
import '../../models/pipeline_summary.dart';
import '../../widgets/extra_tag.dart';

final pipelinesProvider = FutureProvider<List<PipelineSummary>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final raw = await api.get('/api/pipelines') as List;
  return raw.map((e) => PipelineSummary.fromJson(e as Map<String, dynamic>)).toList;
});

class HubScreen extends ConsumerWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pipelinesAsync = ref.watch(pipelinesProvider);
    final colors = context.colors;

    return pipelinesAsync.when(
      loading:  => const Center(child: CircularProgressIndicator),
      error: (err, _) => Center(child: Text('${ref.t('hub_load_error')}: $err')),
      data: (pipelines) {
        // placeholderCategories is the full "coming soon" wishlist -- filter
        // out whichever ones a real pipeline already covers (e.g. DOGMA ships
        // metatranscriptomics today), so a real pipeline's card never sits
        // next to a redundant "coming soon" placeholder for the same layer.
        final realCategoryIds = pipelines.map((p) => p.category).toSet;
        final visiblePlaceholders =
            placeholderCategories.where((c) => !realCategoryIds.contains(c.id)).toList;
        return Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref.t('hub_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(ref.t('hub_subtitle'), style: TextStyle(color: colors.textSecondary)),
              const SizedBox(height: 24),
              Expanded(
                child: GridView.builder(
                  itemCount: pipelines.length + visiblePlaceholders.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 320,
                    mainAxisExtent: 230,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemBuilder: (context, i) {
                    if (i < pipelines.length) {
                      return _PipelineCard(pipeline: pipelines[i]);
                    }
                    final category = visiblePlaceholders[i - pipelines.length];
                    return _PlaceholderCard(category: category);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PipelineCard extends ConsumerWidget {
  final PipelineSummary pipeline;
  const _PipelineCard({required this.pipeline});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final category = PipelineCategoryX.fromId(pipeline.category);
    final english = ref.watch(localeProvider).languageCode == 'en';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap:  {
          ref.read(embeddedPipelineProvider.notifier).state =
              EmbeddedPipelineRoute(pipelineId: pipeline.id, pipelineName: pipeline.name);
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: colors.primarySoft, borderRadius: BorderRadius.circular(10)),
                child: pipeline.icon.isNotEmpty
                    ? Image.asset(
                        pipeline.icon,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => Icon(Icons.science_outlined, color: colors.primaryDark),
                      ): Icon(Icons.science_outlined, color: colors.primaryDark),
              ),
              const SizedBox(height: 12),
              Text(pipeline.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              if (category != null || pipeline.tags.isNotEmpty)...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (category != null) _CategoryTag(category: category, english: english),
                    for (final tag in pipeline.tags) ExtraTag(tag: tag, english: english),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Expanded(
                child: Text(
                  pipeline.description,
                  style: TextStyle(color: colors.textSecondary, height: 1.3, fontSize: 12.5),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Align(alignment: Alignment.centerRight, child: Icon(Icons.arrow_forward, size: 18, color: colors.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceholderCard extends ConsumerWidget {
  final PipelineCategory category;
  const _PlaceholderCard({required this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final english = ref.watch(localeProvider).languageCode == 'en';
    return Opacity(
      opacity: 0.65,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: category.style.bg(Theme.of(context).brightness),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.hourglass_empty, color: category.style.fg(Theme.of(context).brightness)),
              ),
              const SizedBox(height: 12),
              Text(category.label(english), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _ComingSoonTag(english: english),
                  for (final tag in placeholderExtraTags[category] ?? const []) ExtraTag(tag: tag, english: english),
                ],
              ),
              const Spacer,
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryTag extends StatelessWidget {
  final PipelineCategory category;
  final bool english;
  const _CategoryTag({required this.category, required this.english});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: category.style.bg(brightness), borderRadius: BorderRadius.circular(6)),
      child: Text(
        category.label(english),
        style: TextStyle(color: category.style.fg(brightness), fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ComingSoonTag extends ConsumerWidget {
  final bool english;
  const _ComingSoonTag({required this.english});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(6)),
      child: Text(
        ref.t('coming_soon'),
        style: TextStyle(color: colors.textMuted, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
