import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
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
  bool _sendingFile = false;

  static const _models = ['GLM-4.7', 'GLM-4.6', 'Fast'];

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

  /// ＋ icon — attach an image, video, or file. Content rides inline (base64,
  /// ≤ ~2.5MB after encoding); the relay mirrors bigger things to GitHub later.
  Future<void> _attach() async {
    if (_sendingFile) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Neu.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Neu.radius))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.image_outlined, color: Neu.accentDeep),
              title: const Text('Photo or video'),
              onTap: () => Navigator.pop(context, 'media')),
          ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined,
                  color: Neu.accentDeep),
              title: const Text('Any file'),
              onTap: () => Navigator.pop(context, 'file')),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _sendingFile = true);
    try {
      FileType ft = choice == 'media' ? FileType.media : FileType.any;
      final picked = await FilePicker.platform.pickFiles(type: ft, withData: true);
      final f = picked?.files.single;
      if (f == null || !mounted) return;
      final bytes = f.bytes;
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('could not read file'), duration: Duration(seconds: 2)));
        return;
      }
      if (bytes.length > 2_500_000) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('too large — keep files under ~2.5MB for now'),
            backgroundColor: Neu.bad,
            duration: Duration(seconds: 3)));
        return;
      }
      final mime = f.extension?.toLowerCase() ?? '';
      final att = {
        'name': f.name,
        'mime': _mimeFor(mime),
        'size': bytes.length,
        'b64': base64Encode(bytes),
      };
      await Link.i.sendChat(f.name, attachment: att);
      _scrollDown();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('attach failed: $e'), duration: const Duration(seconds: 3)));
    } finally {
      if (mounted) setState(() => _sendingFile = false);
    }
  }

  String _mimeFor(String ext) {
    const map = {
      'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
      'gif': 'image/gif', 'webp': 'image/webp', 'mp4': 'video/mp4',
      'mov': 'video/quicktime', 'webm': 'video/webm', 'pdf': 'application/pdf',
      'txt': 'text/plain', 'json': 'application/json', 'zip': 'application/zip',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  void _pickModel(String m) async {
    widget.store.model = m;
    await widget.store.save();
    Link.i.model = m;
    setState(() {});
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
            ? 'relay link live — messages deliver instantly'
            : 'online — paste your 6-digit code to Orubus to connect');

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
      _modelBar(),
      _composer(),
    ]);
  }

  Widget _modelBar() {
    final current = widget.store.model;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final m in _models)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _pickModel(m),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: m == current ? Neu.accent : Neu.surface,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: m == current
                        ? [
                            BoxShadow(
                                color: Neu.accentDeep.withOpacity(0.4),
                                offset: const Offset(2, 2),
                                blurRadius: 5),
                          ]
                        : const [
                            BoxShadow(
                                color: Neu.shadowDark,
                                offset: Offset(2, 2),
                                blurRadius: 4),
                            BoxShadow(
                                color: Neu.shadowLight,
                                offset: Offset(-2, -2),
                                blurRadius: 4),
                          ],
                  ),
                  child: Text(m,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: m == current ? Colors.white : Neu.inkSoft)),
                ),
              ),
            ),
        ],
      ),
    );
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
          'the same brain you talk to on Discord, no keys.\n\n'
          '1) Pairing screen → generate your 6-digit code\n'
          '2) Paste the code to him in your chat\n'
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
            if (m.hasAttachment) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isUser
                      ? Colors.white.withOpacity(0.25)
                      : Neu.well,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(isUser ? Icons.attach_file : Icons.attach_file,
                      size: 14,
                      color: isUser ? Colors.white : Neu.accentDeep),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(m.attName!,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isUser ? Colors.white : Neu.ink)),
                  ),
                ]),
              ),
            ],
            if (m.text.isNotEmpty)
              SelectableText(m.text,
                  style: const TextStyle(
                      fontSize: 14, height: 1.35, color: Neu.ink)),
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
        NeuIconBtn(
          _sendingFile ? Icons.hourglass_top : Icons.add,
          iconColor: Neu.accentDeep,
          onTap: _sendingFile ? null : _attach,
        ),
        const SizedBox(width: 8),
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
