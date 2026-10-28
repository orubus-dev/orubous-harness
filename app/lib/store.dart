import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// On-device identity + settings store.
/// Identity = topic + token, generated ON THE DEVICE (never by the operator).
/// The user pastes the pairing string to the operator; operator connects back.
/// Deleting identity revokes the channel instantly.
class Store {
  static const kTopic = 'topic',
      kToken = 'token',
      kNtfy = 'ntfyBase',
      kMode = 'mode',
      kPairAt = 'pairAt',
      kWasOnline = 'wasOnline',
      kChatUrl = 'chatUrl';

  String topic = '';
  String token = '';
  String ntfyBase = 'https://ntfy.sh';
  String mode = 'safe'; // safe | open
  DateTime? pairAt; // when the current token was generated (30-min pairing window)
  bool wasOnline = false; // auto-resume the bridge on app launch
  String chatUrl = ''; // operator chat endpoint (chat.z.ai/c/<id>)

  bool get hasIdentity => topic.isNotEmpty && token.isNotEmpty;

  /// Pairing window: operator must connect within 30 minutes of generation.
  Duration get pairingLeft {
    final p = pairAt;
    if (p == null) return Duration.zero;
    final left = const Duration(minutes: 30) - DateTime.now().difference(p);
    return left.isNegative ? Duration.zero : left;
  }

  bool get pairingOpen => hasIdentity && pairingLeft > Duration.zero;

  /// Short display id of the operator chat endpoint (last URL segment).
  String get chatUrlShort {
    final u = chatUrl;
    if (u.isEmpty) return '';
    final parts = u.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? u : parts.last;
  }

  /// The exact string the user pastes into the chat with the operator.
  String get pasteString =>
      hasIdentity ? 'ORUBUS-LINK1 topic=$topic token=$token' : '';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    topic = p.getString(kTopic) ?? '';
    token = p.getString(kToken) ?? '';
    ntfyBase = p.getString(kNtfy) ?? ntfyBase;
    mode = p.getString(kMode) ?? mode;
    final ms = p.getInt(kPairAt) ?? 0;
    pairAt = ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    wasOnline = p.getBool(kWasOnline) ?? false;
    chatUrl = p.getString(kChatUrl) ?? '';
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kTopic, topic);
    await p.setString(kToken, token);
    await p.setString(kNtfy, ntfyBase);
    await p.setString(kMode, mode);
    await p.setInt(kPairAt, pairAt?.millisecondsSinceEpoch ?? 0);
    await p.setBool(kWasOnline, wasOnline);
    await p.setString(kChatUrl, chatUrl);
  }

  /// Restore a full identity from a pasted pairing line:
  ///   ORUBUS-LINK1 topic=<24hex> token=<56hex>
  /// Used by the Authentication screen — turns a fresh install (or a
  /// reinstall) into a one-paste resume instead of a 30-minute pairing.
  bool restoreFromPairLine(String line) {
    final m = RegExp(r'ORUBUS-LINK1\s+topic=([0-9a-fA-F\-]+)\s+token=([0-9a-fA-F]+)')
        .firstMatch(line.trim());
    if (m == null) return false;
    topic = m.group(1)!;
    token = m.group(2)!;
    pairAt = DateTime.now();
    return true;
  }

  /// True when the pasted URL looks like an operator chat endpoint.
  static bool looksLikeChatUrl(String url) {
    final u = url.trim();
    return u.startsWith('https://chat.z.ai/c/') && u.length > 'https://chat.z.ai/c/'.length;
  }

  /// Generate a fresh connectivity token (the user taps this in the app).
  void generateIdentity() {
    final r = Random.secure();
    topic = 'orubous-${_hex(r, 24)}';
    token = _hex(r, 56);
    pairAt = DateTime.now();
  }

  static String _hex(Random r, int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// One chat message in the direct line between the user and the operator.
class ChatMsg {
  final String from; // 'me' (device user) | 'orubus' (operator AI)
  final String text;
  final DateTime at;
  ChatMsg(this.from, this.text, {DateTime? at}) : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() =>
      {'from': from, 'text': text, 'at': at.millisecondsSinceEpoch};

  static ChatMsg fromJson(Map<String, dynamic> j) => ChatMsg(
      (j['from'] ?? '?').toString(),
      (j['text'] ?? '').toString(),
      at: DateTime.fromMillisecondsSinceEpoch(((j['at'] ?? 0) as num).toInt()));
}

/// Chat history persistence (jsonl in the app workspace).
class ChatLog {
  static const maxBytes = 512 * 1024;

  static Future<List<ChatMsg>> load(String workspace) async {
    try {
      final f = file(workspace);
      if (!f.existsSync()) return [];
      final lines = f.readAsStringSync().split('\n').where((l) => l.isNotEmpty);
      return lines.map((l) {
        try {
          return ChatMsg.fromJson(Map<String, dynamic>.from(jsonDecode(l)));
        } catch (_) {
          return ChatMsg('me', '(unreadable entry)');
        }
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> append(String workspace, ChatMsg m) async {
    try {
      final f = file(workspace);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${jsonEncode(m.toJson())}\n',
          mode: FileMode.append);
      if (f.lengthSync() > maxBytes) {
        // keep the last ~200 lines, then continue appending
        final lines = f.readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();
        final keep = lines.length > 200 ? lines.sublist(lines.length - 200) : lines;
        f.writeAsStringSync(keep.join('\n') + '\n');
      }
    } catch (_) {}
  }

  static File file(String ws) {
    final sep = ws.endsWith('/') || ws.endsWith('\\') ? '' : '/';
    return File('$ws${sep}chat_history.jsonl');
  }
}
