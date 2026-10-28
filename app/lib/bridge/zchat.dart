import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Z.ai free-chat transport — talks to chat.z.ai directly with the session
/// token the ZAuth WebView captured. No relay, no pairing, no API key:
/// the user's own logged-in session IS the credential (Open WebUI-style
/// API, Bearer in localStorage). If the wire shape drifts, the ZAuth
/// WebView remains a guaranteed-working fallback (it IS chat.z.ai).
class ZChat {
  ZChat._();
  static final ZChat i = ZChat._();

  static const base = 'https://chat.z.ai';
  static const ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  List<String> _models = const [];
  bool _fetched = false;

  /// Last cached model list (empty until the first successful verify).
  List<String> get models => _models;

  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'User-Agent': ua,
        'Accept': 'application/json',
      };

  /// Validate the session and refresh the model list.
  /// Throws [ZSessionExpired] on 401/403, [Exception] otherwise.
  Future<List<String>> verify(String token, {bool force = false}) async {
    if (_fetched && !force) return _models;
    if (token.isEmpty) return _models;
    final r = await http
        .get(Uri.parse('$base/api/v1/models'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw ZSessionExpired('session rejected (HTTP ${r.statusCode})');
    }
    if (r.statusCode != 200) {
      throw Exception('models check failed (HTTP ${r.statusCode})');
    }
    try {
      final j = jsonDecode(r.body);
      final data = (j is Map ? j['data'] : null) as List?;
      final ids = <String>[];
      for (final e in data ?? const []) {
        if (e is Map) {
          final id = (e['id'] ?? '').toString();
          if (id.isNotEmpty) ids.add(id);
        }
      }
      if (ids.isNotEmpty) {
        _models = ids;
        _fetched = true;
      }
      return _models;
    } catch (e) {
      throw Exception('unexpected models payload (${e.runtimeType})');
    }
  }

  /// Send one user turn, streaming reply deltas through [onDelta].
  /// Stateless per call — history is the device's own chat log.
  Future<void> chat({
    required String token,
    required String text,
    required String model,
    required void Function(String delta) onDelta,
  }) async {
    if (token.isEmpty) {
      throw ZSessionExpired('no z.ai session — sign in first');
    }
    final req = http.Request('POST', Uri.parse('$base/api/chat/completions'));
    req.headers.addAll({
      'Authorization': 'Bearer $token',
      'User-Agent': ua,
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    req.body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': text},
      ],
      'stream': true,
    });

    final client = http.Client();
    var got = 0;
    try {
      final res =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw ZSessionExpired('session rejected (HTTP ${res.statusCode})');
      }
      if (res.statusCode != 200) {
        var snippet = '';
        try {
          snippet = (await res.stream.bytesToString())
              .replaceAll(RegExp(r'\s+'), ' ');
          if (snippet.length > 160) snippet = snippet.substring(0, 160);
        } catch (_) {}
        throw Exception('chat failed (HTTP ${res.statusCode}) $snippet');
      }
      final lines = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        final l = line.trim();
        if (l.isEmpty || !l.startsWith('data:')) continue;
        final payload = l.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final j = jsonDecode(payload);
          if (j is! Map) continue;
          // OpenAI-style chunk: choices[0].delta.content
          final choices = j['choices'];
          if (choices is List && choices.isNotEmpty) {
            final first = choices.first;
            final delta = first is Map
                ? (first['delta'] ?? first['message'] ?? const {})
                : const {};
            if (delta is Map) {
              final piece = delta['content'];
              if (piece is String && piece.isNotEmpty) {
                got += piece.length;
                onDelta(piece);
              }
            }
          }
        } catch (_) {
          // unknown SSE shape — skip the frame, keep the stream alive
        }
      }
      if (got == 0) {
        throw Exception('empty response — the wire shape may have drifted '
            '(use the Z.ai login screen to chat in the WebView)');
      }
    } on TimeoutException {
      throw Exception('chat timed out reaching chat.z.ai');
    } finally {
      client.close();
    }
  }
}

/// 401/403 — the captured session is gone/expired: re-auth via ZAuth.
class ZSessionExpired implements Exception {
  final String message;
  ZSessionExpired(this.message);
  @override
  String toString() => message;
}
