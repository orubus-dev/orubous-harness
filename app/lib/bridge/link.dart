import 'dart:async';

import 'engine.dart';
import 'handlers.dart';
import '../store.dart';

/// App-wide singleton: ONE bridge engine, shared by the Chat and Bridge tabs.
/// The user chats on the Chat tab; the same channel carries operator tasks.
class Link {
  Link._();
  static final Link i = Link._();

  BridgeEngine? engine;
  PlatformOps? ops;
  String workspace = '';
  bool paired = false; // operator answered at least once on this identity

  final List<ChatMsg> chats = <ChatMsg>[];
  final _chatStream = StreamController<ChatMsg>.broadcast();
  Stream<ChatMsg> get chatStream => _chatStream.stream;
  final _stateStream = StreamController<void>.broadcast();
  Stream<void> get stateStream => _stateStream.stream;

  bool get online => engine?.running ?? false;

  Future<void> loadHistory() async {
    if (workspace.isEmpty) return;
    final h = await ChatLog.load(workspace);
    chats
      ..clear()
      ..addAll(h);
    _stateStream.add(null);
  }

  /// Connect the bridge (called from Bridge tab "Go Online").
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
    _stateStream.add(null);
  }

  Future<void> disconnect() async {
    await engine?.stop();
    engine = null;
    _stateStream.add(null);
  }

  /// User sent a message on the Chat tab.
  Future<void> sendChat(String text) async {
    final m = ChatMsg('me', text);
    chats.add(m);
    _chatStream.add(m);
    if (workspace.isNotEmpty) await ChatLog.append(workspace, m);
    await engine?.sendChat(text);
  }

  Future<void> _onOperatorChat(String from, String text) async {
    final m = ChatMsg('orubus', text);
    chats.add(m);
    _chatStream.add(m);
    if (workspace.isNotEmpty) await ChatLog.append(workspace, m);
  }

  /// Operator-side helper (tests): inject a message without the wire.
  void injectForTest(ChatMsg m) {
    chats.add(m);
    _chatStream.add(m);
  }
}
