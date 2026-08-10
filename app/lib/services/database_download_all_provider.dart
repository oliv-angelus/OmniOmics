import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import 'ws_client.dart';

/// The database batch is Hub-level (spans every pipeline; see the backend's
/// _download_all_task), so it uses one fixed key rather than a real pipeline id
/// -- shared by the Databases screen, its progress dialog, and the top-bar
/// indicator so they all refer to the same batch.
const String kHubDownloadBatchId = 'omniomics';

/// Per-database state within a "download all missing" batch, keyed by db key.
enum DbBatchState { pending, running, done, error, skipped }

enum DownloadAllPhase { running, done, error }

/// One database the batch is downloading -- kept in the batch state so the
/// progress dialog can render its chips (and their order) even after being
/// closed and reopened, without the caller having to re-supply the list.
class DbTarget {
  final String key;
  final String name;
  const DbTarget(this.key, this.name);
}

/// Snapshot of one pipeline's "download all missing databases" batch. Held by
/// [DownloadAllNotifier] at the ProviderScope root instead of by the progress
/// dialog's State, so closing/reopening the dialog (or a transient socket
/// drop) reattaches to the same running batch rather than restarting or losing
/// it -- mirroring [DatabaseDownloadsNotifier] for single downloads.
///
/// The backend matches this: /ws/pipelines/{pid}/databases/download-all owns
/// the batch in a background task detached from any one socket, replaying the
/// log + per-db progress to whoever (re)connects.
class DownloadAllState {
  final String pipelineId;
  final List<DbTarget> targets;
  final Map<String, DbBatchState> dbStatus;
  final List<String> log;
  final DownloadAllPhase phase;

  const DownloadAllState({
    required this.pipelineId,
    this.targets = const [],
    this.dbStatus = const {},
    this.log = const [],
    this.phase = DownloadAllPhase.running,
  });

  DownloadAllState copyWith({
    List<DbTarget>? targets,
    Map<String, DbBatchState>? dbStatus,
    List<String>? log,
    DownloadAllPhase? phase,
  }) {
    return DownloadAllState(
      pipelineId: pipelineId,
      targets: targets ?? this.targets,
      dbStatus: dbStatus ?? this.dbStatus,
      log: log ?? this.log,
      phase: phase ?? this.phase,
    );
  }
}

class DownloadAllNotifier extends Notifier<Map<String, DownloadAllState>> {
  final Map<String, WsClient> _sockets = {};

  @override
  Map<String, DownloadAllState> build() => {};

  bool isRunning(String pipelineId) => state[pipelineId]?.phase == DownloadAllPhase.running;

  /// Starts a fresh batch for the chosen [targets] (a start message carrying
  /// base_dir cancels any batch already running for this pipeline on the
  /// backend, so this is safe to call even if a stale one lingers).
  void start({
    required String pipelineId,
    required String baseDir,
    required Map<String, String> options,
    required List<DbTarget> targets,
  }) {
    _sockets[pipelineId]?.close();
    state = {...state, pipelineId: DownloadAllState(pipelineId: pipelineId, targets: targets)};

    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/pipelines/$pipelineId/databases/download-all'));
    _sockets[pipelineId] = ws;
    ws.send({'base_dir': baseDir, 'options': options, 'selected': targets.map((t) => t.key).toList()});
    _listen(pipelineId, ws);
  }

  /// Reattaches to a batch already running for this pipeline (e.g. the dialog
  /// was closed and reopened, or the socket dropped) without restarting it: a
  /// message with no base_dir tells the backend to replay + stream, not start.
  void reconnect(String pipelineId) {
    if (_sockets.containsKey(pipelineId)) return; // already attached
    final current = state[pipelineId];
    if (current == null || current.phase != DownloadAllPhase.running) return;

    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/pipelines/$pipelineId/databases/download-all'));
    _sockets[pipelineId] = ws;
    ws.send({'reconnect': true});
    _listen(pipelineId, ws);
  }

  void _listen(String pid, WsClient ws) {
    ws.events.listen((event) {
      final current = state[pid];
      if (current == null) return;
      switch (event['type']) {
        case 'log':
          state = {...state, pid: current.copyWith(log: [...current.log, (event['text'] as String).trimRight()])};
          break;
        case 'db_start':
          state = {...state, pid: current.copyWith(dbStatus: {...current.dbStatus, event['key'] as String: DbBatchState.running})};
          break;
        case 'db_done':
          state = {...state, pid: current.copyWith(dbStatus: {...current.dbStatus, event['key'] as String: DbBatchState.done})};
          break;
        case 'db_error':
          final prefix = translate('error_prefix', ref.read(localeProvider).languageCode);
          state = {...state,
            pid: current.copyWith(
              dbStatus: {...current.dbStatus, event['key'] as String: DbBatchState.error},
              log: [...current.log, '$prefix (${event['name']}): ${event['text']}'],
            ),
          };
          break;
        case 'db_skipped':
          state = {...state, pid: current.copyWith(dbStatus: {...current.dbStatus, event['key'] as String: DbBatchState.skipped})};
          break;
        case 'done':
          state = {...state, pid: current.copyWith(phase: DownloadAllPhase.done)};
          _sockets.remove(pid);
          break;
        case 'error':
          final prefix = translate('error_prefix', ref.read(localeProvider).languageCode);
          state = {...state,
            pid: current.copyWith(phase: DownloadAllPhase.error, log: [...current.log, '$prefix: ${event['text']}']),
          };
          _sockets.remove(pid);
          break;
        case 'cancelled':
          final next = {...state}..remove(pid);
          state = next;
          _sockets.remove(pid);
          break;
      }
    });
  }

  /// Actually stops the batch on the backend (closing our socket alone only
  /// drops us as a viewer -- the detached task keeps running otherwise).
  void cancel(String pipelineId) {
    _sockets[pipelineId]?.close();
    _sockets.remove(pipelineId);
    final next = {...state}..remove(pipelineId);
    state = next;
    final api = ref.read(apiClientProvider);
    api.post('/api/pipelines/$pipelineId/databases/download-all/cancel').catchError((_) => null);
  }

  /// Drops a finished/errored batch from the map once the user has seen it --
  /// does not touch the backend (the batch is already over either way).
  void dismiss(String pipelineId) {
    _sockets[pipelineId]?.close();
    _sockets.remove(pipelineId);
    final next = {...state}..remove(pipelineId);
    state = next;
  }
}

final downloadAllProvider =
    NotifierProvider<DownloadAllNotifier, Map<String, DownloadAllState>>(DownloadAllNotifier.new);
