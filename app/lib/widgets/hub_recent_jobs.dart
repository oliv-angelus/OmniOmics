import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../models/run_record.dart';
import '../screens/hub/hub_screen.dart' show recentRunsProvider;

/// The five newest runs across every pipeline, on the Hub.
///
/// Same source as the Results tab's list (/api/runs, already newest-first), so
/// "Ver todos" is a jump to that tab rather than a different query.
class HubRecentJobs extends ConsumerStatefulWidget {
  const HubRecentJobs({super.key});

  @override
  ConsumerState<HubRecentJobs> createState() => _HubRecentJobsState();
}

class _HubRecentJobsState extends ConsumerState<HubRecentJobs> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Cheap -- it is a local JSON file, not a directory listing -- and it is
    // what keeps a running job's row moving without the Hub holding a socket.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) ref.invalidate(recentRunsProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _open(RunRecord run) {
    // A run whose folder is gone opens to nothing; the Results tab is where it
    // can be inspected and deleted deliberately, so send it there either way.
    if (run.isRunning) {
      ref.read(embeddedMonitorProvider.notifier).state = true;
      return;
    }
    _seeAll();
  }

  void _seeAll() {
    ref.read(selectedTabProvider.notifier).state = 2; // Results
    ref.read(embeddedPipelineProvider.notifier).state = null;
    ref.read(embeddedMonitorProvider.notifier).state = false;
    ref.read(embeddedPlotRunProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final runsAsync = ref.watch(recentRunsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    ref.t('hub_recent_jobs'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _seeAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: colors.primaryDark,
                  ),
                  child: Text(ref.t('hub_see_all'), style: const TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            runsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text('${ref.t('error_prefix')}: $e',
                    style: TextStyle(fontSize: 12, color: colors.statusError)),
              ),
              data: (runs) {
                if (runs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 26),
                    child: Center(
                      child: Text(
                        ref.t('hub_no_runs'),
                        style: TextStyle(fontSize: 12.5, color: colors.textMuted),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final shown = runs.take(5).toList();
                return Column(
                  children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: colors.border),
                      _JobRow(run: shown[i], onTap: () => _open(shown[i])),
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
}

class _JobRow extends ConsumerWidget {
  final RunRecord run;
  final VoidCallback onTap;
  const _JobRow({required this.run, required this.onTap});

  /// runs_store writes running | done | error | stopped. RunStatus has no
  /// `stopped` member, so it borrows the queued colour -- a run someone
  /// interrupted is neither a success nor a failure.
  (Color, String) _status(AppPalette colors, WidgetRef ref) => switch (run.status) {
        'running' => (colors.statusRunning, ref.t('results_status_running')),
        'done' => (colors.statusDone, ref.t('results_status_done')),
        'error' => (colors.statusError, ref.t('results_status_error')),
        'stopped' => (colors.statusQueued, ref.t('results_status_stopped')),
        _ => (colors.textMuted, run.status),
      };

  String _when(DateTime dt) {
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final (color, label) = _status(colors, ref);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(
          children: [
            if (run.isRunning)
              SizedBox(
                width: 9,
                height: 9,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${run.pipelineName} · ${run.name}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (run.isMissing) ...[
                        Icon(Icons.folder_off_outlined, size: 11, color: colors.statusError),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            ref.t('results_output_missing'),
                            style: TextStyle(fontSize: 11, color: colors.statusError),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ] else
                        Text(
                          _when(run.startedAtDate) +
                              (run.cores > 0 ? ' · ${run.cores} ${ref.t('hub_cores')}' : ''),
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
