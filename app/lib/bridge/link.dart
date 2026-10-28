import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'relay.dart';
import 'handlers.dart';
import '../store.dart';

/// Android foreground keep-alive: holds the process up so the bridge isolate
/// keeps its relay poll loop while the app is backgrounded. No-op elsewhere.
Future<void> _keepAlive(bool on) async {
  if (!Platform.isAndroid) return;
  try {
    await const MethodChannel('harness/device')
        .invokeMethod('bridgeKeepAlive', {'on': on});
  } catch (_) {
    // never block the bridge on the keep-alive (older builds, plugin races)
  }
}

/// App-wide singleton: ONE bridge engine, shared by every screen.
/// The user chats on the Chat page; the same channel carries operator tasks.
/// v2: relay-first — every byte goes to the operator relay over HTTPS.
class Link {
  Link._();
  static final Link i = Link._();

  static const kChatMirror = 'chatMirrorJson';

  RelayEngine? engine;
  PlatformOps? ops;
  String workspace = '';
  bool paired = false; // operator answered at least once on this identity

  /// Hook set by the shell: persists the online flag for auto-resume.
  void Function(bool online)? onOnlineChanged;

  /// Engine events that happened before any screen was listening
  /// (auto-resume at cold start). Seeded into the Bridge activity log.
  final List<RelayEvent> autoEvents = [];

  final List<ChatMsg> chats = <ChatMsg>[];
  final _chatStream = StreamController<ChatMsg>.broadcast();
  Stream<ChatMsg> get chatStream => _chatStream.stream;
  final _stateStream = StreamController<void>.broadcast();
  Stream<void> get stateStream => _stateStream.stream;

  /// Pairing poll bookkeeping (6-digit code → operator claims it).
  Timer? _pairPoll;
  bool pairingNow = false;

  bool get online => engine?.running ?? false;

  void autoLog(String text, {bool error = false}) {
    autoEvents.add(RelayEvent(text, isError: error));
    if (autoEvents.length > 200) {
      autoEvents.removeRange(0, autoEvents.length - 200);
    }
    _stateStream.add(null);
  }

