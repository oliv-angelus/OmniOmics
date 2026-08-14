import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../theme/category_colors.dart';
import '../models/plot_analysis.dart';
import '../services/plot_gallery_provider.dart';

/// Everything this pipeline run has already produced, shown above the analysis
/// catalogue instead of being forgotten.
///
/// The Plots tab used to be a linear wizard -- pick one analysis, run it, look
/// at it, then "Nova análise" and start over -- so a finished plot had to be
/// discarded from the screen to make room for the next. Meanwhile the backend
/// had been recording every analysis run in plot_runs_store and serving them at
/// GET /api/plots/runs, which nothing in the app had ever called.
class PlotGallery extends ConsumerWidget {
  final String parentRunId;
  final String parentOutputDir;
  final List<PlotAnalysis> analyses;

  const PlotGallery({
    super.key,
    required this.parentRunId,
    required this.parentOutputDir,
    required this.analyses,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final async = ref.watch(plotRunsProvider(parentRunId));

    return async.when(
      loading: () => const SizedBox.shrink(),
      // A history that will not load is not worth an error banner above the
      // catalogue -- the catalogue still works, and running something new is
      // how the user would recover anyway.
      error: (_, _) => const SizedBox.shrink(),
      data: (runs) {
        final done = runs.where((r) => r['status'] == 'done').toList();
        if (done.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  ref.t('plots_gallery_title').toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 9),
                Text('${done.length}',
                    style: TextStyle(fontSize: 11, color: colors.textMuted)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: done.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _GalleryCard(
                  run: done[i],
                  analyses: analyses,
                  parentOutputDir: parentOutputDir,
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }
}

class _GalleryCard extends ConsumerWidget {
  final Map<String, dynamic> run;
  final List<PlotAnalysis> analyses;
  final String parentOutputDir;

  const _GalleryCard({
    required this.run,
    required this.analyses,
    required this.parentOutputDir,
  });

  /// The plot run's own folder.
  ///
  /// `add_plot_run` is called with `f"{analysis_id}_{timestamp}"` as the run's
  /// *name*, and `os.makedirs` creates a directory of exactly that name under
  /// `<parent output>/plots/` -- so the name is the folder, and no searching is
  /// needed.
  ///
  /// Worth stating because the obvious alternative is wrong: globbing
  /// `<analysis_id>_*` and taking the newest would give every card for the same
  /// analysis the same latest folder, so an older card would open the newer
  /// run's figures. Running one analysis twice with different parameters is
  /// normal and produces two entries that must resolve separately.
  String? _runDir() {
    final name = run['name'] as String?;
    if (name == null || name.isEmpty) return null;
    return '$parentOutputDir${Platform.pathSeparator}plots'
        '${Platform.pathSeparator}$name';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final english = ref.watch(localeProvider).languageCode == 'en';
    final analysisId = run['analysis_id'] as String?;
    final analysis = analyses.where((a) => a.id == analysisId).firstOrNull;
    final shape = analysis?.inputShape ?? '';
    final style = shape.shapeTagStyle;
    final brightness = Theme.of(context).brightness;
    final dir = _runDir();
    // Deliberately no existsSync() here: build runs on every rebuild and on
    // every scroll of the horizontal list, and stat-ing the disk each time to
    // decide whether a card is tappable is not worth it. _open reports a
    // missing folder instead.

    return SizedBox(
      width: 200,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: dir == null ? null : () => _open(dir),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.insights, size: 20, color: style.fg(brightness)),
                const SizedBox(height: 8),
                Text(
                  analysis?.name ?? analysisId ?? '',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.25),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                if (shape.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: style.bg(brightness),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      shape.shapeTagLabel(english),
                      style: TextStyle(
                          fontSize: 9.5, fontWeight: FontWeight.w700, color: style.fg(brightness)),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  _when(run['started_at']),
                  style: TextStyle(fontSize: 10.5, color: colors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _when(dynamic ts) {
    if (ts is! num) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _open(String dir) async {
    // xdg-open on the folder: the plot itself is a PNG the user will want in
    // whatever viewer or figure editor they already use, and the folder also
    // holds the data.json and the .rds the export step reads.
    if (!Directory(dir).existsSync()) return;
    try {
      await Process.run('xdg-open', [dir]);
    } on ProcessException {
      // Nothing to recover here; the path is shown on the card either way.
    }
  }
}
