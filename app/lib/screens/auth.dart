import 'package:flutter/material.dart';

import '../bridge/link.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Authentication — two credentials, one screen:
///
/// 1. OPERATOR CHAT ENDPOINT: the chat.z.ai URL where the operator brain
///    lives. Users authenticate by holding that link; uploads (images,
///    video, files) and the model picker are native on that side.
///
/// 2. RESTORE IDENTITY: paste the ORUBUS-LINK1 line and the channel comes
///    back instantly — fresh installs and reinstalls skip the 30-minute
///    pairing dance entirely.
class AuthScreen extends StatefulWidget {
  final Store store;
  const AuthScreen({super.key, required this.store});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final TextEditingController _url, _line;
  String _urlMsg = '';
  String _lineMsg = '';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.store.chatUrl);
    _line = TextEditingController();
  }

  @override
  void dispose() {
    _url.dispose();
    _line.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    final u = _url.text.trim();
    if (!Store.looksLikeChatUrl(u)) {
      setState(() => _urlMsg = 'not a chat.z.ai chat link — expected https://chat.z.ai/c/<chat-id>');
      return;
    }
    final s = widget.store;
    s.chatUrl = u;
    await s.save();
    Link.i.autoLog('operator chat endpoint saved: …${u.split('/').last}');
    if (!mounted) return;
    setState(() => _urlMsg = 'saved ✓ — this device now points at the operator chat');
  }

  Future<void> _restore() async {
    final s = widget.store;
    final ok = s.restoreFromPairLine(_line.text);
    if (!ok) {
      setState(() => _lineMsg = 'invalid — expected: ORUBUS-LINK1 topic=<topic> token=<token>');
      return;
    }
    await s.save();
    Link.i.paired = false;
    if (!mounted) return;
    setState(() => _lineMsg = 'identity restored ✓ — open Bridge and Go Online');
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('channel identity restored — no pairing needed'),
        duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    return ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 14), children: [
      NeuCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeuSection('operator chat endpoint'),
          Text(
            'The URL of the chat where the operator brain lives. Hold the link = you are authenticated. '
            'Images, video, files and the model picker are native on that side — this app is the portable half of the same line.',
            style: TextStyle(fontSize: 12, height: 1.5, color: Neu.inkSoft)),
          const SizedBox(height: 10),
          NeuInset(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: TextField(
              controller: _url,
              style: const TextStyle(fontSize: 13, color: Neu.ink),
              decoration: const InputDecoration(
                  labelText: 'chat.z.ai link',
                  labelStyle: TextStyle(fontSize: 12, color: Neu.inkSoft),
                  hintText: 'https://chat.z.ai/c/…',
                  hintStyle: TextStyle(fontSize: 12, color: Neu.inkSoft),
                  border: InputBorder.none),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            NeuButton(label: 'SAVE ENDPOINT', icon: Icons.verified_outlined, small: true,
                fill: Neu.accent, onTap: _saveUrl),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.chatUrl.isEmpty
                    ? 'no endpoint saved'
                    : 'saved: …${s.chatUrlShort}',
                style: const TextStyle(fontSize: 11.5, color: Neu.inkSoft),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          if (_urlMsg.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_urlMsg,
                style: TextStyle(
                    fontSize: 11.5,
                    color: _urlMsg.startsWith('saved') ? Neu.good : Neu.bad)),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      NeuCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeuSection('restore channel identity'),
          Text(
            'Paste the ORUBUS-LINK1 line the operator holds for you (topic + token). '
            'The channel resumes instantly — this is how reinstalls skip pairing completely.',
            style: TextStyle(fontSize: 12, height: 1.5, color: Neu.inkSoft)),
          const SizedBox(height: 10),
          NeuInset(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: TextField(
              controller: _line,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12, color: Neu.ink),
              decoration: const InputDecoration(
                  labelText: 'ORUBUS-LINK1 …',
                  labelStyle: TextStyle(fontSize: 12, color: Neu.inkSoft),
                  border: InputBorder.none),
            ),
          ),
          const SizedBox(height: 10),
          NeuButton(label: 'RESTORE IDENTITY', icon: Icons.restore, small: true,
              onTap: _restore),
          if (_lineMsg.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_lineMsg,
                style: TextStyle(
                    fontSize: 11.5,
                    color: _lineMsg.contains('✓') ? Neu.good : Neu.bad)),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      NeuInset(
        padding: const EdgeInsets.all(14),
        child: Text(
          'Outbound-only transport: nothing reaches this device unless it answers to your token. '
          'Regenerating the token on the Pairing screen kills the old channel instantly.',
          style: TextStyle(fontSize: 11.5, height: 1.5, color: Neu.inkSoft)),
      ),
    ]);
  }
}
