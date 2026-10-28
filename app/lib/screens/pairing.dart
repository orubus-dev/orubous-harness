import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/link.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Pairing v2 — the 6-digit code flow.
/// Generate a code → paste it in your chat with Orubus.ai → the link snaps
/// live automatically. No topics, no tokens, no hex.
class PairingScreen extends StatefulWidget {
  final Store store;
  const PairingScreen({super.key, required this.store});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  StreamSubscription<void>? _stateSub;
  Timer? _ticker;
  bool _advanced = false;
  bool _busy = false;
  late final TextEditingController _relay, _key, _ntfy;

  @override
  void initState() {
    super.initState();
    final s = widget.store;
    _relay = TextEditingController(text: s.relayBase);
    _key = TextEditingController(text: s.bridgeKey);
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
    _relay.dispose();
    _key.dispose();
    _ntfy.dispose();
    _stateSub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final code = await Link.i.startPairing(widget.store);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('code $code is live — paste it to Orubus.ai'),
          duration: const Duration(seconds: 3)));
    } catch (e) {
      Link.i.autoLog('pairing failed: $e', error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _copyCode() {
    final s = widget.store;
    if (s.pairCode.isEmpty) return;
    Clipboard.setData(ClipboardData(text: s.pairCode));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('code copied — paste it in your chat with Orubus.ai'),
        duration: Duration(seconds: 2)));
  }

  Future<void> _saveAdvanced() async {
    final s = widget.store;
    s.relayBase =
        _relay.text.trim().isEmpty ? Store.defaultRelayBase : _relay.text.trim();
    s.bridgeKey = _key.text.trim().isEmpty ? Store.defaultBridgeKey : _key.text.trim();
    s.ntfyBase = _ntfy.text.trim().isEmpty ? 'https://ntfy.sh' : _ntfy.text.trim();
    await s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('endpoint saved'), duration: Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final live = Link.i.online && (s.pairClaimed || Link.i.paired);
    final left = s.pairingLeft;
    final mm = left.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = left.inSeconds.remainder(60).toString().padLeft(2, '0');

    final statusPill = live
        ? const NeuPill('LINK LIVE ✓', color: Neu.good)
        : (s.pairingOpen
            ? NeuPill('WAITING · $mm:$ss', color: Neu.warn)
            : const NeuPill('NOT PAIRED', color: Neu.inkSoft));

    return ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 14), children: [
      NeuCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('PAIRING CODE',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: Neu.inkSoft)),
            const Spacer(),
            statusPill,
          ]),
          const SizedBox(height: 14),
          Center(
            child: GestureDetector(
              onTap: s.pairCode.isEmpty ? null : _copyCode,
              child: NeuInset(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Text(
                  s.pairCode.isEmpty ? '· · · · · ·' : _spaced(s.pairCode),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: s.pairCode.isEmpty ? 22 : 34,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: s.pairCode.isEmpty ? Neu.inkSoft : Neu.ink,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              live
                  ? 'Connected to Orubus.ai — just talk on the Chat tab.'
                  : (s.pairingOpen
                      ? 'Paste this code in your chat with Orubus.ai.\nThe link snaps live the moment he claims it.'
                      : 'Generate a code, then paste it in your chat\nwith Orubus.ai — takes two seconds.'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, height: 1.5, color: Neu.inkSoft),
            ),
          ),
          const SizedBox(height: 14),
          NeuButton(
            label: live
                ? 'GENERATE NEW CODE'
                : (s.pairingOpen ? 'REGENERATE CODE' : 'GENERATE PAIRING CODE'),
            icon: Icons.pin,
            fill: Neu.accent,
            onTap: _busy ? null : _generate,
          ),
          if (s.pairCode.isNotEmpty && !live) ...[
            const SizedBox(height: 10),
            NeuButton(
              label: 'COPY CODE',
              icon: Icons.copy,
              small: true,
              onTap: _copyCode,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            live
                ? 'The pairing binds this device to the operator until you generate a new code.'
                : 'Codes expire after 15 minutes and work exactly once.',
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
            const Text('ADVANCED — RELAY ENDPOINT',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: Neu.inkSoft)),
            const SizedBox(width: 6),
            Icon(_advanced ? Icons.expand_less : Icons.expand_more,
                size: 16, color: Neu.inkSoft),
          ]),
        ),
      ),
      if (_advanced)
        NeuCard(
          child: Column(children: [
            _field(_relay, 'relay base URL'),
            _field(_key, 'access key', mono: true),
            _field(_ntfy, 'legacy ntfy base (unused in relay mode)'),
            const SizedBox(height: 6),
            NeuButton(label: 'SAVE', icon: Icons.save, small: true, onTap: _saveAdvanced),
          ]),
        ),
    ]);
  }

  String _spaced(String code) => code.split('').join(' ');

  Widget _field(TextEditingController c, String label, {String? hint, bool mono = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: NeuInset(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: TextField(
            controller: c,
            style: TextStyle(
                fontSize: 13,
                color: Neu.ink,
                fontFamily: mono ? 'monospace' : null),
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
