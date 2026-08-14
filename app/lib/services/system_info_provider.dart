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
/// State is the latest reading, or null before the first one arrives.
class SystemInfoNotifier extends Notifier<Map<String, dynamic>?> {
  WsClient? _ws;

  @override
  Map<String, dynamic>? build() {
    _connect();
    // Never actually fires -- the provider is read from AppShell, which lives
    // as long as the app does -- but leaving the socket unclosed on teardown
    // would leak it in tests and on hot restart.
    ref.onDispose(() => _ws?.close());
    return null;
  }

  void _connect() {
    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/system'));
    _ws = ws;
    ws.events.listen(
      (event) => state = event,
      // The backend sends a fresh reading every two seconds, so a dropped
      // socket means no further updates ever. Keep the last reading on screen
      // rather than blanking the strip -- it is stale by seconds, not wrong --
      // and let the next reading correct it if the connection comes back.
      onError: (_) {},
      onDone: () {},
    );
  }
}

final systemInfoProvider =
    NotifierProvider<SystemInfoNotifier, Map<String, dynamic>?>(SystemInfoNotifier.new);
