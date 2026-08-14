import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import 'ws_client.dart';

/// One live subscription to /ws/system for the whole application.
///
/// The Resources *screen* used to own this: it opened the socket in initState
/// and closed it in dispose, which is right for a screen. The resource strip in
/// AppShell is not a screen -- it is present on every tab and behind every
/// embedded view -- so owning the socket per-widget would tear it down and
/// reconnect it on each rebuild, and the strip would blink back to "no reading
/// yet" every time the user changed tabs.
///
/// Deliberately not autoDispose: there is no moment inside the shell where
/// nobody is watching, and reconnecting costs a round trip plus up to the two
/// seconds until the backend's next tick.
class SystemInfoNotifier extends StateNotifier<Map<String, dynamic>?> {
  final Ref _ref;
  WsClient? _ws;

  SystemInfoNotifier(this._ref) : super(null) {
    _connect();
  }

  void _connect() {
    final api = _ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/system'));
    _ws = ws;
    ws.events.listen(
      (event) {
        if (mounted) state = event;
      },
      // The backend sends a fresh reading every two seconds, so a dropped
      // socket means no further updates ever. Keep the last reading on screen
      // rather than blanking the strip -- it is stale by seconds, not wrong --
      // and let the next reading correct it if the connection comes back.
      onError: (_) {},
      onDone: () {},
    );
  }

  @override
  void dispose() {
    _ws?.close();
    super.dispose();
  }
}

/// Latest system reading, or null before the first one arrives.
final systemInfoProvider =
    StateNotifierProvider<SystemInfoNotifier, Map<String, dynamic>?>(
  (ref) => SystemInfoNotifier(ref),
);
