import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'handlers.dart';

class RelayEvent {
  final String text;
  final bool isError;
  RelayEvent(this.text, {this.isError = false});
}

/// Relay-first transport (v2): the phone talks ONLY to the operator relay
/// (https://orubus-harness.vercel.app). No ntfy on the device — the relay
/// does all ntfy I/O server-side, so carrier DNS quirks can never kill the
/// link again.
///
/// Wire:
///   poll  GET  /api/op/poll?after=<id>&wait=8000   (Authorization: Bearer)
///   send  POST /api/op/send {type:"chat"|"result", ...}
///   files POST /api/op/attach {name, mime, b64} → permanent URL
///
/// Tasks use the same envelope shapes as protocol v1.1 (see PROTOCOL.md):
/// type:"task" arrives from the operator, results go back chunked ≤3000 chars.
class RelayEngine {
  final String baseUrl, key, deviceId, mode;
  final PlatformOps ops;
  final void Function(RelayEvent) log;

  void Function(String from, String text, Map<String, dynamic>? attachment)? onChat;
  void Function()? onOperatorAlive;
  bool _operatorSeen = false;

  bool running = false;
  String _cursor = '';
  http.Client? _client;
  final Map<String, Map<int, String>> _putBuf = {};
  final Stopwatch _up = Stopwatch()..start();

  static const chunkSize = 3000; // keep every envelope under the ntfy 4KB line
  static const rateGap = Duration(milliseconds: 120);

  RelayEngine({
    required this.baseUrl,
    required this.key,
    required this.deviceId,
    required this.mode,
    required this.ops,
    required this.log,
  });

  Uri _u(String path, [Map<String, String>? q]) {
    var s = '$baseUrl$path';
    if (q != null && q.isNotEmpty) {
      final parts = <String>[];
      q.forEach((k, v) {
        parts.add('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}');
      });
      s = '$s?${parts.join('&')}';
    }
    return Uri.parse(s);
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      };

  Future<void> start() async {
    running = true;
    log(RelayEvent('relay online — $baseUrl · device ${deviceId.substring(0, deviceId.length > 12 ? 12 : deviceId.length)} · mode=$mode'));
    final st = await ops.status(_up.elapsedMilliseconds ~/ 1000);
    await _sendResult('hello', {'ok': true, 'out': jsonEncode(st)});
    unawaited(_loop());
  }

  Future<void> stop() async {
    running = false;
    try {
      _client?.close();
    } catch (_) {}
    log(RelayEvent('relay stopped'));
  }

