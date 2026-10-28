import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/link.dart';
import '../store.dart';
import '../version.dart';
import '../widgets/neu.dart';
import 'auth.dart';
import 'bridge.dart';
import 'chat.dart';
import 'device_access.dart';
import 'pairing.dart';
import 'settings.dart';

/// App shell — skeuomorphic top bar:
///   hamburger (top-left)  -> drawer with every screen
///   three dots (top-right)-> popup: online toggle, copy token, clear chat
class HarnessShell extends StatefulWidget {
  final Store store;
  const HarnessShell({super.key, required this.store});

  @override
  State<HarnessShell> createState() => _HarnessShellState();
}

class _HarnessShellState extends State<HarnessShell> {
  int _page = 0; // 0 chat · 1 bridge · 2 pairing · 3 auth · 4 settings
  StreamSubscription<void>? _stateSub;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _stateSub = Link.i.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  void _goto(int i) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => _page = i);
  }

  Future<void> _toggle() async {
    await Link.i.toggleWith(widget.store,
        (t, {error = false}) => Link.i.autoLog(t, error: error));
    if (mounted) setState(() {});
  }

  void _copyToken() {
    final code = widget.store.pairCode;
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('no active code — open Pairing and generate one'),
          duration: Duration(seconds: 2)));
      return;
    }
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('pairing code copied — paste it to Orubus.ai'),
        duration: Duration(seconds: 2)));
  }

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Neu.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(Neu.radius)),
        title: const Text('Clear chat history'),
        content: const Text(
            'Removes every message from this device (file + backup mirror). '
            'The operator side keeps its own copy.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Neu.bad),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await Link.i.clearChats();
      if (mounted) setState(() {});
    }
  }

  String get _statusLabel {
    if (!Link.i.online) return 'OFFLINE';
    return Link.i.paired ? 'PAIRED · LIVE' : 'ONLINE · WAITING';
  }

  Color get _statusColor {
    if (!Link.i.online) return Neu.inkSoft;
    return Link.i.paired ? Neu.good : Neu.warn;
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatScreen(store: widget.store),
      BridgeScreen(store: widget.store),
      PairingScreen(store: widget.store),
      AuthScreen(store: widget.store),
      SettingsScreen(store: widget.store),
    ];
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Neu.bg,
      drawer: _drawer(context),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _header(context),
          Expanded(
            child: IndexedStack(index: _page, children: pages),
          ),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Row(children: [
        NeuIconBtn(Icons.menu, onTap: () => _scaffoldKey.currentState?.openDrawer()),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('ORUBUS HARNESS',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: Neu.ink)),
            const SizedBox(height: 1),
            Row(children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: _statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(_statusLabel,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: _statusColor)),
            ]),
          ]),
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'toggle') _toggle();
            if (v == 'copy') _copyToken();
            if (v == 'clear') _clearChat();
          },
          color: Neu.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Neu.radius)),
          icon: const Icon(Icons.more_vert, color: Neu.ink),
          itemBuilder: (_) => [
            PopupMenuItem(
                value: 'toggle',
                child: Row(children: [
                  Icon(Link.i.online ? Icons.link_off : Icons.link,
                      size: 19, color: Neu.ink),
                  const SizedBox(width: 10),
                  Text(Link.i.online ? 'Go offline' : 'Go online'),
                ])),
            PopupMenuItem(
                value: 'copy',
                child: Row(children: [
                  Icon(Icons.copy, size: 19, color: Neu.ink),
                  const SizedBox(width: 10),
                  const Text('Copy pairing string'),
                ])),
            PopupMenuItem(
                value: 'clear',
                child: Row(children: [
                  Icon(Icons.delete_sweep_outlined, size: 19, color: Neu.bad),
                  const SizedBox(width: 10),
                  const Text('Clear chat history'),
                ])),
          ],
        ),
      ]),
    );
  }

  Widget _drawer(BuildContext context) {
    Widget item(IconData ic, String label, int target) {
      final selected = _page == target;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Material(
          color: selected ? Neu.accent.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _goto(target),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(children: [
                Icon(ic,
                    size: 20,
                    color: selected ? Neu.accentDeep : Neu.inkSoft),
                const SizedBox(width: 12),
                Text(label,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? Neu.accentDeep : Neu.ink)),
              ]),
            ),
          ),
        ),
      );
    }

    final s = widget.store;
    return Drawer(
      backgroundColor: Neu.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(24))),
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              20, MediaQuery.of(context).padding.top + 18, 20, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Neu.accent,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                        color: Neu.shadowDark,
                        offset: Offset(4, 4),
                        blurRadius: 9),
                    BoxShadow(
                        color: Neu.shadowLight,
                        offset: Offset(-4, -4),
                        blurRadius: 9),
                  ],
                ),
                child: const Icon(Icons.cable, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Orubous Harness',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Neu.ink)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              s.hasIdentity
                  ? 'device ${s.deviceId.length > 12 ? s.deviceId.substring(0, 12) : s.deviceId}…'
                  : 'no identity yet',
              style: const TextStyle(fontSize: 11, color: Neu.inkSoft),
            ),
            Text('v$kAppVersion · ${s.mode} mode',
                style: const TextStyle(fontSize: 11, color: Neu.inkSoft)),
          ]),
        ),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            item(Icons.chat_bubble_outline, 'Chat', 0),
            item(Icons.settings_remote, 'Bridge', 1),
            item(Icons.vpn_key_outlined, 'Pairing', 2),
            item(Icons.verified_user_outlined, 'Authentication', 3),
            item(Icons.tune, 'Settings', 4),
            const Divider(height: 22, color: Color(0x33A9B6C9)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            DeviceAccessScreen(store: widget.store)));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 13),
                    child: const Row(children: [
                      Icon(Icons.admin_panel_settings_outlined,
                          size: 20, color: Neu.inkSoft),
                      SizedBox(width: 12),
                      Text('Device Access (permissions)',
                          style: TextStyle(fontSize: 14, color: Neu.ink)),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('the direct line — no API, no middleman',
              style: TextStyle(fontSize: 10.5, color: Neu.inkSoft)),
        ),
      ]),
    );
  }
}
