import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// On-device store — v2 relay-first.
/// The 6-digit pairing code replaces the hex topic/token dance: the app
/// registers a code, the operator claims it, done. Identity = a device id
/// (random, persisted) + the pairing state. Chat history survives restarts.
class Store {
  static const kTopic = 'topic',
      kToken = 'token',
      kNtfy = 'ntfyBase',
      kMode = 'mode',
      kPairAt = 'pairAt',
      kWasOnline = 'wasOnline',
      kChatUrl = 'chatUrl',
      kDeviceId = 'deviceId',
      kRelayBase = 'relayBase',
      kBridgeKey = 'bridgeKey',
      kPairCode = 'pairCode',
      kPairCodeAt = 'pairCodeAt',
      kPairClaimed = 'pairClaimed';

  /// The operator relay (Vercel). The phone talks ONLY to this host —
  /// no ntfy, no DNS drama, works on any carrier/Wi-Fi.
  static const defaultRelayBase = 'https://orubus-harness.vercel.app';
  static const defaultBridgeKey =
      'be49185f9187d8b8cba06104ea6f025a1a44dad2c15becef';

  String topic = ''; // legacy ntfy identity (unused in relay mode, kept for compat)
  String token = '';
  String ntfyBase = 'https://ntfy.sh';
  String mode = 'safe'; // safe | open
  String model = 'GLM-5.3-Flash'; // model picker selection, rides with each chat
  DateTime? pairAt;
  bool wasOnline = false;
  String chatUrl = '';

  String deviceId = ''; // stable random device id
  String relayBase = defaultRelayBase;
  String bridgeKey = defaultBridgeKey;
  String pairCode = ''; // current 6-digit code (empty = none)
  DateTime? pairCodeAt;
  bool pairClaimed = false; // operator claimed the current code

  bool get hasIdentity => deviceId.isNotEmpty;

  /// Pairing window: 15 minutes from code generation.
  Duration get pairingLeft {
    final p = pairCodeAt;
    if (p == null) return Duration.zero;
    final left = const Duration(minutes: 15) - DateTime.now().difference(p);
    return left.isNegative ? Duration.zero : left;
  }

  bool get pairingOpen => pairCode.length == 6 && pairingLeft > Duration.zero;

  String get chatUrlShort {
    final u = chatUrl;
    if (u.isEmpty) return '';
    final parts = u.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? u : parts.last;
  }

  bool restoreFromPairLine(String line) {
    final m = RegExp(r'ORUBUS-LINK1\s+topic=([0-9a-fA-F\-]+)\s+token=([0-9a-fA-F]+)')
        .firstMatch(line.trim());
    if (m == null) return false;
    topic = m.group(1)!;
    token = m.group(2)!;
    pairAt = DateTime.now();
    return true;
  }

  static bool looksLikeChatUrl(String url) {
    final u = url.trim();
    return u.startsWith('https://chat.z.ai/c/') && u.length > 'https://chat.z.ai/c/'.length;
  }

  /// Legacy ntfy identity — kept so old paired installs keep their channel.
  void generateIdentity() {
    final r = Random.secure();
    topic = 'orubous-${_hex(r, 24)}';
    token = _hex(r, 56);
    pairAt = DateTime.now();
  }

  /// Fresh 6-digit pairing code (relay-first flow).
  void generatePairCode() {
    final r = Random.secure();
    pairCode = (100000 + r.nextInt(900000)).toString();
    pairCodeAt = DateTime.now();
    pairClaimed = false;
  }

  static String _hex(Random r, int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    topic = p.getString(kTopic) ?? '';
    token = p.getString(kToken) ?? '';
    ntfyBase = p.getString(kNtfy) ?? ntfyBase;
    mode = p.getString(kMode) ?? mode;
    model = p.getString('model') ?? model;
    final ms = p.getInt(kPairAt) ?? 0;
    pairAt = ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    wasOnline = p.getBool(kWasOnline) ?? false;
    chatUrl = p.getString(kChatUrl) ?? '';
    deviceId = p.getString(kDeviceId) ?? '';
    relayBase = p.getString(kRelayBase) ?? defaultRelayBase;
    bridgeKey = p.getString(kBridgeKey) ?? defaultBridgeKey;
    pairCode = p.getString(kPairCode) ?? '';
    final pcAt = p.getInt(kPairCodeAt) ?? 0;
    pairCodeAt = pcAt > 0 ? DateTime.fromMillisecondsSinceEpoch(pcAt) : null;
    pairClaimed = p.getBool(kPairClaimed) ?? false;
    if (deviceId.isEmpty) {
      deviceId = 'dev-${_hex(Random.secure(), 12)}';
      await save();
    }
    // a stale unclaimed code from a previous session is dead — clear it
    if (!pairClaimed && !pairingOpen) {
      pairCode = '';
      pairCodeAt = null;
      await save();
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kTopic, topic);
    await p.setString(kToken, token);
    await p.setString(kNtfy, ntfyBase);
    await p.setString(kMode, mode);
    await p.setString('model', model);
    await p.setInt(kPairAt, pairAt?.millisecondsSinceEpoch ?? 0);
    await p.setBool(kWasOnline, wasOnline);
    await p.setString(kChatUrl, chatUrl);
    await p.setString(kDeviceId, deviceId);
    await p.setString(kRelayBase, relayBase);
    await p.setString(kBridgeKey, bridgeKey);
    await p.setString(kPairCode, pairCode);
    await p.setInt(kPairCodeAt, pairCodeAt?.millisecondsSinceEpoch ?? 0);
    await p.setBool(kPairClaimed, pairClaimed);
  }
}

/// One chat message in the direct line between the user and the operator.
/// [attName]/[attUrl] carry an attachment pointer (content lives on the
/// relay's asset store — small envelopes only).
class ChatMsg {
  final String from; // 'me' (device user) | 'orubus' (operator AI)
  final String text;
  final DateTime at;
  final String? attName;
  final String? attMime;
  final String? attUrl;
  final int? attSize;

  ChatMsg(this.from, this.text, {DateTime? at, this.attName, this.attMime, this.attUrl, this.attSize})
      : at = at ?? DateTime.now();

  bool get hasAttachment => attUrl != null && attUrl!.isNotEmpty;
  bool get attIsImage => (attMime ?? '').startsWith('image/');

  Map<String, dynamic> toJson() => {
        'from': from,
        'text': text,
        'at': at.millisecondsSinceEpoch,
        if (attName != null) 'attName': attName,
        if (attMime != null) 'attMime': attMime,
        if (attUrl != null) 'attUrl': attUrl,
        if (attSize != null) 'attSize': attSize,
      };

  static ChatMsg fromJson(Map<String, dynamic> j) => ChatMsg(
        (j['from'] ?? '?').toString(),
        (j['text'] ?? '').toString(),
        at: DateTime.fromMillisecondsSinceEpoch(((j['at'] ?? 0) as num).toInt()),
        attName: j['attName']?.toString(),
        attMime: j['attMime']?.toString(),
        attUrl: j['attUrl']?.toString(),
        attSize: j['attSize'] == null ? null : ((j['attSize'] as num).toInt()),
      );
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