  Future<void> _loop() async {
    _client ??= http.Client(); // BUGFIX 10.8: was never initialized — poll crashed (_TypeError) every iteration, app never fetched operator replies
    while (running) {
      try {
        final r = await _client!
            .get(_u('/api/op/poll', {'after': _cursor, 'wait': '8000'}),
                headers: _headers())
            .timeout(const Duration(seconds: 25));
        if (!running) break;
        if (r.statusCode == 401) {
          log(RelayEvent('relay rejected the key (401) — check Settings', isError: true));
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }
        if (r.statusCode != 200) {
          log(RelayEvent('relay HTTP ${r.statusCode} — retry in 5s', isError: true));
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        final d = jsonDecode(utf8.decode(r.bodyBytes));
        if (d is! Map) continue;
        final lastId = (d['lastId'] ?? '').toString();
        final events = d['events'];
        if (lastId.isNotEmpty) _cursor = lastId;
        if (events is! List) continue;
        for (final e in events) {
          if (!running) break;
          if (e is! Map) continue;
          await _onEnvelope(Map<String, dynamic>.from(e));
        }
      } catch (e) {
        if (running) {
          log(RelayEvent('poll dropped: ${e.runtimeType} — retry in 5s', isError: true));
          await Future.delayed(const Duration(seconds: 5));
        }
      }
    }
  }

  Future<void> _onEnvelope(Map<String, dynamic> e) async {
    final from = (e['from'] ?? '').toString();
    final kind = (e['type'] ?? '').toString();

    if (kind == 'chat') {
      if (from == 'device') return; // our own echo
      final text = (e['text'] ?? '').toString();
      final att = e['attachment'] is Map
          ? Map<String, dynamic>.from(e['attachment'] as Map)
          : null;
      if (text.isNotEmpty || att != null) {
        if (!_operatorSeen) {
          _operatorSeen = true;
          onOperatorAlive?.call();
        }
        onChat?.call(from, text, att);
      }
      return;
    }

    if (kind != 'task') return;
    if (!_operatorSeen) {
      _operatorSeen = true;
      onOperatorAlive?.call();
    }
    unawaited(_handle(Map<String, dynamic>.from(e)));
  }

  /// Send a chat message to the operator.
  Future<bool> sendChat(String text, {String? model}) async {
    try {
      final r = await http
          .post(_u('/api/op/send'),
              headers: _headers(),
              body: jsonEncode({
                'type': 'chat',
                'from': 'device',
                'text': text,
                if (model != null && model.isNotEmpty) 'model': model,
              }))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 200;
    } catch (e) {
      log(RelayEvent('send failed: ${e.runtimeType}', isError: true));
      return false;
    }
  }

  /// Upload a file to the relay's asset store. Returns the permanent URL,
  /// or null on failure. The pointer travels as a normal chat envelope.
  Future<String?> sendAttachment(String name, String mime, List<int> bytes) async {
    try {
      final r = await http
          .post(_u('/api/op/attach'),
              headers: _headers(),
              body: jsonEncode({
                'name': name,
                'mime': mime,
                'b64': base64Encode(bytes),
              }))
          .timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) {
        String msg = 'upload HTTP ${r.statusCode}';
        try {
          msg = (jsonDecode(r.body) as Map)['error']?.toString() ?? msg;
        } catch (_) {}
        log(RelayEvent(msg, isError: true));
        return null;
      }
      final d = jsonDecode(r.body) as Map;
      final url = (d['url'] ?? '').toString();
      return url.isEmpty ? null : url;
    } catch (e) {
      log(RelayEvent('upload failed: ${e.runtimeType}', isError: true));
      return null;
    }
  }

  Future<void> _handle(Map<String, dynamic> task) async {
    final tid = (task['task_id'] ?? '?').toString();
    final kind = (task['kind'] ?? '').toString();
    log(RelayEvent('▶ task $tid: $kind'));
    Map<String, dynamic> res;
    if (kind == 'kill') {
      await _sendResult(tid, {'ok': true, 'out': 'agent shutting down. bye.'});
      log(RelayEvent('⏹ kill switch — operator requested shutdown', isError: true));
      await Future.delayed(const Duration(milliseconds: 300));
      exit(0);
    }
    try {
      res = await ops.dispatch(kind, task, _putBuf);
    } catch (e) {
      res = {'ok': false, 'out': 'agent error: ${e.runtimeType}: $e'};
    }
    await _sendResult(tid, res);
    log(RelayEvent('✓ result $tid ok=${res['ok']} len=${(res['out'] ?? '').toString().length}'));
  }

  Future<void> _sendResult(String tid, Map<String, dynamic> result) async {
    final raw = jsonEncode(result);
    final n = (raw.length / chunkSize).ceil().clamp(1, 1 << 20);
    for (var i = 0; i < n; i++) {
      final end = ((i + 1) * chunkSize) < raw.length ? ((i + 1) * chunkSize) : raw.length;
      try {
        final r = await http
            .post(_u('/api/op/send'),
                headers: _headers(),
                body: jsonEncode({
                  'type': 'result',
                  'task_id': tid,
                  'part': i + 1,
                  'of': n,
                  'data': raw.substring(i * chunkSize, end),
                }))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          log(RelayEvent('result part ${i + 1} HTTP ${r.statusCode}', isError: true));
          return;
        }
      } catch (e) {
        log(RelayEvent('result part ${i + 1} failed: ${e.runtimeType}', isError: true));
        return;
      }
      if (i < n - 1) await Future.delayed(rateGap);
    }
  }
}
