import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../bridge/link.dart';
import '../store.dart';
import '../version.dart';
import '../widgets/neu.dart';

const _releasesApi =
    'https://api.github.com/repos/orubus-dev/orubus-harness/releases/latest';

class SettingsScreen extends StatefulWidget {
  final Store store;
  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _mode = 'safe';
  bool _autoLaunch = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.store.mode;
    _autoLaunch = widget.store.wasOnline;
  }

  Future<void> _save({bool? autoLaunch}) async {
    final s = widget.store;
    s.mode = _mode;
    if (autoLaunch != null) {
      s.wasOnline = autoLaunch;
      _autoLaunch = autoLaunch;
    }
    await s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('saved'), duration: Duration(seconds: 1)));
  }

  Future<void> _checkUpdates() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('checking…'), duration: Duration(seconds: 1)));
    try {
      final r = await http.get(Uri.parse(_releasesApi),
          headers: {'User-Agent': 'orubus-harness-updater'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final rel = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = (rel['tag_name'] ?? '').toString();
      final url = (rel['html_url'] ?? '').toString();
      final newer = tag.isNotEmpty && tag != 'v$kAppVersion';
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: Neu.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Neu.radius)),
          title: Text(newer ? 'Update available' : 'Up to date'),
          content: Text(newer
              ? 'Latest release: $tag\nInstalled: v$kAppVersion\n\nSame key signs every build — updates install over the old version.'
              : 'Installed: v$kAppVersion — this IS the latest.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
            if (newer)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Neu.accentDeep),
                onPressed: () {
                  Navigator.pop(context);
                  _openInBrowser(url);
                },
                child: const Text('Get it'),
              ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('update check failed: $e'),
          duration: const Duration(seconds: 3)));
    }
  }

  Future<void> _openInBrowser(String url) async {
    const chan = MethodChannel('harness/device');
    try {
      await chan.invokeMethod('openUrl', {'url': url});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 14), children: [
      NeuCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeuSection('bridge mode'),
          DropdownButtonFormField<String>(
            value: _mode,
            dropdownColor: Neu.surface,
            decoration: const InputDecoration(
                labelText: 'mode',
                labelStyle: TextStyle(fontSize: 12, color: Neu.inkSoft),
                border: InputBorder.none),
            items: const [
              DropdownMenuItem(value: 'safe', child: Text('safe — guardrails on')),
              DropdownMenuItem(
                  value: 'open', child: Text('open — full shell (think first)')),
            ],
            onChanged: (v) {
              setState(() => _mode = v ?? 'safe');
              _save();
            },
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: Neu.accentDeep,
            title: const Text('Auto-launch the bridge',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Neu.ink)),
            subtitle: const Text(
                'Reconnect by itself whenever the app opens — survives closes and process kills.',
                style: TextStyle(fontSize: 11.5, color: Neu.inkSoft)),
            value: _autoLaunch,
            onChanged: (v) => _save(autoLaunch: v),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      NeuCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeuSection('updates'),
          Text('installed: v$kAppVersion',
              style: const TextStyle(fontSize: 12, color: Neu.inkSoft)),
          const SizedBox(height: 8),
          NeuButton(
              label: 'CHECK FOR UPDATES',
              icon: Icons.system_update,
              small: true,
              onTap: _checkUpdates),
        ]),
      ),
      const SizedBox(height: 14),
      NeuInset(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeuSection('about'),
          Text(
              'Orubous Harness v$kAppVersion — the direct line.\n'
              'Chat here talks to Orubus.ai himself — no API, no key, no middleman config. '
              'The same channel carries his commands: shell, python, files, screen, logs, skills.\n\n'
              'Workspace: ${Link.i.workspace}\n\n'
              'Outbound-only transport: no open ports, nothing can reach this device '
              'unless it answers to your token. Identity is revocable in one tap '
              '(regenerate on the Pairing screen — the old one is dead).',
              style: const TextStyle(fontSize: 12, color: Neu.inkSoft, height: 1.5)),
        ]),
      ),
    ]);
  }
}
