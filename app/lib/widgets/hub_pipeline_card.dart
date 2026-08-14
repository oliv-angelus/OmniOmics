import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../theme/category_colors.dart';
import '../models/pipeline_summary.dart';
import 'extra_tag.dart';

/// One pipeline on the Hub. Hovering lifts the card and turns its border the
/// accent colour -- a per-card `shape` overriding cardTheme's default, so the
/// theme itself needs no change.
class HubPipelineCard extends ConsumerStatefulWidget {
  final PipelineSummary pipeline;
  const HubPipelineCard({super.key, required this.pipeline});

  @override
  ConsumerState<HubPipelineCard> createState() => _HubPipelineCardState();
}

class _HubPipelineCardState extends ConsumerState<HubPipelineCard> {
  bool _hovering = false;

  void _open() {
    ref.read(embeddedPipelineProvider.notifier).state = EmbeddedPipelineRoute(
      pipelineId: widget.pipeline.id,
      pipelineName: widget.pipeline.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pipeline = widget.pipeline;
    final category = PipelineCategoryX.fromId(pipeline.category);
    final english = ref.watch(localeProvider).languageCode == 'en';
    final accent = category?.style.accent ?? colors.primary;
    // Someone who has asked for less motion still gets the border change; only
    // the travel is dropped.
    final lift = _hovering && !MediaQuery.disableAnimationsOf(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedSlide(
        offset: lift ? const Offset(0, -0.008) : Offset.zero,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: _hovering ? colors.primary : colors.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _open,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                            color: colors.primarySoft, borderRadius: BorderRadius.circular(10)),
                        child: pipeline.icon.isNotEmpty
                            ? Image.asset(
                                pipeline.icon,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stack) =>
                                    Icon(Icons.science_outlined, color: colors.primaryDark),
                              )
                            : Icon(Icons.science_outlined, color: colors.primaryDark),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(pipeline.name,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                            if (category != null || pipeline.tags.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 5,
                                runSpacing: 5,
                                children: [
                                  if (category != null)
                                    _CategoryTag(category: category, english: english),
                                  for (final tag in pipeline.tags)
                                    ExtraTag(tag: tag, english: english),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 50,
                    child: Text(
                      pipeline.description,
                      style: TextStyle(color: colors.textSecondary, height: 1.35, fontSize: 12.5),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Spacer(),
                  if (pipeline.steps.isNotEmpty)
                    StepTrack(steps: pipeline.steps, accent: accent),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _open,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.primaryDark,
                        side: BorderSide(color: colors.primary),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      child: Text(ref.t('hub_start_analysis')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One segment per stage in the manifest's `categories`, with the first and
/// last named and the total called out.
///
/// The segment count is the point: the pipelines run from 5 stages (DEFINE,
/// PRISM) to 14 (SIGMA), and that depth difference is exactly what helps
/// someone choose between them. A fixed number of step icons would hide it, and
/// drawing fourteen icons for abstract stages would be noise.
class StepTrack extends ConsumerWidget {
  final List<String> steps;
  final Color accent;
  const StepTrack({super.key, required this.steps, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: Tooltip(
                  message: '${i + 1}. ${steps[i]}',
                  waitDuration: const Duration(milliseconds: 300),
                  child: Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: dark ? 0.95 : 0.85),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            Flexible(
              child: Text(
                steps.first,
                style: TextStyle(fontSize: 10.5, color: colors.textMuted),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (steps.length > 1) ...[
              Icon(Icons.arrow_right, size: 13, color: colors.textMuted),
              Flexible(
                child: Text(
                  steps.last,
                  style: TextStyle(fontSize: 10.5, color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                '${steps.length} ${ref.t('hub_steps')}',
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w600, color: colors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// An omics layer with no pipeline yet. Deliberately gets no hover treatment --
/// it is not clickable, and a hover affordance on a dead card is a lie.
class HubPlaceholderCard extends ConsumerWidget {
  final PipelineCategory category;
  const HubPlaceholderCard({super.key, required this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final english = ref.watch(localeProvider).languageCode == 'en';
    final brightness = Theme.of(context).brightness;

    return Opacity(
      opacity: 0.65,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: category.style.bg(brightness),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.hourglass_empty, color: category.style.fg(brightness)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(category.label(english),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            _ComingSoonTag(colors: colors),
                            for (final tag in placeholderExtraTags[category] ?? const [])
                              ExtraTag(tag: tag, english: english),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
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
      decoration: BoxDecoration(
          color: category.style.bg(brightness), borderRadius: BorderRadius.circular(6)),
      child: Text(
        category.label(english),
        style: TextStyle(
            color: category.style.fg(brightness), fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ComingSoonTag extends ConsumerWidget {
  final AppPalette colors;
  const _ComingSoonTag({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(6)),
      child: Text(
        ref.t('coming_soon'),
        style: TextStyle(color: colors.textMuted, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
