import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../providers.dart';
import '../../models/job_entry.dart';
import '../../services/pipeline_run_provider.dart';

/// Watches the app-wide [pipelineRunProvider] instead of owning its own
/// WebSocket -- so leaving this screen (back button, switching to another
/// pipeline tab, etc.) never stops the run: the connection lives in the
/// provider, not in this widget's State. Reopening this screen just re-reads
/// whatever the provider has accumulated in the meantime.
class MonitorScreen extends ConsumerStatefulWidget {
  const MonitorScreen({super.key});

  @override
  ConsumerState<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends ConsumerState<MonitorScreen> {
  final _logScroll = ScrollController();

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _stop() async {
    await ref.read(pipelineRunProvider.notifier).stop();
  }

  String _statusText(PipelineRunState run) {
    if (run.stopped && !run.finished) return ref.t('monitor_stopping');
    if (!run.finished) return ref.t('monitor_running');
    if (run.stopped) return ref.t('monitor_stopped_by_user');
    if (run.exitCode == 0) return ref.t('monitor_done_success');
    return '${ref.t('monitor_finished_error_prefix')} ${run.exitCode})';
  }

  Color _statusColor(PipelineRunState run, AppPalette colors) {
    if (run.stopped) return run.finished ? colors.textMuted: colors.statusRunning;
    if (!run.finished) return colors.statusRunning;
    return run.exitCode == 0 ? colors.statusDone: colors.statusError;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final run = ref.watch(pipelineRunProvider);

    ref.listen(pipelineRunProvider, (previous, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });

    if (run == null) {
      return Column(
        children: [
          _MonitorHeader(title: ref.t('monitor_title_fallback')),
          Expanded(
            child: Center(child: Text(ref.t('monitor_no_run'), style: TextStyle(color: colors.textMuted))),
          ),
        ],
      );
    }

    // null -> indeterminate (animated) bar, which is only correct while still
    // actually running. Once finished, Snakemake may never have reported any
    // "X of Y steps" progress at all (e.g. aborted during conda env creation,
    // before running a single rule) -- without this, the bar keeps spinning
    // forever after a stop/error, looking like the pipeline is still going.
    final pct = run.stepsTotal > 0
        ? run.stepsDone / run.stepsTotal: (run.finished ? (run.exitCode == 0 && !run.stopped ? 1.0: 0.0): null);
    final jobs = run.jobs.values.toList()..sort((a, b) => b.jobid.compareTo(a.jobid));

    return Column(
      children: [
        _MonitorHeader(
          title: '${ref.t('monitor_running_title_prefix')} ${run.pipelineName}',
          actions: [
            if (!run.finished && !run.stopped)
              TextButton.icon(
                onPressed: _stop,
                icon: Icon(Icons.stop_circle_outlined, color: colors.statusError),
                label: Text(ref.t('stop_pipeline_button'), style: TextStyle(color: colors.statusError)),
              ),
          ],
        ),
        Expanded(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _statusText(run),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _statusColor(run, colors),
                          ),
                        ),
                        const Spacer(),
                        if (run.stepsTotal > 0)
                          Text('${run.stepsDone} / ${run.stepsTotal} ${ref.t('monitor_steps_suffix')}',
                              style: TextStyle(color: colors.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(value: pct, minHeight: 8),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: _StepTracker(jobs: jobs)),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 3, child: _LogConsole(log: run.log, scrollController: _logScroll)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Replaces the Scaffold+AppBar this screen used before it became embeddable
/// in AppShell's body (see embeddedMonitorProvider) -- a manual back button
/// instead of AppBar's automatic one, since there's no Navigator route to pop.
class _MonitorHeader extends ConsumerWidget {
  final String title;
  final List<Widget> actions;
  const _MonitorHeader({required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: ref.t('back_to_hub'),
            onPressed: () => ref.read(embeddedMonitorProvider.notifier).state = false,
          ),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),...actions,
        ],
      ),
    );
  }
}

class _StepTracker extends ConsumerWidget {
  final List<JobEntry> jobs;
  const _StepTracker({required this.jobs});

  String _statusLabel(WidgetRef ref, RunStatus status) => switch (status) {
        RunStatus.queued => ref.t('job_status_queued'),
        RunStatus.running => ref.t('job_status_running'),
        RunStatus.done => ref.t('job_status_done'),
        RunStatus.error => ref.t('job_status_error'),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    if (jobs.isEmpty) {
      return Center(child: Text(ref.t('monitor_waiting_jobs'), style: TextStyle(color: colors.textMuted)));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final job = jobs[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: job.status.bg(colors),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _StatusIcon(status: job.status),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.rule, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    if (job.sample != null) Text(job.sample!, style: TextStyle(fontSize: 11.5, color: colors.textSecondary)),
                  ],
                ),
              ),
              Text(_statusLabel(ref, job.status),
                  style: TextStyle(fontSize: 11, color: job.status.fg(colors), fontWeight: FontWeight.w600)),
            ],
          ),
        );
      },
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final RunStatus status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    switch (status) {
      case RunStatus.running:
        return SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: status.fg(colors)));
      case RunStatus.done:
        return Icon(Icons.check_circle, size: 18, color: status.fg(colors));
      case RunStatus.error:
        return Icon(Icons.error, size: 18, color: status.fg(colors));
      case RunStatus.queued:
        return Icon(Icons.schedule, size: 18, color: status.fg(colors));
    }
  }
}

class _LogConsole extends StatelessWidget {
  final List<String> log;
  final ScrollController scrollController;
  const _LogConsole({required this.log, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      color: colors.surfaceAlt,
      padding: const EdgeInsets.all(16),
      child: ListView.builder(
        controller: scrollController,
        itemCount: log.length,
        itemBuilder: (context, i) => Text(
          log[i],
          style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: colors.textSecondary, height: 1.4),
        ),
      ),
    );
  }
}
