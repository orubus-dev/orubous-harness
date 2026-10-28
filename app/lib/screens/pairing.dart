import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/link.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Pairing — owns the connectivity token: view, copy, regenerate, and
/// advanced manual editing of the channel identity (topic/token/relay).
class PairingScreen extends StatefulWidget {
  final Store store;
  const PairingScreen({super.key, required this.store});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _scroll = ScrollController();
  StreamSubscription<void>? _stateSub;
  Timer? _ticker;
  bool _advanced = false;
  late final TextEditingController _topic, _token, _ntfy;

  @override
  void initState() {
    super.initState();
    final s = widget.store;
    _topic = TextEditingController(text: s.topic);
    _token = TextEditingController(text: s.token);
    _ntfy = TextEditingController(text: s.ntfyBase);
    _stateSub = Link.i.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _topic.dispose();
    _token.dispose();
    _ntfy.dispose();
    _stateSub?.cancel();
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _generateToken() async {
    final s = widget.store;
    s.generateIdentity();
    Link.i.paired = false;
    _topic.text = s.topic;
    _token.text = s.token;
    await s.save();
    Link.i.autoLog('new connectivity token generated — old channel is dead');
    if (mounted) setState(() {});
  }

  void _copyPairing() {
    Clipboard.setData(ClipboardData(text: widget.store.pasteString));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('pairing string copied — paste it to Orubus.ai'),
        duration: Duration(seconds: 2)));
  }

  Future<void> _saveAdvanced() async {
    final s = widget.store;
    s.topic = _topic.text.trim();
    s.token = _token.text.trim();
    s.ntfyBase = _ntfy.text.trim().isEmpty ? 'https://ntfy.sh' : _ntfy.text.trim();
    await s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('channel identity saved'),
        duration: Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final left = s.pairingLeft;
    final mm = left.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = left.inSeconds.remainder(60).toString().padLeft(2, '0');
    final paired = Link.i.paired;

    return ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 14), children: [
      NeuCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('CONNECTIVITY TOKEN',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: Neu.inkSoft)),
            const Spacer(),
            NeuPill(
              paired
                  ? 'PAIRED ✓'
                  : (s.pairingOpen ? 'WINDOW $mm:$ss' : 'WINDOW CLOSED'),
              color: paired
                  ? Neu.good
                  : (s.pairingOpen ? Neu.warn : Neu.bad),
            ),
          ]),
          const SizedBox(height: 10),
          if (!s.hasIdentity)
            const Text(
                'No token yet. Generate one, paste the string to Orubus.ai in your chat — he connects back and the line stays yours.',
                style: TextStyle(fontSize: 12.5, height: 1.45, color: Neu.inkSoft))
          else ...[
            NeuInset(
              padding: const EdgeInsets.all(12),
              child: SelectableText(s.pasteString,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12, height: 1.4, color: Neu.ink)),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: NeuButton(
                  label: 'COPY PAIRING STRING',
                  icon: Icons.copy,
                  small: true,
                  onTap: _copyPairing,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: NeuButton(
                  label: 'REGENERATE',
                  icon: Icons.refresh,
                  small: true,
                  textColor: Neu.bad,
                  onTap: _generateToken,
                ),
              ),
            ]),
          ],
          if (!s.hasIdentity) ...[
            const SizedBox(height: 12),
            NeuButton(
              label: 'GENERATE CONNECTIVITY TOKEN',
              icon: Icons.key,
              fill: Neu.accent,
              onTap: _generateToken,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            paired
                ? 'Paired — this identity lives until you regenerate it. Reinstalling? Authentication screen restores it in one paste.'
                : 'The 30-minute window only guards the first handshake. After pairing, the identity is long-lived.',
            style: const TextStyle(fontSize: 11, height: 1.45, color: Neu.inkSoft),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      GestureDetector(
        onTap: () => setState(() => _advanced = !_advanced),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(children: [
            Text('ADVANCED — MANUAL CHANNEL EDIT',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: Neu.inkSoft)),
            SizedBox(width: 6),
            Icon(_advanced ? Icons.expand_less : Icons.expand_more,
                size: 16, color: Neu.inkSoft),
          ]),
        ),
      ),
      if (_advanced)
        NeuCard(
          child: Column(children: [
            _field(_ntfy, 'relay base URL', hint: 'https://ntfy.sh'),
            _field(_topic, 'topic'),
            _field(_token, 'token'),
            const SizedBox(height: 6),
            NeuButton(label: 'SAVE', icon: Icons.save, small: true, onTap: _saveAdvanced),
          ]),
        ),
    ]);
  }

  Widget _field(TextEditingController c, String label, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: NeuInset(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: TextField(
            controller: c,
            style: const TextStyle(fontSize: 13.5, color: Neu.ink),
            decoration: InputDecoration(
                labelText: label,
                labelStyle: const TextStyle(fontSize: 12, color: Neu.inkSoft),
                hintText: hint,
                hintStyle: const TextStyle(fontSize: 12, color: Neu.inkSoft),
                border: InputBorder.none),
          ),
        ),
      );
}
