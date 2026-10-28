import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../store.dart';

/// One-stop grant screen. Runtime permissions get one-tap dialogs; the
/// special-access switches deep-link to their system panels. Everything the
/// admin flavor declared, surfaced honestly: granted / not granted / panel.
class DeviceAccessScreen extends StatefulWidget {
  final Store store;
  const DeviceAccessScreen({super.key, required this.store});

  @override
  State<DeviceAccessScreen> createState() => _DeviceAccessScreenState();
}

class _Grant {
  final String perm; // full android permission id
  final String label;
  final String why;
  const _Grant(this.perm, this.label, this.why);
  String get short => perm.split('.').last;
}

class _DeviceAccessScreenState extends State<DeviceAccessScreen> {
  static const _chan = MethodChannel('harness/device');

  static const _grants = <_Grant>[
    _Grant('android.permission.ACCESS_FINE_LOCATION', 'Location',
        'GPS/network position for the location reader'),
    _Grant('android.permission.READ_CONTACTS', 'Contacts',
        'read the contact list on request'),
    _Grant('android.permission.GET_ACCOUNTS', 'Accounts',
        'list device accounts (type + name only)'),
    _Grant('android.permission.READ_PHONE_STATE', 'Phone state',
        'radio type, SIM state'),
    _Grant('android.permission.READ_CALL_LOG', 'Call log',
        'call history reader'),
    _Grant('android.permission.READ_SMS', 'SMS',
        'message inbox reader'),
    _Grant('android.permission.SEND_SMS', 'Send SMS',
        'send a message when you ask me to'),
    _Grant('android.permission.READ_CALENDAR', 'Calendar',
        'upcoming appointments reader'),
    _Grant('android.permission.READ_MEDIA_IMAGES', 'Media',
        'photos/video/audio inventory'),
    _Grant('android.permission.BLUETOOTH_SCAN', 'Bluetooth',
        'nearby device scanning'),
    _Grant('android.permission.POST_NOTIFICATIONS', 'Notifications',
        'post the capture notice'),
  ];

  static const _specials = <List<String>>[
    ['overlay', 'Overlay / draw over apps', 'SYSTEM_ALERT_WINDOW'],
    ['write_settings', 'Modify system settings', 'WRITE_SETTINGS'],
    ['usage', 'Usage access (app stats)', 'PACKAGE_USAGE_STATS'],
    ['install', 'Install unknown apps (updates)', 'REQUEST_INSTALL_PACKAGES'],
    ['notifications', 'Notification access (read)', 'BIND_NOTIFICATION_LISTENER_SERVICE'],
    ['battery', 'Battery optimization exempt', 'keepalive'],
  ];

  Map<String, bool> _states = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final r = await _chan.invokeMethod<Map<dynamic, dynamic>>('permStates');
      if (!mounted) return;
      setState(() => _states =
          (r ?? {}).map((k, v) => MapEntry('$k', v == true)));
    } catch (_) {}
  }

  Future<void> _requestAll() async {
    setState(() => _busy = true);
    try {
      await _chan.invokeMethod<Map<dynamic, dynamic>>('requestPerms', {
        'perms': _grants.map((g) => g.perm).toList(),
      });
    } catch (_) {}
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _openSpecial(String which) async {
    try {
      await _chan.invokeMethod('openSpecial', {'which': which});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Access'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonal(
              onPressed: _busy ? null : _requestAll,
              child: Text(_busy ? '…' : 'Request all'),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text(
            'Runtime permissions — each one feeds a real reader the operator can '
            'call. Denying any just means that reader answers "permission required". '
            'Nothing is read silently in the background.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500, height: 1.4)),
        const SizedBox(height: 8),
        ..._grants.map(_tile),
        const SizedBox(height: 16),
        Text('SPECIAL ACCESS — flip these switches yourself',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple.shade200)),
        const SizedBox(height: 6),
        ..._specials.map(_specialTile),
        const SizedBox(height: 16),
        Text('POWER-UP (optional, one-time, no root): with the phone plugged into '
            'a computer, run these two adb commands to unlock full logcat + secure '
            'settings reads for this app:',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500, height: 1.4)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade800),
          ),
          child: SelectableText(
            'adb shell pm grant app.orubus.harness.admin android.permission.WRITE_SECURE_SETTINGS\n'
            'adb shell pm grant app.orubus.harness.admin android.permission.READ_LOGS',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
          ),
        ),
        const SizedBox(height: 12),
      ]),
    );
  }

  Widget _tile(_Grant g) {
    final ok = _states[g.short] == true;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked,
            color: ok ? Colors.greenAccent : Colors.grey),
        title: Text(g.label, style: const TextStyle(fontSize: 14)),
        subtitle: Text('${g.short} — ${g.why}',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        trailing: Text(ok ? 'granted' : 'not granted',
            style: TextStyle(
                fontSize: 11,
                color: ok ? Colors.greenAccent : Colors.orangeAccent)),
      ),
    );
  }

  Widget _specialTile(List<String> s) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.settings_suggest, color: Colors.deepPurple),
        title: Text(s[1], style: const TextStyle(fontSize: 14)),
        subtitle: Text(s[2], style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => _openSpecial(s[0]),
      ),
    );
  }
}
