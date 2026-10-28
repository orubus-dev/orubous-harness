import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../store.dart';

const _sysPrompt =
    'You are Orubus, the AI operator inside the user\'s Orubous Harness app. '
    'Be concise, technical, brutally honest. You can also operate this device '
    'through the Bridge tab when a bridge identity is connected.';

class ChatScreen extends StatefulWidget {
  final Store store;
  const ChatScreen({super.key, required this.store});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    _ctrl.clear();
    setState(() {
      _msgs.add(_Msg('user', text));
      _busy = true;
    });
    _scrollDown();

    final base = widget.store.aiBase.replaceAll(RegExp(r'/+$'), '');
    final history = [
      {'role': 'system', 'content': _sysPrompt},
      ..._msgs.where((m) => m.kind == 'user' || m.kind == 'ai').map((m) =>
          {'role': m.kind == 'user' ? 'user' : 'assistant', 'content': m.text}),
    ].toList();
    if (history.length > 25) {
      history.removeRange(1, history.length - 24);
    }

    try {
      final r = await http
          .post(Uri.parse('$base/chat/completions'),
              headers: {
                'Content-Type': 'application/json',
                if (widget.store.aiKey.isNotEmpty)
                  'Authorization': 'Bearer ${widget.store.aiKey}',
              },
              body: jsonEncode({
                'model': widget.store.aiModel,
                'messages': history,
                'stream': false,
              }))
          .timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) {
        throw 'HTTP ${r.statusCode}: ${r.body.substring(0, r.body.length > 300 ? 300 : r.body.length)}';
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      final content =
          ((choices?.isNotEmpty ?? false) ? choices![0]['message']['content'] : null)
              ?.toString() ??
          '(empty response)';
      setState(() => _msgs.add(_Msg('ai', content)));
    } catch (e) {
      setState(() => _msgs.add(_Msg('err', 'chat failed: $e')));
    } finally {
      setState(() => _busy = false);
      _scrollDown();
    }
  }

  void _scrollDown() {
    Timer(const Duration(milliseconds: 100), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat — GLM')),
      body: Column(children: [
        Expanded(
          child: _msgs.isEmpty
              ? Center(
                  child: Text(
                    'Direct line to GLM.\nSet your endpoint + API key in Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _msgs.length,
                  itemBuilder: (_, i) {
                    final m = _msgs[i];
                    final isUser = m.kind == 'user';
                    final isErr = m.kind == 'err';
                    return Align(
                      alignment: isUser
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.85),
                        decoration: BoxDecoration(
                          color: isErr
                              ? Colors.red.shade900.withOpacity(0.4)
                              : isUser
                                  ? Colors.deepPurple.shade700
                                  : Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(m.text),
                      ),
                    );
                  },
                ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                      hintText: 'message…', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                  onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Msg {
  final String kind; // user | ai | err
  final String text;
  _Msg(this.kind, this.text);
}
