import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/link.dart';
import '../bridge/engine.dart';
import '../bridge/handlers.dart';
import '../store.dart';
import 'device_access.dart';

class BridgeScreen extends StatefulWidget {
  final Store store;
  final String workspace;
  const BridgeScreen({super.key, required this.store, required this.workspace});

  @override
  State<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreen> {
  final List<BridgeEvent> _events = [];
  final _scroll = ScrollController();
  StreamSubscription<void>? _stateSub;
  Timer? _ticker;

  bool get _connected => Link.i.online;

  @override
  void initState() {
    super.initState();
    Link.i.workspace = widget.workspace;
    _stateSub = Link.i.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    // 1-second ticker so the pairing countdown breathes.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _log(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() => _events.add(BridgeEvent(text, isError: error)));
    if (_events.length > 400) _events.removeRange(0, _events.length - 400);
    Timer(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _toggle() async {
    if (_connected) {
      await Link.i.disconnect();
      setState(() {});
      return;
    }
    final s = widget.store;
    if (!s.hasIdentity) {
      _log('no identity — tap Generate Connectivity Token first', error: true);
      return;
    }
    _log('connecting to relay…');
    await Link.i.connect(
      ntfyBase: s.ntfyBase,
      topic: s.topic,
      token: s.token,
      mode: s.mode,
      log: _log,
    );
    setState(() {});
  }

  Future<void> _generateToken() async {
    final s = widget.store;
    s.generateIdentity();
    Link.i.paired = false;
    await s.save();
    _log('new connectivity token generated — valid 30 min for pairing');
    setState(() {});
  }

  void _copyPairing() {
    Clipboard.setData(ClipboardData(text: widget.store.pasteString));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('pairing string copied — paste it to Orubus.ai'),
        duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final left = s.pairingLeft;
    final mm = left.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = left.inSeconds.remainder(60).toString().padLeft(2, '0');
    final paired = Link.i.paired;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bridge'),
        actions: [
          IconButton(
            tooltip: 'Device Access (permissions)',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DeviceAccessScreen(store: s))),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(_connected ? Icons.sensors : Icons.sensors_off,
                  size: 18,
                  color: _connected
                      ? (paired ? Colors.greenAccent : Colors.orangeAccent)
                      : Colors.grey),
              label: Text(
                  _connected ? (paired ? 'PAIRED' : 'WAITING') : 'offline',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ---- connectivity token card ------------------------------------
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          color: Colors.deepPurple.shade900.withOpacity(0.35),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text('CONNECTIVITY TOKEN',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (s.hasIdentity)
                    Text(
                        paired
                            ? 'paired ✓'
                            : (s.pairingOpen
                                ? 'pairing window  $mm:$ss'
                                : 'window closed — regenerate'),
                        style: TextStyle(
                            fontSize: 11,
                            color: paired
                                ? Colors.greenAccent
                                : (s.pairingOpen
                                    ? Colors.orangeAccent
                                    : Colors.redAccent))),
                ]),
                const SizedBox(height: 8),
                if (!s.hasIdentity)
                  const Text(
                      'No token yet. Generate one, paste it to Orubus.ai in your chat with him — he connects back.',
                      style: TextStyle(fontSize: 12.5, height: 1.4))
                else ...[
                  SelectableText(s.pasteString,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12.5)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _copyPairing,
                        icon: const Icon(Icons.copy, size: 17),
                        label: const Text('Copy pairing string'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: 'regenerate (kills old channel)',
                      onPressed: _generateToken,
                      icon: const Icon(Icons.refresh),
                    ),
                  ]),
                ],
                if (!s.hasIdentity) ...[
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _generateToken,
                    icon: const Icon(Icons.key),
                    label: const Text('Generate Connectivity Token'),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: FilledButton.icon(
            onPressed: _toggle,
            style: FilledButton.styleFrom(
                backgroundColor:
                    _connected ? Colors.red.shade800 : Colors.deepPurple),
            icon: Icon(_connected ? Icons.link_off : Icons.link),
            label: Text(_connected ? 'Go Offline' : 'Go Online'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('activity',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade800),
            ),
            child: _events.isEmpty
                ? Center(
                    child: Text(
                      'Generate a token → paste it to Orubus.ai → Go Online.\n'
                      'Then he is inside this device: chat, code, files,\n'
                      'screen, logs — everything lands in this log.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _events.length,
                    itemBuilder: (_, i) {
                      final e = _events[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(e.text,
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: e.isError
                                    ? Colors.orangeAccent
                                    : Colors.grey.shade300)),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}
