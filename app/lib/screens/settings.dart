import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../store.dart';

const _appVersion = '1.2026.10.1';
const _releasesApi =
    'https://api.github.com/repos/orubus-dev/orubus-harness/releases/latest';

class SettingsScreen extends StatefulWidget {
  final Store store;
  final String docsDir;
  const SettingsScreen({super.key, required this.store, required this.docsDir});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _topic, _token, _ntfy;
  String _mode = 'safe';

  @override
  void initState() {
    super.initState();
    final s = widget.store;
    _topic = TextEditingController(text: s.topic);
    _token = TextEditingController(text: s.token);
    _ntfy = TextEditingController(text: s.ntfyBase);
    _mode = s.mode;
  }

  @override
  void dispose() {
    _topic.dispose();
    _token.dispose();
    _ntfy.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = widget.store;
    s.topic = _topic.text.trim();
    s.token = _token.text.trim();
    s.ntfyBase = _ntfy.text.trim().isEmpty ? 'https://ntfy.sh' : _ntfy.text.trim();
    s.mode = _mode;
    await s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('saved'), duration: Duration(seconds: 1)));
  }

  Future<void> _checkUpdates() async {
    const msg = SnackBar(content: Text('checking…'), duration: Duration(seconds: 1));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(msg);
    try {
      final r = await http.get(Uri.parse(_releasesApi),
          headers: {'User-Agent': 'orubus-harness-updater'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final rel = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = (rel['tag_name'] ?? '').toString();
      final url = (rel['html_url'] ?? '').toString();
      final newer = tag.isNotEmpty && tag != 'v$_appVersion';
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(newer ? 'Update available' : 'Up to date'),
          content: Text(newer
              ? 'Latest release: $tag\nInstalled: v$_appVersion\n\nSame key signs every build — updates install over the old version.'
              : 'Installed: v$_appVersion — this IS the latest.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
            if (newer)
              FilledButton(
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

  Future<void> _newIdentity() async {
    widget.store.generateIdentity();
    _topic.text = widget.store.topic;
    _token.text = widget.store.token;
    await _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('new token generated — old channel is dead'),
        duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _section('operator channel'),
        _field(_ntfy, 'relay base URL', hint: 'https://ntfy.sh'),
        _field(_topic, 'topic'),
        _field(_token, 'token', obscure: true),
        DropdownButtonFormField<String>(
          value: _mode,
          decoration: const InputDecoration(labelText: 'mode'),
          items: const [
            DropdownMenuItem(value: 'safe', child: Text('safe — guardrails on')),
            DropdownMenuItem(
                value: 'open', child: Text('open — full shell (think first)')),
          ],
          onChanged: (v) => setState(() => _mode = v ?? 'safe'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('Save')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
                onPressed: _newIdentity,
                icon: const Icon(Icons.refresh),
                label: const Text('New token')),
          ),
        ]),
        Text('workspace: ${widget.docsDir}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 16),
        _section('updates'),
        Text('installed: v$_appVersion',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: _checkUpdates,
          icon: const Icon(Icons.system_update),
          label: const Text('Check for updates'),
        ),
        const SizedBox(height: 24),
        _section('about'),
        const Text(
            'Orubous Harness v1.1 — the direct line.\n'
            'Chat here talks to Orubus.ai himself — no API, no key, no middleman config. '
            'The same channel carries his commands: shell, python, files, screen, logs, skills.\n\n'
            'Outbound-only transport: no open ports, nothing can reach this device '
            'unless it answers to your token. Identity is revocable in one tap '
            '(generate a new token — the old one is dead).',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.45)),
      ]),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple.shade200)),
      );

  Widget _field(TextEditingController c, String label,
          {bool obscure = false, String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          decoration:
              InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        ),
      );
}
