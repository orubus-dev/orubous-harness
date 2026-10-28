import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/engine.dart';
import '../bridge/link.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Bridge — the heart of the harness: connection state + activity log.
/// Token generation lives on the Pairing screen; the ⋮ menu can toggle too.
class BridgeScreen extends StatefulWidget {
  final Store store;
  const BridgeScreen({super.key, required this.store});

  @override
  State<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreen> {
  final List<BridgeEvent> _events = [];
  final _scroll = ScrollController();
  StreamSubscription<void>? _stateSub;
  Timer? _ticker;
  bool _busy = false;

  bool get _connected => Link.i.online;

  @override
  void initState() {
    super.initState();
    _events.addAll(Link.i.autoEvents);
    _stateSub = Link.i.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
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
    if (_busy) return;
    setState(() => _busy = true);
    await Link.i.toggleWith(widget.store, _log);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  String get _statusWord {
    if (!_connected) return 'OFFLINE';
    return Link.i.paired ? 'PAIRED — LIVE' : 'ONLINE — WAITING';
  }

  Color get _statusColor {
    if (!_connected) return Neu.inkSoft;
    return Link.i.paired ? Neu.good : Neu.warn;
  }

  String get _statusSub {
    if (!_connected) {
      return 'The link to Orubus.ai is down. Press the button — the app resumes by itself after closes.';
    }
    if (Link.i.paired) {
      return 'Foreground service is holding the line. Background, lock screen, app switch — the bridge stays up.';
    }
    return 'Subscribed to your private relay topic. Waiting for the first sign from the operator…';
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 14), children: [
          NeuCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: _statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(_statusWord,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: _statusColor)),
              ]),
              const SizedBox(height: 8),
              Text(_statusSub,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.45, color: Neu.inkSoft)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: NeuButton(
                    label: _connected ? 'GO OFFLINE' : 'GO ONLINE',
                    icon: _connected ? Icons.link_off : Icons.link,
                    fill: _connected ? Colors.white : Neu.accent,
                    textColor: _connected ? Neu.bad : Neu.ink,
                    onTap: _busy ? null : _toggle,
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 14),
          const NeuSection('activity'),
          NeuInset(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.42,
              child: _events.isEmpty
                  ? Center(
                      child: Text(
                        'Generate a token → paste it to Orubus.ai → Go Online.\n'
                        'Then he is inside this device: chat, code, files,\n'
                        'screen, logs — everything lands in this log.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Neu.inkSoft, fontSize: 12, height: 1.5),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: _events.length,
                      itemBuilder: (_, i) {
                        final e = _events[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Text(e.text,
                              style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  height: 1.35,
                                  color: e.isError
                                      ? Neu.warn
                                      : Neu.ink.withOpacity(0.75))),
                        );
                      },
                    ),
            ),
          ),
        ]),
      ),
    ]);
  }
}
