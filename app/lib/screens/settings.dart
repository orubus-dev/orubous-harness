import 'package:flutter/material.dart';

import '../store.dart';

class SettingsScreen extends StatefulWidget {
  final Store store;
  final String docsDir;
  const SettingsScreen({super.key, required this.store, required this.docsDir});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _topic,
      _token,
      _ntfy,
      _aiBase,
      _aiKey,
      _aiModel;
  String _mode = 'safe';

  @override
  void initState() {
    super.initState();
    final s = widget.store;
    _topic = TextEditingController(text: s.topic);
    _token = TextEditingController(text: s.token);
    _ntfy = TextEditingController(text: s.ntfyBase);
    _aiBase = TextEditingController(text: s.aiBase);
    _aiKey = TextEditingController(text: s.aiKey);
    _aiModel = TextEditingController(text: s.aiModel);
    _mode = s.mode;
  }

  @override
  void dispose() {
    _topic.dispose();
    _token.dispose();
    _ntfy.dispose();
    _aiBase.dispose();
    _aiKey.dispose();
    _aiModel.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = widget.store;
    s.topic = _topic.text.trim();
    s.token = _token.text.trim();
    s.ntfyBase = _ntfy.text.trim().isEmpty ? 'https://ntfy.sh' : _ntfy.text.trim();
    s.mode = _mode;
    s.aiBase = _aiBase.text.trim();
    s.aiKey = _aiKey.text.trim();
    s.aiModel = _aiModel.text.trim();
    await s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('saved'), duration: Duration(seconds: 1)));
  }

  Future<void> _newIdentity() async {
    widget.store.generateIdentity();
    _topic.text = widget.store.topic;
    _token.text = widget.store.token;
    await _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('new identity generated — old one is dead'),
        duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _section('operator bridge'),
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
                label: const Text('New identity')),
          ),
        ]),
        Text('workspace: ${widget.docsDir}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 24),
        _section('AI chat (OpenAI-compatible)'),
        _field(_aiBase, 'base URL', hint: 'https://api.z.ai/api/paas/v4'),
        _field(_aiKey, 'API key', obscure: true),
        _field(_aiModel, 'model', hint: 'glm-4.6'),
        const SizedBox(height: 8),
        FilledButton.tonal(
            onPressed: _save, child: const Text('Save AI config')),
        const SizedBox(height: 24),
        _section('about'),
        const Text(
            'Orubous Harness v1.0\n'
            'Outbound-only operator bridge + GLM chat.\n'
            'No open ports. Identity is revocable in one tap.\n'
            'Every bridge action is logged in the Bridge tab.',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
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
