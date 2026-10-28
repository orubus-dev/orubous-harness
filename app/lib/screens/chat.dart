import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/link.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Direct chat with the operator (Orubus.ai) — NO API, NO KEY CONFIG.
/// Messages ride the same bridge channel as operator tasks: you write here,
/// it lands in the operator's inbox; their replies appear here.
/// History persists across restarts (file + mirror store).
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
    final statusColor = online ? (paired ? Neu.good : Neu.warn) : Neu.inkSoft;
    final statusText = !online
        ? 'offline — toggle Go online in the three-dot menu'
        : (paired
            ? 'connected to operator — messages deliver instantly'
            : 'online — waiting for operator to connect…');

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
        child: Row(children: [
          Container(
            width: 7,
            height: 7,
            decoration:
                BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(statusText,
                style: const TextStyle(fontSize: 11.5, color: Neu.inkSoft)),
          ),
        ]),
      ),
      Expanded(child: _messagesArea(context)),
      _composer(),
    ]);
  }

  Widget _messagesArea(BuildContext context) {
    if (Link.i.chats.isEmpty) return _emptyState();
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      itemCount: Link.i.chats.length,
      itemBuilder: (_, i) => _bubble(context, Link.i.chats[i]),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          'This is a direct line to Orubus.ai —\n'
          'the same brain you talk to on Discord, no API keys.\n\n'
          '1) Pairing screen → generate / copy your token\n'
          '2) Paste it to him in your chat\n'
          '3) Come back here and just talk.',
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Neu.inkSoft, fontSize: 13, height: 1.5),
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, ChatMsg m) {
    final isUser = m.from == 'me';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: isUser ? Neu.accent : Neu.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
          boxShadow: isUser
              ? [
                  BoxShadow(
                      color: Neu.accentDeep.withOpacity(0.35),
                      offset: const Offset(3, 3),
                      blurRadius: 8),
                ]
              : const [
                  BoxShadow(
                      color: Neu.shadowDark,
                      offset: Offset(3, 3),
                      blurRadius: 7),
                  BoxShadow(
                      color: Neu.shadowLight,
                      offset: Offset(-3, -3),
                      blurRadius: 7),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(m.text,
                style: const TextStyle(fontSize: 14, height: 1.35, color: Neu.ink)),
            const SizedBox(height: 3),
            Text(_clock(m.at),
                style: TextStyle(
                    fontSize: 9,
                    color: isUser ? Neu.ink.withOpacity(0.45) : Neu.inkSoft)),
          ],
        ),
      ),
    );
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(children: [
        Expanded(
          child: NeuInset(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: TextField(
              controller: _ctrl,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: const TextStyle(fontSize: 14, color: Neu.ink),
              decoration: const InputDecoration(
                  hintText: 'message Orubus.ai…',
                  hintStyle: TextStyle(color: Neu.inkSoft, fontSize: 13.5),
                  border: InputBorder.none),
            ),
          ),
        ),
        const SizedBox(width: 10),
        NeuIconBtn(
          Icons.send_rounded,
          iconColor: Neu.accentDeep,
          onTap: _busy ? null : _send,
        ),
      ]),
    );
  }
}
