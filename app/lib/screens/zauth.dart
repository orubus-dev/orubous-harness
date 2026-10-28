import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../bridge/link.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Z.ai login — an embedded WebView on chat.z.ai.
///
/// The user signs in interactively (captcha, password, SSO — whatever the
/// site asks). While the page runs, we poll localStorage for the session
/// token the site stores after login (Open WebUI-style: `token` JWT) and
/// capture it silently. From then on the free-chat transport talks to
/// chat.z.ai natively with that Bearer token — no relay, no pairing.
///
/// The WebView doubles as a guaranteed-working chat fallback: you can type
/// right here even if the native wire ever drifts.
class ZAuthScreen extends StatefulWidget {
  final Store store;
  const ZAuthScreen({super.key, required this.store});

  @override
  State<ZAuthScreen> createState() => _ZAuthScreenState();
}

class _ZAuthScreenState extends State<ZAuthScreen> {
  late final WebViewController _wc;
  Timer? _poll;
  bool _captured = false;
  bool _ready = false;
  String _status = 'loading chat.z.ai…';

  @override
  void initState() {
    super.initState();
    _wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (!mounted) return;
          setState(() => _ready = true);
          _sniff();
        },
      ))
      ..loadRequest(Uri.parse('https://chat.z.ai/'));
    _poll = Timer.periodic(const Duration(milliseconds: 1800), (_) => _sniff());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  String _clean(Object? v) =>
      v.toString().replaceAll("'", '').replaceAll('"', '').trim();

  /// Poll localStorage for the login token; capture once, then stop.
  Future<void> _sniff() async {
    if (_captured || !mounted) return;
    try {
      final tok = await _wc.runJavaScriptReturningResult(
          "(() => { try { return localStorage.getItem('token') || ''; } "
          'catch (e) { return \'\'; } })()');
      final t = _clean(tok);
      if (t.length < 20 || !t.startsWith('ey')) return; // not a JWT yet

      String who = '';
      try {
        final u = await _wc.runJavaScriptReturningResult(
            "(() => { try { const u = JSON.parse(localStorage.getItem('user') "
            "|| '{}'); return u.name || u.email || ''; } catch (e) { "
            "return ''; } })()");
        who = _clean(u);
      } catch (_) {}

      _captured = true;
      _poll?.cancel();
      final s = widget.store;
      s.zToken = t;
      if (who.isNotEmpty) s.zUser = who;
      await s.save();
      Link.i.autoLog('z.ai session captured${who.isEmpty ? '' : ' — $who'}');
      if (!mounted) return;
      setState(() => _status = 'session captured ✓ — free chat is live');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(who.isEmpty
              ? 'z.ai session captured — free chat enabled'
              : 'z.ai session captured — signed in as $who'),
          duration: const Duration(seconds: 3)));
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // page not ready / JS bridge busy — the timer comes back
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSession = widget.store.zToken.isNotEmpty;
    return Scaffold(
      backgroundColor: Neu.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 14, 6),
            child: Row(children: [
              NeuIconBtn(Icons.arrow_back, onTap: () => Navigator.pop(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Z.AI LOGIN',
                          style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                              color: Neu.ink)),
                      Text(
                        _captured
                            ? _status
                            : (hasSession
                                ? 'session active — re-login to refresh'
                                : _status),
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: _captured
                                ? Neu.good
                                : (hasSession ? Neu.good : Neu.inkSoft)),
                      ),
                    ]),
              ),
              if (_ready && !_captured)
                const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Neu.accentDeep)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Text(
              'Sign in on the page below. The moment login lands, the session '
              'is captured automatically — then Chat (z.ai free transport) '
              'talks to chat.z.ai natively. You can also chat right here.',
              style: TextStyle(fontSize: 11, height: 1.4, color: Neu.inkSoft),
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.white,
                boxShadow: const [
                  BoxShadow(
                      color: Neu.shadowDark,
                      offset: Offset(3, 3),
                      blurRadius: 8),
                  BoxShadow(
                      color: Neu.shadowLight,
                      offset: Offset(-3, -3),
                      blurRadius: 8),
                ],
              ),
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              clipBehavior: Clip.antiAlias,
              child: WebViewWidget(controller: _wc),
            ),
          ),
        ]),
      ),
    );
  }
}
