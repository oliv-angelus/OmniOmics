import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import 'ws_client.dart';

/// A reading plus when it arrived, so the strip can tell "live" from "the last
/// thing we ever heard".
class SystemInfo {
  final Map<String, dynamic> data;
  final DateTime receivedAt;
  const SystemInfo(this.data, this.receivedAt);

  /// The backend ticks every 2 s. Three missed ticks is a dropped connection,
  /// not jitter.
  bool get isFresh => DateTime.now().difference(receivedAt) < const Duration(seconds: 7);
}

/// One live subscription to /ws/system for the whole application.
///
/// The Resources *screen* used to own this: it opened the socket in initState
/// and closed it in dispose, which is right for a screen. The resource strip in
/// AppShell is not a screen -- it is present on every tab and behind every
/// embedded view -- so owning the socket per-widget would tear it down and
/// reconnect it on each rebuild, and the strip would blink back to "no reading
/// yet" every time the user changed tabs.
///
/// State is the latest reading plus its arrival time, or null before the first
/// one arrives.
class SystemInfoNotifier extends Notifier<SystemInfo?> {
  WsClient? _ws;
  Timer? _retry;
  Timer? _staleTick;
  bool _disposed = false;

  @override
  SystemInfo? build() {
    ref.onDispose(() {
      _disposed = true;
      _retry?.cancel();
      _staleTick?.cancel();
      _ws?.close();
    });
    // Nothing recomputes `isFresh` on its own, so without this the strip would
    // keep rendering a green dot until some unrelated rebuild happened to touch
    // it. Cheap: one no-op rebuild every two seconds, same cadence as the feed.
    _staleTick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_disposed && state != null && !state!.isFresh) {
        state = SystemInfo(state!.data, state!.receivedAt);
      }
    });
    _connect();
    return null;
  }

  void _connect() {
    if (_disposed) return;
    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/system'));
    _ws = ws;
    ws.events.listen(
      (event) => state = SystemInfo(event, DateTime.now()),
      // A dropped socket means no further readings ever, and this strip is on
      // every screen -- left alone it would show a green dot and frozen numbers
      // forever after a backend restart, and the Databases budget would go on
      // validating selections against stale free space. The retired Resources
      // screen at least reconnected when you re-entered the tab; nothing here
      // ever would.
      //
      // The last reading stays on screen (stale by seconds beats blank), but
      // `isFresh` goes false so the strip can say so.
      onError: (_) => _scheduleRetry(),
      onDone: _scheduleRetry,
    );
  }

  void _scheduleRetry() {
    if (_disposed || _retry?.isActive == true) return;
    _ws?.close();
    _ws = null;
    _retry = Timer(const Duration(seconds: 3), _connect);
  }
}

final systemInfoProvider =
    NotifierProvider<SystemInfoNotifier, SystemInfo?>(SystemInfoNotifier.new);

/// The latest payload regardless of freshness, for callers that only want the
/// numbers. Prefer [systemInfoProvider] where staleness matters.
final systemInfoDataProvider =
    Provider<Map<String, dynamic>?>((ref) => ref.watch(systemInfoProvider)?.data);
