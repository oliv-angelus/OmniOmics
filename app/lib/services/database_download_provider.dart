import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import 'ws_client.dart';

enum DownloadPhase { running, done, error }

/// Snapshot of one database's download, keyed by "`<pipelineId>:<dbKey>`". Held
/// by [DatabaseDownloadsNotifier] instead of by DatabaseCard's State, so the
/// download survives leaving the Databases screen -- only Cancelar (or the
/// backend task actually finishing) should stop it.
class DatabaseDownloadState {
  final String pipelineId;
  final String dbKey;
  final String dbName;
  final String destDir;
  final DownloadPhase phase;
  final double percent;
  final String progressText;
  final List<String> log;
  final String? errorText;

  const DatabaseDownloadState({
    required this.pipelineId,
    required this.dbKey,
    required this.dbName,
    required this.destDir,
    required this.phase,
    this.percent = 0,
    this.progressText = '',
    this.log = const [],
    this.errorText,
  });

  DatabaseDownloadState copyWith({
    DownloadPhase? phase,
    double? percent,
    String? progressText,
    List<String>? log,
    String? errorText,
  }) {
    return DatabaseDownloadState(
      pipelineId: pipelineId,
      dbKey: dbKey,
      dbName: dbName,
      destDir: destDir,
      phase: phase ?? this.phase,
      percent: percent ?? this.percent,
      progressText: progressText ?? this.progressText,
      log: log ?? this.log,
      errorText: errorText ?? this.errorText,
    );
  }
}

String databaseDownloadKey(String pipelineId, String dbKey) => '$pipelineId:$dbKey';

/// Owns every in-flight (or just-finished) database download's WebSocket.
/// Lives at the ProviderScope root (not tied to DatabaseCard's widget
/// lifecycle), so navigating away from and back to the Databases screen just
/// re-reads the same accumulated state instead of losing it or cancelling
/// the download.
///
/// The backend mirrors this: /ws/pipelines/{pid}/databases/download detaches
/// the download's lifetime from any one socket, so even if this notifier's
/// socket drops and reconnects, nothing is lost.
class DatabaseDownloadsNotifier extends Notifier<Map<String, DatabaseDownloadState>> {
  final Map<String, WsClient> _sockets = {};

  @override
  Map<String, DatabaseDownloadState> build() => {};

  void start({
    required String pipelineId,
    required String dbKey,
    required String dbName,
    required String optionId,
    required String destDir,
  }) {
    final key = databaseDownloadKey(pipelineId, dbKey);
    _sockets[key]?.close();

    state = {...state,
      key: DatabaseDownloadState(
          pipelineId: pipelineId, dbKey: dbKey, dbName: dbName, destDir: destDir, phase: DownloadPhase.running),
    };

    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/pipelines/$pipelineId/databases/download'));
    _sockets[key] = ws;
    ws.send({'db_key': dbKey, 'option_id': optionId, 'dest_dir': destDir});
    ws.events.listen((event) {
      final current = state[key];
      if (current == null) return;
      switch (event['type']) {
        case 'log':
          state = {...state,
            key: current.copyWith(log: [...current.log, (event['text'] as String).trimRight()]),
          };
          break;
        case 'progress':
          state = {...state,
            key: current.copyWith(
              percent: (event['percent'] as num?)?.toDouble() ?? current.percent,
              progressText: '${event['done']} / ${event['total']} ${event['unit']}',
            ),
          };
          break;
        case 'done':
          state = {...state, key: current.copyWith(phase: DownloadPhase.done)};
          _sockets.remove(key);
          break;
        case 'error':
          state = {...state,
            key: current.copyWith(phase: DownloadPhase.error, errorText: event['text'] as String?),
          };
          _sockets.remove(key);
          break;
        case 'cancelled':
          // Normally cancel already dropped this key from state locally --
          // this only fires if a "cancelled" for *this* connection arrives
          // some other way (e.g. the backend itself replaced it on a fresh
          // start elsewhere). Either way, nothing left to show for it here.
          final next = {...state}..remove(key);
          state = next;
          _sockets.remove(key);
          break;
      }
    });
  }

  void cancel(String pipelineId, String dbKey) {
    final key = databaseDownloadKey(pipelineId, dbKey);
    _sockets[key]?.close();
    _sockets.remove(key);
    final next = {...state}..remove(key);
    state = next;
    // Closing our own socket only drops us as a *viewer* -- the backend task
    // is intentionally independent of any one connection (that's what makes
    // it survive navigating away), so it keeps running unless explicitly
    // told to stop. Without this call, a "cancelled" download kept
    // downloading in the background and could later get silently latched
    // onto by the next Baixar click for the same database, ignoring
    // whatever option/folder that click actually asked for.
    final api = ref.read(apiClientProvider);
    api.post('/api/pipelines/$pipelineId/databases/$dbKey/download/cancel').catchError((_) => null);
  }

  /// Drops a finished/errored download from the map once the user has seen
  /// it -- doesn't touch the backend, the download is already over either way.
  void dismiss(String pipelineId, String dbKey) {
    final key = databaseDownloadKey(pipelineId, dbKey);
    final next = {...state}..remove(key);
    state = next;
  }

  /// Clears every download that isn't still running -- used by the top-bar
  /// indicator so acknowledging it (by tapping through to Databases) clears
  /// finished/errored entries but leaves active downloads' badges in place.
  void dismissFinished() {
    final next = {
      for (final entry in state.entries)
        if (entry.value.phase == DownloadPhase.running) entry.key: entry.value,
    };
    state = next;
  }
}

final databaseDownloadsProvider =
    NotifierProvider<DatabaseDownloadsNotifier, Map<String, DatabaseDownloadState>>(DatabaseDownloadsNotifier.new);
