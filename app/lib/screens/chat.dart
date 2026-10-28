import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/link.dart';
import '../store.dart';

/// Direct chat with the operator (Orubus.ai) — NO API, NO KEY CONFIG.
/// Messages ride the same bridge channel as operator tasks: you write here,
/// it lands in the operator's inbox; their replies appear here.
class ChatScreen extends StatefulWidget {
  final Store store;
  const ChatScreen({super.key, required this.store});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<ChatMsg>? _sub;
  StreamSubscription<void>? _stateSub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sub = Link.i.chatStream.listen((_) {
      if (!mounted) return;
      setState(() {});
      _scrollDown();
    });
    _stateSub = Link.i.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _stateSub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    _ctrl.clear();
    setState(() => _busy = true);
    await Link.i.sendChat(text);
    if (!mounted) return;
    setState(() => _busy = false);
    _scrollDown();
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
    final online = Link.i.online;
    final paired = Link.i.paired;
    return Scaffold(
      appBar: AppBar(title: const Text('Orubus.ai — direct line')),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: online
              ? (paired ? Colors.green.shade900.withOpacity(0.35) : Colors.orange.shade900.withOpacity(0.30))
              : Colors.grey.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            online
                ? (paired
                    ? 'connected to operator — messages deliver instantly'
                    : 'online — waiting for operator to connect…')
                : 'offline — open the Bridge tab and press Go Online',
            style: TextStyle(
                fontSize: 11.5,
                color: online
                    ? (paired ? Colors.greenAccent : Colors.orangeAccent)
                    : Colors.grey.shade500),
          ),
        ),
        Expanded(
          child: Link.i.chats.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      'This is a direct line to Orubus.ai —\n'
                      'the same brain you talk to on Discord, no API keys.\n\n'
                      '1) Bridge tab → Generate Connectivity Token\n'
                      '2) Paste the pairing string in your chat with him\n'
                      '3) Come back here and just talk.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 13,
                          height: 1.5),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: Link.i.chats.length,
                  itemBuilder: (_, i) {
                    final m = Link.i.chats[i];
                    final isUser = m.from == 'me';
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
                          color: isUser
                              ? Colors.deepPurple.shade700
                              : Colors.grey.shade800,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(12),
                            topRight: const Radius.circular(12),
                            bottomLeft: Radius.circular(isUser ? 12 : 2),
                            bottomRight: Radius.circular(isUser ? 2 : 12),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(m.text),
                            SizedBox(height: 4),
                            Text(
                                '${m.at.hour.toString().padLeft(2, '0')}:${m.at.minute.toString().padLeft(2, '0')}',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.white.withOpacity(0.4))),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
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
                      hintText: 'message Orubus.ai…',
                      border: OutlineInputBorder()),
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
