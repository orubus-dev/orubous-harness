import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hot-swappable update modules — the "delta updates that only update
/// specific modules, not the whole app" layer. A module is a small JSON
/// file fetched from the relay's update manifest and written into
/// <docs>/modules/. Applied at runtime, NO reinstall needed.
///
/// Known modules:
///   model_map  → {"labels": ["GLM-5.3-Flash", ...]} overrides chat chips
///   ai_map     → {"fast": id, "default": id, "pro": id} model ids per chip
class Modules {
  Modules._();

  static const kDefaults = ['GLM-5.3-Flash', 'GLM-5.3', 'Fast'];

  static List<String>? _labelsCache;
  static String? _dirPath;

  static Future<String> dir() async {
    if (_dirPath != null) return _dirPath!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/modules');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dirPath = d.path;
    return d.path;
  }

  /// Read a module's payload, or null if not installed/corrupt.
  static Future<Map<String, dynamic>?> read(String name) async {
    try {
      final f = File('${await dir()}/$name.json');
      if (!f.existsSync()) return null;
      final raw = f.readAsStringSync();
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// Write a module payload (validated by the caller).
  static Future<void> write(String name, Map<String, dynamic> payload) async {
    final f = File('${await dir()}/$name.json');
    f.writeAsStringSync(jsonEncode(payload), flush: true);
    if (name == 'model_map') _labelsCache = null;
  }

  static Future<void> clear(String name) async {
    try {
      final f = File('${await dir()}/$name.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    if (name == 'model_map') _labelsCache = null;
  }

  /// Chat screen model chips: module override or built-in defaults.
  static List<String> modelLabels() {
    if (_labelsCache != null) return _labelsCache!;
    _labelsCache = kDefaults; // sync fallback; refreshed async below
    () async {
      final m = await read('model_map');
      final labels = m?['labels'];
      if (labels is List && labels.isNotEmpty) {
        final out = labels.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
        if (out.isNotEmpty) _labelsCache = out;
      }
    }();
    return _labelsCache!;
  }

  static Future<void> refreshModelLabels() async {
    final m = await read('model_map');
    final labels = m?['labels'];
    if (labels is List && labels.isNotEmpty) {
      final out = labels.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      if (out.isNotEmpty) _labelsCache = out;
    } else {
      _labelsCache = kDefaults;
    }
  }

  /// Installed module versions (name → version) for the manifest request.
  static Future<Map<String, int>> versions() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('moduleVersions');
      if (raw == null || raw.isEmpty) return {};
      final v = jsonDecode(raw);
      if (v is! Map) return {};
      final out = <String, int>{};
      v.forEach((k, val) {
        final n = val is num ? val.toInt() : int.tryParse('$val');
        if (n != null) out[k.toString()] = n;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> setVersion(String name, int version) async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = await versions();
      v[name] = version;
      await p.setString('moduleVersions', jsonEncode(v));
    } catch (_) {}
  }
}
