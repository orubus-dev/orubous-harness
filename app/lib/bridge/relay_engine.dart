import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'engine.dart';
import 'handlers.dart';

/// Relay-first transport (v1.2026.10.7): the app talks ONLY to the Vercel
/// relay API — no ntfy on the device, no DNS drama on any carrier.
///
/// Pairing: the app registers a 6-digit code (/api/pair/start), the operator
/// claims it, and the returned deviceToken unlocks /api/op/send + /api/op/poll.
/// The wire: everything lands in the relay ring; both sides poll it.
class RelayEngine {
  final String base; // https://orubus-harness.vercel.app
  final String deviceToken; // 'odt_…' — issued at pair/start, activated on claim
  final String mode;
  final PlatformOps ops;
  final void Function(BridgeEvent) log;

  void Function(String from, String text, Map<String, dynamic>? att)? onChat;
  void Function()? onOperatorAlive;
  bool _operatorSeen = false;

  bool running = false;
  String _cursor = '';
  final Set<String> _seen = {};
  final Map<String, Map<int, String>> _putBuf = {};
  final Stopwatch _up = Stopwatch()..start();

  static const chunkSize = 3000; // result chunk cap (relay enforces ≤3200)
  static const rateGap = Duration(milliseconds: 250);

  RelayEngine({
    required this.base,
    required this.deviceToken,
    required this.mode,
    required this.ops,
    required this.log,
  });

  Map<String, String> get _hdr => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $deviceToken',
      };

  Future<void> start() async {
    running = true;
    log(BridgeEvent('relay link online — direct API wire, no ntfy needed'));
    final st = await ops.status(_up.elapsedMilliseconds ~/ 1000);
    await sendResult('hello', {'ok': true, 'out': jsonEncode(st)});
    unawaited(_loop());
  }

  Future<void> stop() async {
    running = false;
    log(BridgeEvent('relay link stopped'));
  }

  Future<void> _loop() async {
    var backoff = const Duration(seconds: 2);
    while (running) {
      try {
        final uri = Uri.parse(
            '$base/api/op/poll?after=${Uri.encodeComponent(_cursor)}&wait=8000');
        final r =
            await http.get(uri, headers: _hdr).timeout(const Duration(seconds: 25));
        if (!running) break;
        if (r.statusCode != 200) {
          log(BridgeEvent('relay HTTP ${r.statusCode} — retry', isError: true));
          await Future.delayed(backoff);
          continue;
        }
        backoff = const Duration(seconds: 2);
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        _cursor = (d['lastId'] ?? _cursor).toString();
        final events = (d['events'] as List? ?? []);
        for (final ev in events) {
          if (ev is! Map) continue;
          final id = (ev['id'] ?? '').toString();
          if (id.isEmpty || _seen.contains(id)) continue;
          _seen.add(id);
          if (_seen.length > 600) _seen.remove(_seen.first);
          final kind = (ev['type'] ?? '').toString();
          if (kind == 'chat') {
            final from = (ev['from'] ?? 'orubus').toString();
            final text = (ev['text'] ?? '').toString();
            if (text.isEmpty) continue;
            if (from == 'device') continue; // our own echo
            if (!_operatorSeen) {
              _operatorSeen = true;
              onOperatorAlive?.call();
            }
            if (from == 'system') {
              log(BridgeEvent(text));
            } else {
              onChat?.call(
                  from, text, ev['attachment'] as Map<String, dynamic>?);
            }
            continue;
          }
          if (kind != 'task') continue;
          if (!_operatorSeen) {
            _operatorSeen = true;
            onOperatorAlive?.call();
          }
          unawaited(_handle(Map<String, dynamic>.from(ev)));
        }
      } catch (e) {
        if (running) {
          log(BridgeEvent('relay poll dropped: $e — retry', isError: true));
          await Future.delayed(backoff);
          if (backoff < const Duration(seconds: 15)) {
            backoff = Duration(seconds: backoff.inSeconds + 3);
          }
        }
      }
    }
  }

  /// Send a chat message (and optional attachment) to the operator.
  Future<bool> sendChat(String text,
      {Map<String, dynamic>? attachment, String? model}) =>
      _post({
        'type': 'chat',
        'from': 'device',
        'text': text,
        if (model != null && model.isNotEmpty) 'model': model,
        if (attachment != null) 'attachment': attachment,
      });

  Future<void> _handle(Map<String, dynamic> task) async {
    final tid = (task['task_id'] ?? '?').toString();
    final kind = (task['kind'] ?? '').toString();
    log(BridgeEvent('▶ task $tid: $kind'));
    Map<String, dynamic> res;
    if (kind == 'kill') {
      await sendResult(tid, {'ok': true, 'out': 'agent shutting down. bye.'});
      log(BridgeEvent('⏹ kill switch — operator requested shutdown', isError: true));
      await Future.delayed(const Duration(milliseconds: 300));
      // relay mode has no isolate to kill — just stop the engine
      await stop();
      return;
    }
    try {
      res = await ops.dispatch(kind, task, _putBuf);
    } catch (e) {
      res = {'ok': false, 'out': 'agent error: ${e.runtimeType}: $e'};
    }
    await sendResult(tid, res);
    log(BridgeEvent(
        '✓ result $tid ok=${res['ok']} len=${(res['out'] ?? '').toString().length}'));
  }

  /// Chunked result upload (relay caps each chunk at 3200 chars).
  Future<void> sendResult(String tid, Map<String, dynamic> result) async {
    final raw = jsonEncode(result);
    final n = (raw.length / chunkSize).ceil().clamp(1, 1 << 20);
    for (var i = 0; i < n; i++) {
      final end = ((i + 1) * chunkSize) < raw.length
          ? ((i + 1) * chunkSize)
          : raw.length;
      final ok = await _post({
        'type': 'result',
        'task_id': tid,
        'part': i + 1,
        'of': n,
        'data': raw.substring(i * chunkSize, end),
      });
      if (!ok) break;
      if (i < n - 1) await Future.delayed(rateGap);
    }
  }

  Future<bool> _post(Map<String, dynamic> env) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final r = await http
            .post(Uri.parse('$base/api/op/send'),
                headers: _hdr, body: jsonEncode(env))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode == 429) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
          continue;
        }
        if (r.statusCode >= 300) {
          log(BridgeEvent('relay send HTTP ${r.statusCode}', isError: true));
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
}

/// Pairing helpers (used by the Pairing screen — no engine instance needed).
class RelayPair {
  static const base = 'https://orubus-harness.vercel.app';

  /// Register a 6-digit code. Returns the device token on success.
  static Future<Map<String, dynamic>> start(String code, String device) async {
    try {
      final r = await http
          .post(Uri.parse('$base/api/pair/start'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'code': code, 'device': device}))
          .timeout(const Duration(seconds: 15));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// Poll whether the operator claimed the code.
  static Future<Map<String, dynamic>> status(String code) async {
    try {
      final r = await http
          .get(Uri.parse('$base/api/pair/status?code=$code'))
          .timeout(const Duration(seconds: 15));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'claimed': false, 'error': '$e'};
    }
  }
}
