import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'bspatch.dart';
import 'modules.dart';

/// One entry from the relay's update manifest.
class ModuleEntry {
  final String name;
  final int version;
  final String url;
  final String sha256;
  ModuleEntry({required this.name, required this.version, required this.url, required this.sha256});

  factory ModuleEntry.fromJson(Map<String, dynamic> j) => ModuleEntry(
        name: (j['name'] ?? '').toString(),
        version: (j['version'] is num) ? (j['version'] as num).toInt() : int.tryParse('${j['version']}') ?? 0,
        url: (j['url'] ?? '').toString(),
        sha256: (j['sha256'] ?? '').toString(),
      );
}

class ReleaseEntry {
  final String version;
  final int code;
  final String kind; // 'delta' | 'full'
  final int baseCode; // for delta: the versionCode the patch applies to
  final String url;
  final String sha256;
  final String notes;
  ReleaseEntry({
    required this.version,
    required this.code,
    required this.kind,
    required this.baseCode,
    required this.url,
    required this.sha256,
    required this.notes,
  });

  bool get isDelta => kind == 'delta';

  factory ReleaseEntry.fromJson(Map<String, dynamic> j) => ReleaseEntry(
        version: (j['version'] ?? '').toString(),
        code: (j['code'] is num) ? (j['code'] as num).toInt() : int.tryParse('${j['code']}') ?? 0,
        kind: (j['kind'] ?? 'full').toString(),
        baseCode: (j['base_code'] is num) ? (j['base_code'] as num).toInt() : int.tryParse('${j['base_code']}') ?? 0,
        url: (j['url'] ?? '').toString(),
        sha256: (j['sha256'] ?? '').toString(),
        notes: (j['notes'] ?? '').toString(),
      );
}

class UpdateManifest {
  final List<ModuleEntry> modules;
  final ReleaseEntry? release;
  UpdateManifest({required this.modules, this.release});

  factory UpdateManifest.fromJson(Map<String, dynamic> j) => UpdateManifest(
        modules: (j['modules'] as List? ?? [])
            .whereType<Map>()
            .map((m) => ModuleEntry.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        release: j['release'] is Map ? ReleaseEntry.fromJson(Map<String, dynamic>.from(j['release'] as Map)) : null,
      );
}

/// Delta update engine: talks to the relay's /api/updates/manifest,
/// hot-applies config modules (no reinstall), and for binary releases
/// either downloads the full APK or applies a bsdiff delta against the
/// installed APK, then hands it to the Android installer.
class Updater {
  final String relayBase;
  final String key;
  Updater({required this.relayBase, required this.key});

  static const kAppVersion = '1.2026.10.7.1';
  static const kAppCode = 120261008;

  Map<String, String> get _headers => {'Authorization': 'Bearer $key'};

  Future<UpdateManifest> check() async {
    final installed = await Modules.versions();
    final q = installed.isEmpty
        ? ''
        : '?' + installed.entries.map((e) => 'mod_${Uri.encodeQueryComponent(e.key)}=${e.value}').join('&');
    final r = await http
        .get(Uri.parse('$relayBase/api/updates/manifest$q'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw 'manifest HTTP ${r.statusCode}';
    final d = jsonDecode(utf8.decode(r.bodyBytes));
    if (d is! Map) throw 'manifest not a map';
    return UpdateManifest.fromJson(Map<String, dynamic>.from(d));
  }

  /// Download + verify + install config modules. Returns applied names.
  Future<List<String>> applyModules(List<ModuleEntry> mods) async {
    final applied = <String>[];
    for (final m in mods) {
      if (m.name.isEmpty || m.url.isEmpty) continue;
      try {
        final raw = await _download(m.url, maxBytes: 2 << 20);
        if (m.sha256.isNotEmpty && !_sha(raw, m.sha256)) {
          throw 'sha mismatch for ${m.name}';
        }
        final payload = jsonDecode(utf8.decode(raw));
        if (payload is! Map) throw 'module ${m.name} not a map';
        await Modules.write(m.name, Map<String, dynamic>.from(payload));
        await Modules.setVersion(m.name, m.version);
        applied.add(m.name);
      } catch (_) {
        // a bad module never blocks the rest or the app
      }
    }
    await Modules.refreshModelLabels();
    return applied;
  }

  /// Prepare a release for install. Returns the path of a ready-to-install
  /// APK (delta patched or full download), verified by sha256.
  Future<String> prepareRelease(ReleaseEntry rel) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    Uint8List apkBytes;
    if (rel.isDelta) {
      if (rel.baseCode != kAppCode) {
        throw 'delta base ${rel.baseCode} != installed $kAppCode — need full update';
      }
      final patch = await _download(rel.url, maxBytes: 64 << 20);
      if (rel.sha256.isNotEmpty && !_sha(patch, rel.sha256)) {
        throw 'patch sha mismatch';
      }
      final srcApk = Platform.resolvedExecutable; // installed APK path
      final old = File(srcApk).readAsBytesSync();
      apkBytes = bspatch(old, patch);
    } else {
      apkBytes = await _download(rel.url, maxBytes: 128 << 20);
      if (rel.sha256.isNotEmpty && !_sha(apkBytes, rel.sha256)) {
        throw 'apk sha mismatch';
      }
    }
    final out = File('${dir.path}/update_${rel.code}.apk');
    await out.writeAsBytes(apkBytes, flush: true);
    return out.path;
  }

  /// Hand the APK to Android's package installer.
  Future<bool> install(String apkPath) async {
    try {
      const chan = MethodChannel('harness/device');
      final ok = await chan.invokeMethod('installApk', {'path': apkPath});
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List> _download(String url, {int maxBytes = 32 << 20}) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))..followRedirects = true;
      final resp = await client.send(req).timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) throw 'download HTTP ${resp.statusCode}';
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in resp.stream) {
        total += chunk.length;
        if (total > maxBytes) throw 'download exceeds ${maxBytes ~/ (1 << 20)}MB cap';
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }

  bool _sha(List<int> data, String expect) {
    final h = sha256.convert(data).toString();
    return h.toLowerCase() == expect.toLowerCase();
  }
}
