import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'handlers.dart';

class BridgeEvent {
  final String text;
  final bool isError;
  BridgeEvent(this.text, {this.isError = false});
}

/// Outbound-only operator bridge (protocol v1, see PROTOCOL.md).
/// Subscribes to a private ntfy topic, executes signed tasks, publishes chunked results.
/// Only processes `type == "task"` — the self-echo rule learned in live testing.
class BridgeEngine {
  final String baseUrl, topic, token, mode;
  final PlatformOps ops;
  final void Function(BridgeEvent) log;

  bool running = false;
  final Set<String> _seen = {};
  http.Client? _client;
  final Map<String, Map<int, String>> _putBuf = {};
  final Stopwatch _up = Stopwatch()..start();

  static const chunkSize = 3000; // ntfy free tier caps a message at 4096 bytes
  static const rateGap = Duration(milliseconds: 650);

  BridgeEngine({
    required this.baseUrl,
    required this.topic,
    required this.token,
    required this.mode,
    required this.ops,
    required this.log,
  });

  Future<void> start() async {
    running = true;
    log(BridgeEvent('bridge online — topic ${topic.substring(0, topic.length > 18 ? 18 : topic.length)}… mode=$mode'));
    final st = await ops.status(_up.elapsedMilliseconds ~/ 1000);
    await _publish({
      'type': 'result',
      'task_id': 'hello',
      'part': 1,
      'of': 1,
      'data': jsonEncode(st),
      'token': token,
    });
    unawaited(_loop());
  }

  Future<void> stop() async {
    running = false;
    try {
      _client?.close();
    } catch (_) {}
    log(BridgeEvent('bridge stopped'));
  }

  Future<void> _loop() async {
    while (running) {
      _client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse('$baseUrl/$topic/json?since=10m'));
        final resp = await _client!.send(req).timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) {
          log(BridgeEvent('relay HTTP ${resp.statusCode} — retry in 5s', isError: true));
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        final lines = resp.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in lines) {
          if (!running) break;
          if (line.isEmpty) continue;
          dynamic ev;
          try {
            ev = jsonDecode(line);
          } catch (_) {
            continue;
          }
          if (ev is! Map || ev['event'] != 'message') continue;
          final id = ev['id'] as String?;
          if (id == null || _seen.contains(id)) continue;
          _seen.add(id);
          dynamic decoded;
          try {
            decoded = jsonDecode(ev['message'] as String? ?? '{}');
          } catch (_) {
            continue;
          }
          if (decoded is! Map || decoded['type'] != 'task') continue;
          if (decoded['token'] != token) {
            log(BridgeEvent('⚠ dropped message with bad token', isError: true));
            continue;
          }
          unawaited(_handle(Map<String, dynamic>.from(decoded)));
        }
      } catch (e) {
        if (running) {
          log(BridgeEvent('stream dropped: $e — retry in 5s', isError: true));
          await Future.delayed(const Duration(seconds: 5));
        }
      } finally {
        try {
          _client?.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(Map<String, dynamic> task) async {
    final tid = (task['task_id'] ?? '?').toString();
    final kind = (task['kind'] ?? '').toString();
    log(BridgeEvent('▶ task $tid: $kind'));
    Map<String, dynamic> res;
    if (kind == 'kill') {
      await _sendResult(tid, {'ok': true, 'out': 'agent shutting down. bye.'});
      log(BridgeEvent('⏹ kill switch — operator requested shutdown', isError: true));
      await Future.delayed(const Duration(milliseconds: 300));
      exit(0);
    }
    try {
      res = await ops.dispatch(kind, task, _putBuf);
    } catch (e) {
      res = {'ok': false, 'out': 'agent error: ${e.runtimeType}: $e'};
    }
    await _sendResult(tid, res);
    log(BridgeEvent('✓ result $tid ok=${res['ok']} len=${(res['out'] ?? '').toString().length}'));
  }

  Future<bool> _publish(Map<String, dynamic> env) async {
    final title = ('${env['type']} ${env['task_id'] ?? ''}')
        .substring(0, ('${env['type']} ${env['task_id'] ?? ''}').length > 80
            ? 80
            : ('${env['type']} ${env['task_id'] ?? ''}').length);
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final r = await http
            .post(Uri.parse(baseUrl),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'topic': topic,
                  'message': jsonEncode(env),
                  'title': title,
                }))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 429) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
          continue;
        }
        if (r.statusCode >= 300) {
          log(BridgeEvent('publish HTTP ${r.statusCode}', isError: true));
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return true;
      } catch (e) {
        await Future.delayed(Duration(seconds: 1 + attempt));
      }
    }
    return false;
  }

  Future<void> _sendResult(String tid, Map<String, dynamic> result) async {
    final raw = jsonEncode(result);
    final n = (raw.length / chunkSize).ceil().clamp(1, 1 << 20);
    for (var i = 0; i < n; i++) {
      final end = ((i + 1) * chunkSize) < raw.length ? ((i + 1) * chunkSize) : raw.length;
      final ok = await _publish({
        'type': 'result',
        'task_id': tid,
        'part': i + 1,
        'of': n,
        'data': raw.substring(i * chunkSize, end),
        'token': token,
      });
      if (!ok) break;
      if (i < n - 1) await Future.delayed(rateGap);
    }
  }
}
