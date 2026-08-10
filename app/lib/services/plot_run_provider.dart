import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import 'ws_client.dart';

/// Snapshot of an in-progress (or just-finished) Plots-tab analysis run.
/// Mirrors PipelineRunState/PipelineRunNotifier (pipeline_run_provider.dart)
/// for the same reason: held at the ProviderScope root so the run survives
/// navigating away from the Plots tab and back, instead of losing the
/// websocket/log the moment the screen's State is disposed.
class PlotRunState {
  final String runId;
  final String parentRunId;
  final String analysisId;
  final String outDir;
  final List<String> log;
  final bool finished;
  final int? exitCode;

  const PlotRunState({
    required this.runId,
    required this.parentRunId,
    required this.analysisId,
    required this.outDir,
    required this.log,
    required this.finished,
    required this.exitCode,
  });

  PlotRunState copyWith({List<String>? log, bool? finished, int? exitCode}) => PlotRunState(
        runId: runId,
        parentRunId: parentRunId,
        analysisId: analysisId,
        outDir: outDir,
        log: log ?? this.log,
        finished: finished ?? this.finished,
        exitCode: exitCode ?? this.exitCode,
      );

  bool get succeeded => finished && exitCode == 0;
}

class PlotRunNotifier extends Notifier<PlotRunState?> {
  WsClient? _ws;

  @override
  PlotRunState? build() => null;

  bool get isRunning => state != null && !state!.finished;

  Future<void> start({
    required String analysisId,
    required String parentRunId,
    required String dataRds,
    required List<Map<String, dynamic>> parameters,
    String? styleJson,
  }) async {
    _ws?.close();
    final api = ref.read(apiClientProvider);
    final res = await api.post('/api/plots/$analysisId/run', {
      'parent_run_id': parentRunId,
      'data_rds': dataRds,
      'parameters': parameters,
      if (styleJson != null) 'style_json': styleJson,
    }) as Map<String, dynamic>;

    final runId = res['run_id'] as String;
    final outDir = res['out_dir'] as String;
    state = PlotRunState(
      runId: runId,
      parentRunId: parentRunId,
      analysisId: analysisId,
      outDir: outDir,
      log: const [],
      finished: false,
      exitCode: null,
    );

    final ws = WsClient.connect(api.wsUrl('/ws/plots/$runId'));
    _ws = ws;
    ws.events.listen((event) {
      final current = state;
      if (current == null || current.runId != runId) return;
      switch (event['type']) {
        case 'log':
          state = current.copyWith(log: [...current.log, (event['text'] as String).trimRight()]);
          break;
        case 'done':
          state = current.copyWith(finished: true, exitCode: event['code'] as int?);
          break;
      }
    });
  }

  /// Clears the state once the user has seen a finished run (or wants to
  /// start a different analysis) -- does not touch the backend, the R
  /// process is already over by the time this is called.
  void dismiss() {
    _ws?.close();
    _ws = null;
    state = null;
  }
}

final plotRunProvider = NotifierProvider<PlotRunNotifier, PlotRunState?>(PlotRunNotifier.new);
