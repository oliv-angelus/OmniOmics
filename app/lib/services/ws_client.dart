import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Wraps a backend WebSocket endpoint as a stream of decoded JSON events.
/// Every /ws/* route in the backend sends newline-delimited JSON messages
/// ({"type": "log"|"progress"|"job_start"|"job_done"|"done"|"error",...}).
class WsClient {
  final WebSocketChannel _channel;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  WsClient._(this._channel) {
    _channel.stream.listen(
      (raw) {
        try {
          final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
          _controller.add(decoded);
        } catch (_) {
          // Non-JSON frame: ignore rather than crash the stream.
        }
      },
      onError: (e) => _controller.addError(e),
      onDone: () => _controller.close(),
    );
  }

  factory WsClient.connect(String url) => WsClient._(WebSocketChannel.connect(Uri.parse(url)));

  Stream<Map<String, dynamic>> get events => _controller.stream;

  void send(Map<String, dynamic> message) => _channel.sink.add(jsonEncode(message));

  Future<void> close() async {
    await _controller.close();
    await _channel.sink.close();
  }
}
