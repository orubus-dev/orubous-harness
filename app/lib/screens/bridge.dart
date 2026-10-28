import 'package:flutter/material.dart';

import '../bridge/engine.dart';
import '../bridge/handlers.dart';
import '../store.dart';

class BridgeScreen extends StatefulWidget {
  final Store store;
  final String workspace;
  const BridgeScreen({super.key, required this.store, required this.workspace});

  @override
  State<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreen> {
  BridgeEngine? _engine;
  final List<BridgeEvent> _log = [];
  final _scroll = ScrollController();

  bool get _connected => _engine?.running ?? false;

  void _log(BridgeEvent e) {
    if (!mounted) return;
    setState(() => _log.add(e));
    if (_log.length > 400) _log.removeRange(0, _log.length - 400);
    Timer(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _toggle() async {
    if (_connected) {
      await _engine!.stop();
      setState(() {});
      return;
    }
    final s = widget.store;
    if (!s.hasIdentity) {
      _log(BridgeEvent('no identity — generate one in Settings', isError: true));
      return;
    }
    _engine = BridgeEngine(
      baseUrl: s.ntfyBase,
      topic: s.topic,
      token: s.token,
      mode: s.mode,
      ops: PlatformOps(workspace: widget.workspace, mode: s.mode),
      log: _log,
    );
    await _engine!.start();
    setState(() {});
  }

  @override
  void dispose() {
    _engine?.stop();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bridge'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(_connected ? Icons.sensors : Icons.sensors_off,
                  size: 18,
                  color: _connected ? Colors.greenAccent : Colors.grey),
              label: Text(_connected ? 'ONLINE' : 'offline',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text('identity',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('mode: ${s.mode}',
                      style: TextStyle(
                          fontSize: 11,
                          color: s.mode == 'safe'
                              ? Colors.greenAccent
                              : Colors.orangeAccent)),
                ]),
                const SizedBox(height: 6),
                SelectableText('topic  ${s.topic}',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
                SelectableText(
                    'token  ${s.token.isEmpty ? '' : '${s.token.substring(0, 8)}…${s.token.substring(s.token.length - 4)}'}',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
                Text('workspace  ${widget.workspace}',
                    style: TextStyle(
                        fontSize: 10, color: Colors.grey.shade500)),
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
            label: Text(_connected ? 'Disconnect' : 'Connect to relay'),
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
            child: _log.isEmpty
                ? Center(
                    child: Text(
                      'Press Connect — then the operator can reach this device.\n'
                      'Every task and result is logged here. Nothing is hidden.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _log.length,
                    itemBuilder: (_, i) {
                      final e = _log[i];
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
