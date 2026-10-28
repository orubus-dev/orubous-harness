import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine.dart';
import 'handlers.dart';
import '../store.dart';

/// Android foreground keep-alive: holds the process up so the bridge isolate
/// keeps its ntfy stream while the app is backgrounded. No-op elsewhere.
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
class Link {
  Link._();
  static final Link i = Link._();

  static const kChatMirror = 'chatMirrorJson';

  BridgeEngine? engine;
  PlatformOps? ops;
  String workspace = '';
  bool paired = false; // operator answered at least once on this identity

  /// Hook set by the shell: persists the online flag for auto-resume.
  void Function(bool online)? onOnlineChanged;

  /// Engine events that happened before any screen was listening
  /// (auto-resume at cold start). Seeded into the Bridge activity log.
  final List<BridgeEvent> autoEvents = [];

  final List<ChatMsg> chats = <ChatMsg>[];
  final _chatStream = StreamController<ChatMsg>.broadcast();
  Stream<ChatMsg> get chatStream => _chatStream.stream;
  final _stateStream = StreamController<void>.broadcast();
  Stream<void> get stateStream => _stateStream.stream;

  bool get online => engine?.running ?? false;

  void autoLog(String text, {bool error = false}) {
    autoEvents.add(BridgeEvent(text, isError: error));
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
    _chatStream.add(null);
    _stateStream.add(null);
  }

  /// Connect the bridge (Bridge screen "Go Online", three-dot menu, auto-resume).
  Future<void> connect({
    required String ntfyBase,
    required String topic,
    required String token,
    required String mode,
    required void Function(String text, {bool error}) log,
  }) async {
    if (online) return;
    ops ??= PlatformOps(workspace: workspace, mode: mode);
    final eng = BridgeEngine(
      baseUrl: ntfyBase,
      topic: topic,
      token: token,
      mode: mode,
      ops: ops!,
      log: (e) => log(e.text, error: e.isError),
    );
    eng.onChat = (from, text) => _onOperatorChat(from, text);
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
    if (!s.hasIdentity) {
      log('no identity — open Pairing and generate a token first',
          error: true);
      return;
    }
    log('connecting to relay…');
    await connect(
      ntfyBase: s.ntfyBase,
      topic: s.topic,
      token: s.token,
      mode: s.mode,
      log: log,
    );
  }

  /// Cold-start auto-resume: if the app was online when it was closed,
  /// reconnect immediately — "withstand app closes".
  Future<void> autoResume(Store s) async {
    if (!s.wasOnline || !s.hasIdentity || online) return;
    autoLog('auto-resume: reconnecting bridge…');
    try {
      await connect(
        ntfyBase: s.ntfyBase,
        topic: s.topic,
        token: s.token,
        mode: s.mode,
        log: autoLog,
      );
    } catch (e) {
      autoLog('auto-resume failed: $e', error: true);
    }
  }

  /// User sent a message on the Chat screen.
  Future<void> sendChat(String text) async {
    final m = ChatMsg('me', text);
    chats.add(m);
    _chatStream.add(m);
    await _persist(m);
    await engine?.sendChat(text);
  }

  Future<void> _onOperatorChat(String from, String text) async {
    final m = ChatMsg('orubus', text);
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