  /// Load chat history from BOTH stores (jsonl file + SharedPreferences
  /// mirror) and merge. OEM cache cleaners and storage quirks can eat the
  /// workspace file — the mirror is the second line of defense.
  Future<void> loadHistory() async {
    final fileMsgs =
        workspace.isEmpty ? <ChatMsg>[] : await ChatLog.load(workspace);
    final mirrorMsgs = <ChatMsg>[];
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(kChatMirror);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        for (final e in list) {
          try {
            mirrorMsgs
                .add(ChatMsg.fromJson(Map<String, dynamic>.from(e as Map)));
          } catch (_) {}
        }
      }
    } catch (_) {}

    // union, deduped, chronological, newest last
    final seen = <String>{};
    final merged = <ChatMsg>[...fileMsgs, ...mirrorMsgs]..sort(
        (a, b) => a.at.millisecondsSinceEpoch
            .compareTo(b.at.millisecondsSinceEpoch));
    final out = <ChatMsg>[];
    for (final m in merged) {
      final k = '${m.from}|${m.at.millisecondsSinceEpoch}|${m.text}';
      if (seen.add(k)) out.add(m);
    }
    final trimmed =
        out.length > 500 ? out.sublist(out.length - 500) : out;
    chats
      ..clear()
      ..addAll(trimmed);
    _stateStream.add(null);
  }

  /// Write a message to BOTH stores.
  Future<void> _persist(ChatMsg m) async {
    if (workspace.isNotEmpty) await ChatLog.append(workspace, m);
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(kChatMirror);
      final list =
          raw != null && raw.isNotEmpty ? (jsonDecode(raw) as List).toList() : <dynamic>[];
      list.add(m.toJson());
      while (list.length > 150) {
        list.removeAt(0);
      }
      await p.setString(kChatMirror, jsonEncode(list));
    } catch (_) {}
  }

  /// Wipe chat history everywhere (file + mirror + memory).
  Future<void> clearChats() async {
    chats.clear();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(kChatMirror);
    } catch (_) {}
    try {
      if (workspace.isNotEmpty) {
        final f = ChatLog.file(workspace);
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
    _stateStream.add(null);
  }

  /// Connect the relay (Bridge screen "Go Online", three-dot menu, auto-resume).
  Future<void> connect({
    required String relayBase,
    required String key,
    required String deviceId,
    required String mode,
    required void Function(String text, {bool error}) log,
  }) async {
    if (online) return;
    ops ??= PlatformOps(workspace: workspace, mode: mode);
    final eng = RelayEngine(
      baseUrl: relayBase,
      key: key,
      deviceId: deviceId,
      mode: mode,
      ops: ops!,
      log: (e) => log(e.text, error: e.isError),
    );
    eng.onChat = (from, text, att) => _onOperatorChat(from, text, att);
    eng.onOperatorAlive = () {
      paired = true;
      _stateStream.add(null);
    };
    engine = eng;
    await eng.start();
    await _keepAlive(true);
    onOnlineChanged?.call(true);
    _stateStream.add(null);
  }

  Future<void> disconnect() async {
    await engine?.stop();
    engine = null;
    await _keepAlive(false);
    onOnlineChanged?.call(false);
    _stateStream.add(null);
  }

  /// Toggle from any screen, using the store as the source of truth.
  Future<void> toggleWith(Store s,
      void Function(String text, {bool error}) log) async {
    if (online) {
      await disconnect();
      return;
    }
    log('connecting to operator relay…');
    await connect(
      relayBase: s.relayBase,
      key: s.bridgeKey,
      deviceId: s.deviceId,
      mode: s.mode,
      log: log,
    );
  }

  /// Cold-start auto-resume: if the app was online when it was closed,
  /// reconnect immediately — "withstand app closes".
  Future<void> autoResume(Store s) async {
    if (!s.wasOnline || online) return;
    autoLog('auto-resume: reconnecting relay…');
    try {
      await connect(
        relayBase: s.relayBase,
        key: s.bridgeKey,
        deviceId: s.deviceId,
        mode: s.mode,
        log: autoLog,
      );
    } catch (e) {
      autoLog('auto-resume failed: $e', error: true);
    }
  }

  // -------------------------------------------------------------------------
  // 6-digit pairing — the consumer flow.
  // -------------------------------------------------------------------------

  /// Register a fresh 6-digit code on the relay. Returns the code or throws.
  Future<String> startPairing(Store s) async {
    s.generatePairCode();
    await s.save();
    final r = await http
        .post(Uri.parse('${s.relayBase}/api/pair/start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': s.pairCode, 'device': s.deviceId}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw 'relay rejected the code (HTTP ${r.statusCode})';
    }
    pairingNow = true;
    _stateStream.add(null);
    _pollPair(s);
    return s.pairCode;
  }

  void _pollPair(Store s) {
    _pairPoll?.cancel();
    _pairPoll = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (!pairingNow || s.pairCode.length != 6) {
        t.cancel();
        return;
      }
      try {
        final r = await http
            .get(Uri.parse('${s.relayBase}/api/pair/status?code=${s.pairCode}'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final d = jsonDecode(r.body) as Map;
          if (d['claimed'] == true && !s.pairClaimed) {
            s.pairClaimed = true;
            await s.save();
            pairingNow = false;
            t.cancel();
            autoLog('operator connected — link is live ✓');
            if (!online) {
              await connect(
                relayBase: s.relayBase,
                key: s.bridgeKey,
                deviceId: s.deviceId,
                mode: s.mode,
                log: autoLog,
              );
            }
            _stateStream.add(null);
          }
        }
      } catch (_) {
        // transient — keep polling until the window closes
        if (s.pairingOpen == false) {
          pairingNow = false;
          t.cancel();
          _stateStream.add(null);
        }
      }
    });
  }

  void stopPairing() {
    pairingNow = false;
    _pairPoll?.cancel();
    _pairPoll = null;
    _stateStream.add(null);
  }

  // -------------------------------------------------------------------------
  // Chat
  // -------------------------------------------------------------------------

  /// User sent a message on the Chat screen.
  Future<void> sendChat(String text) async {
    final m = ChatMsg('me', text);
    chats.add(m);
    _chatStream.add(m);
    await _persist(m);
    await engine?.sendChat(text);
  }

  /// User attached a file (already size-checked + compressed by the UI).
  Future<void> sendAttachment(String name, String mime, List<int> bytes) async {
    final m = ChatMsg('me', '📎 $name',
        attName: name, attMime: mime, attSize: bytes.length);
    chats.add(m);
    _chatStream.add(m);
    await _persist(m);
    final url = await engine?.sendAttachment(name, mime, bytes);
    await markAttachmentUploaded(name, url);
  }

  /// Fill in the asset URL once the upload lands (enables inline preview).
  Future<void> markAttachmentUploaded(String name, String? url) async {
    if (url == null || url.isEmpty) {
      _stateStream.add(null);
      return;
    }
    for (var i = chats.length - 1; i >= 0; i--) {
      final m = chats[i];
      if (m.from == 'me' && m.attName == name && (m.attUrl ?? '').isEmpty) {
        final done = ChatMsg('me', m.text,
            at: m.at,
            attName: m.attName,
            attMime: m.attMime,
            attUrl: url,
            attSize: m.attSize);
        chats[i] = done;
        await _persist(done);
        _chatStream.add(done);
        break;
      }
    }
    _stateStream.add(null);
  }

  Future<void> _onOperatorChat(
      String from, String text, Map<String, dynamic>? att) async {
    final m = ChatMsg('orubus', text,
        attName: att?['name']?.toString(),
        attMime: att?['mime']?.toString(),
        attUrl: att?['url']?.toString(),
        attSize: att?['size'] == null ? null : (att!['size'] as num).toInt());
    chats.add(m);
    _chatStream.add(m);
    await _persist(m);
  }

  /// Operator-side helper (tests): inject a message without the wire.
  void injectForTest(ChatMsg m) {
    chats.add(m);
    _chatStream.add(m);
  }
}
