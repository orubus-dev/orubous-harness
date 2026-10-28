import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/link.dart';
import '../bridge/modules.dart';
import '../bridge/updater.dart';
import '../store.dart';
import '../version.dart';
import '../widgets/neu.dart';
import 'zauth.dart';

class SettingsScreen extends StatefulWidget {
  final Store store;
  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _mode = 'safe';
  bool _autoLaunch = false;
  String _transport = 'relay';

  @override
  void initState() {
    super.initState();
    _mode = widget.store.mode;
    _autoLaunch = widget.store.wasOnline;
    _transport = widget.store.chatMode == 'zai' ? 'zai' : 'relay';
  }

  Future<void> _save({bool? autoLaunch, String? transport}) async {
    final s = widget.store;
    s.mode = _mode;
    if (autoLaunch != null) {
      s.wasOnline = autoLaunch;
      _autoLaunch = autoLaunch;
    }
    if (transport != null) {
      s.chatMode = transport;
      _transport = transport;
      Link.i.syncWith(s);
    }
    await s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('saved'), duration: Duration(seconds: 1)));
  }

  Future<void> _openZAuth() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ZAuthScreen(store: widget.store)));
    if (!mounted) return;
    setState(() {}); // token may have changed while the WebView was up
  }

  /// Delta update flow: relay manifest → hot-apply modules → offer the
  /// binary release (delta patch or full APK) if one targets this build.
  Future<void> _checkUpdates() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('checking the relay for updates…'),
        duration: Duration(seconds: 1)));
    try {
      final up = Updater(
          relayBase: widget.store.relayBase,
          key: widget.store.bridgeKey);
      final m = await up.check();

      // 1) config modules — apply silently, they ARE the delta hotfix layer
      final applied = await up.applyModules(m.modules);
      if (mounted && applied.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('modules updated: ${applied.join(", ")}'),
            duration: const Duration(seconds: 3)));
      }

      // 2) binary release
      final rel = m.release;
      final newer = rel != null && rel.code > Updater.kAppCode;
      final wrongBase = rel != null && rel.isDelta && rel.baseCode != Updater.kAppCode;
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: Neu.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Neu.radius)),
          title: Text(newer ? 'Update to ${rel!.version}' : 'Up to date'),
          content: Text(newer
              ? (wrongBase
                  ? 'v${rel!.version} needs a different base — install it as a full APK.'
                  : 'v${rel!.version} (${rel!.isDelta ? "delta patch — KBs, not the whole app" : "full APK"})\n\n${rel!.notes}')
              : 'Installed: v$kAppVersion\nModules checked: ${m.modules.length}\nThis IS the latest.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
            if (newer)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Neu.accentDeep),
                onPressed: () async {
                  Navigator.pop(context);
                  await _installRelease(up, rel!);
                },
                child: const Text('Update now'),
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

  Future<void> _installRelease(Updater up, ReleaseEntry rel) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('fetching update…'),
        duration: Duration(seconds: 2)));
    try {
      final path = await up.prepareRelease(rel);
      final ok = await up.install(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? 'installer opened — confirm to finish'
              : 'installer blocked — allow "install unknown apps" for Orubus Harness (Pairing → advanced)'),
          duration: const Duration(seconds: 5)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('update failed: $e'),
          duration: const Duration(seconds: 4)));
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
          const NeuSection('chat transport'),
          DropdownButtonFormField<String>(
            value: _transport,
            dropdownColor: Neu.surface,
            decoration: const InputDecoration(
                labelText: 'transport',
                labelStyle: TextStyle(fontSize: 12, color: Neu.inkSoft),
                border: InputBorder.none),
            items: const [
              DropdownMenuItem(
                  value: 'relay',
                  child: Text('relay — the paired operator line')),
              DropdownMenuItem(
                  value: 'zai',
                  child: Text('z.ai free — chat.z.ai direct, no pairing')),
            ],
            onChanged: (v) => _save(transport: v ?? 'relay'),
          ),
          const SizedBox(height: 8),
          Text(
            _transport == 'zai'
                ? (widget.store.zToken.isEmpty
                    ? 'no z.ai session yet — sign in below, then chat.'
                    : 'session: ${widget.store.zUser.isEmpty ? "captured ✓" : widget.store.zUser} — model: ${widget.store.zModel}')
                : 'the direct line to Orubus.ai — needs pairing.',
            style: TextStyle(
                fontSize: 11.5,
                color: (_transport == 'zai' && widget.store.zToken.isNotEmpty)
                    ? Neu.good
                    : Neu.inkSoft),
          ),
          const SizedBox(height: 10),
          NeuButton(
              label: 'Z.AI LOGIN',
              icon: Icons.travel_explore,
              small: true,
              fill: Neu.accent,
              onTap: _openZAuth),
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
