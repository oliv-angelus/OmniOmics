import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thin REST wrapper around the FastAPI backend. One instance is created
/// after main.dart confirms the backend sidecar process is up and healthy.
class ApiClient {
  final String baseUrl;
  final http.Client _client = http.Client();

  ApiClient({required this.baseUrl});

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<dynamic> get(String path) async {
    final res = await _client.get(_uri(path));
    _checkStatus(res);
    return jsonDecode(res.body);
  }

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    final res = await _client.post(
      _uri(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body ?? {}),
    );
    _checkStatus(res);
    return res.body.isEmpty ? null: jsonDecode(res.body);
  }

  void _checkStatus(http.Response res) {
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
  }

  String wsUrl(String path) {
    final uri = Uri.parse('$baseUrl$path');
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss': 'ws').toString();
  }

  void dispose() => _client.close();
}

class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}
