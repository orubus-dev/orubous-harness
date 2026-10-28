import 'dart:math';

/// On-device identity + settings store.
/// Identity = topic + token. Deleting it revokes the channel instantly.
class Store {
  static const kTopic = 'topic',
      kToken = 'token',
      kNtfy = 'ntfyBase',
      kMode = 'mode',
      kAiBase = 'aiBase',
      kAiKey = 'aiKey',
      kAiModel = 'aiModel';

  String topic = '';
  String token = '';
  String ntfyBase = 'https://ntfy.sh';
  String mode = 'safe'; // safe | open
  String aiBase = 'https://api.z.ai/api/paas/v4';
  String aiKey = '';
  String aiModel = 'glm-4.6';

  bool get hasIdentity => topic.isNotEmpty && token.isNotEmpty;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    topic = p.getString(kTopic) ?? '';
    token = p.getString(kToken) ?? '';
    ntfyBase = p.getString(kNtfy) ?? ntfyBase;
    mode = p.getString(kMode) ?? mode;
    aiBase = p.getString(kAiBase) ?? aiBase;
    aiKey = p.getString(kAiKey) ?? '';
    aiModel = p.getString(kAiModel) ?? aiModel;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kTopic, topic);
    await p.setString(kToken, token);
    await p.setString(kNtfy, ntfyBase);
    await p.setString(kMode, mode);
    await p.setString(kAiBase, aiBase);
    await p.setString(kAiKey, aiKey);
    await p.setString(kAiModel, aiModel);
  }

  /// New identity: unguessable topic + 56-hex token. Cheap rotation by design.
  void generateIdentity() {
    final r = Random.secure();
    topic = 'orubous-${_hex(r, 24)}';
    token = _hex(r, 56);
  }

  static String _hex(Random r, int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
}
