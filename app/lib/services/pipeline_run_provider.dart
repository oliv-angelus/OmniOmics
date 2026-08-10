import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../models/job_entry.dart';
import '../theme/app_theme.dart';
import 'ws_client.dart';

/// Snapshot of an in-progress (or just-finished) pipeline run. Held by
/// [PipelineRunNotifier] instead of by MonitorScreen's State, so the run
/// survives Navigator push/pop -- closing the Monitor screen must not stop
/// the pipeline (only /stop, or the whole app closing, should).
class PipelineRunState {
  final String pipelineId;
  final String pipelineName;
  /// The runs_store history id for this run, once the backend has assigned
  /// one (arrives via the 'run_id' event shortly after start) -- lets the
  /// Results page tell this provider "the run you're showing was just
  /// deleted" instead of the two staying out of sync.
  final String? runId;
  final Map<int, JobEntry> jobs;
  final List<String> log;
  final int stepsDone;
  final int stepsTotal;
  final bool finished;
  final int? exitCode;
  /// True once the user has pressed Parar for this run -- set optimistically
  /// by stop, before the backend even confirms. Snakemake exits with a
  /// negative code (SIGTERM = -15) when killed this way, which is otherwise
  /// indistinguishable from a real crash; this flag is what lets the UI show
  /// "Interrompido pelo usuário" instead of "Finalizado com erro".
  final bool stopped;

  const PipelineRunState({
    required this.pipelineId,
    required this.pipelineName,
    this.runId,
    required this.jobs,
    required this.log,
    required this.stepsDone,
    required this.stepsTotal,
    required this.finished,
    required this.exitCode,
    this.stopped = false,
  });

  PipelineRunState copyWith({
    String? runId,
    Map<int, JobEntry>? jobs,
    List<String>? log,
    int? stepsDone,
    int? stepsTotal,
    bool? finished,
    int? exitCode,
    bool? stopped,
  }) {
    return PipelineRunState(
      pipelineId: pipelineId,
      pipelineName: pipelineName,
      runId: runId ?? this.runId,
      jobs: jobs ?? this.jobs,
      log: log ?? this.log,
      stepsDone: stepsDone ?? this.stepsDone,
      stepsTotal: stepsTotal ?? this.stepsTotal,
      finished: finished ?? this.finished,
      exitCode: exitCode ?? this.exitCode,
      stopped: stopped ?? this.stopped,
    );
  }
}

/// Owns the WebSocket connection to a running pipeline. Lives at the
/// ProviderScope root (not tied to any screen's widget lifecycle), so
/// navigating away from and back to the Monitor screen just re-reads the
/// same accumulated state instead of losing it or cancelling the run.
///
/// The backend mirrors this on its side: /ws/pipelines/{pid}/run detaches
/// the process's lifetime from any one socket, replaying history to whoever
/// (re)connects -- so even if this notifier's socket drops and reconnects,
/// nothing is lost.
class PipelineRunNotifier extends Notifier<PipelineRunState?> {
  WsClient? _ws;

  @override
  PipelineRunState? build => null;

  bool get isRunning => state != null && !state!.finished;

  void start({
    required String pipelineId,
    required String pipelineName,
    required String configPath,
    required int cores,
    required List<String> omitFrom,
  }) {
    _ws?.close;
    state = PipelineRunState(
      pipelineId: pipelineId,
      pipelineName: pipelineName,
      jobs: const {},
      log: const [],
      stepsDone: 0,
      stepsTotal: 0,
      finished: false,
      exitCode: null,
    );

    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/pipelines/$pipelineId/run'));
    _ws = ws;
    ws.send({'config_path': configPath, 'cores': cores, 'omit_from': omitFrom, 'pipeline_name': pipelineName});
    _listen(ws);
  }

  void _listen(WsClient ws) {
    ws.events.listen((event) {
      final current = state;
      if (current == null) return;
      switch (event['type']) {
        case 'run_id':
          state = current.copyWith(runId: event['id'] as String?);
          break;
        case 'log':
          state = current.copyWith(log: [...current.log, (event['text'] as String).trimRight]);
          break;
        case 'job_start':
          final id = event['jobid'] as int;
          final jobs = Map<int, JobEntry>.of(current.jobs);
          jobs[id] = JobEntry(
            jobid: id,
            rule: event['rule'] as String,
            sample: event['sample'] as String?,
            status: RunStatus.running,
          );
          state = current.copyWith(jobs: jobs);
          break;
        case 'job_done':
          final id = event['jobid'] as int;
          final jobs = Map<int, JobEntry>.of(current.jobs);
          jobs[id]?.status = RunStatus.done;
          state = current.copyWith(jobs: jobs);
          break;
        case 'job_error':
          final id = event['jobid'] as int;
          final jobs = Map<int, JobEntry>.of(current.jobs);
          if (jobs.containsKey(id)) {
            jobs[id]!.status = RunStatus.error;
          } else {
            jobs[id] = JobEntry(
              jobid: id,
              rule: event['rule'] as String,
              sample: event['sample'] as String?,
              status: RunStatus.error,
            );
          }
          state = current.copyWith(jobs: jobs);
          break;
        case 'progress':
          state = current.copyWith(stepsDone: event['done'] as int, stepsTotal: event['total'] as int);
          break;
        case 'done':
          // Snakemake gets SIGTERM'd across its whole process group at once
          // (itself + whatever it's currently shelling out to, e.g. `conda env
          // create`) -- there's no guarantee it gets a chance to print anything
          // about being interrupted before dying, so the log can otherwise just
          // stop mid-sentence with no visible sign anything happened.
          state = current.copyWith(
            finished: true,
            exitCode: event['code'] as int?,
            log: current.stopped
                ? [...current.log, translate('monitor_stopped_log', ref.read(localeProvider).languageCode)]: current.log,
          );
          break;
      }
    });
  }

  Future<void> stop async {
    final current = state;
    if (current == null) return;
    state = current.copyWith(
      stopped: true,
      log: [...current.log, translate('monitor_stopping_log', ref.read(localeProvider).languageCode)],
    );
    final api = ref.read(apiClientProvider);
    await api.post('/api/pipelines/${current.pipelineId}/stop');
  }

  /// Clears the banner/state once the user has seen a finished run -- does not
  /// touch the backend (the run is already over by the time this is called).
  void dismiss {
    _ws?.close;
    _ws = null;
    state = null;
  }

  /// Clears the banner if it's currently showing one of these history ids -- /// called by the Results page right after deleting run(s), so a deleted
  /// run's pill doesn't linger at the top of the app with nothing to show
  /// for it anymore.
  void dismissIfIdIn(Set<String> deletedRunIds) {
    final id = state?.runId;
    if (id != null && deletedRunIds.contains(id)) dismiss;
  }
}

final pipelineRunProvider = NotifierProvider<PipelineRunNotifier, PipelineRunState?>(PipelineRunNotifier.new);
