import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../bridge/link.dart';
import '../bridge/modules.dart';
import '../store.dart';
import '../widgets/neu.dart';

/// Direct chat with the operator (Orubus.ai) — relay-first v2.
/// ＋ icon attaches images/videos/files (≤900KB, images auto-compressed).
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
  bool _uploading = false;

  static const maxAttachBytes = 900 * 1024;

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
    if ((text.isEmpty && !_uploading) || _busy) return;
    if (text.isEmpty) return;
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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  /// ＋ icon: pick → size-guard → compress images → upload via relay.
  Future<void> _pickAttachment() async {
    if (_uploading || _busy) return;
    try {
      final res = await FilePicker.platform
          .pickFiles(withData: false, type: FileType.any);
      final file = res?.files.single;
      if (file == null) return;
      final name = file.name;
      final mime = _mimeFor(name);
      List<int> bytes;

      if (mime.startsWith('image/') && !mime.contains('gif')) {
        // compress images to fit the wire (photos are 2-6MB straight from camera)
        final src = File(file.path!);
        if (!src.existsSync()) return _snack('file vanished before upload');
        final raw = src.readAsBytesSync();
        List<int> out = raw;
        if (raw.length > maxAttachBytes) {
          out = await FlutterImageCompress.compressWithList(
            Uint8List.fromList(raw),
            minWidth: 1280,
            minHeight: 1280,
            quality: 72,
          );
        }
        if (out.length > maxAttachBytes) {
          out = await FlutterImageCompress.compressWithList(
            Uint8List.fromList(out),
            minWidth: 900,
            minHeight: 900,
            quality: 60,
          );
        }
        if (out.length > maxAttachBytes) {
          return _snack('image still too large after compression');
        }
        bytes = out;
      } else {
        final size = file.size;
        if (size > maxAttachBytes) {
          return _snack('too large — 900KB max for now (videos included)');
        }
        final f = File(file.path!);
        if (!f.existsSync()) return _snack('file vanished before upload');
        bytes = f.readAsBytesSync();
      }

      setState(() => _uploading = true);
      final url = await Link.i.engine?.sendAttachment(name, mime, bytes);
      await Link.i.markAttachmentUploaded(name, url);
      setState(() => _uploading = false);
      if (url == null) {
        _snack('upload failed — check the Bridge log');
      } else {
        _snack('attachment delivered ✓');
      }
      _scrollDown();
    } catch (e) {
      setState(() => _uploading = false);
      _snack('picker error: ${e.runtimeType}');
    }
  }

  String _mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
      'mp4': 'video/mp4', 'mov': 'video/quicktime', 'webm': 'video/webm',
      'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'ogg': 'audio/ogg',
      'm4a': 'audio/mp4', 'pdf': 'application/pdf',
      'txt': 'text/plain', 'md': 'text/plain', 'json': 'application/json',
      'zip': 'application/zip',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    final online = Link.i.online;
    final relayUp = Link.i.relayUp && online;
    // True wire-level states: relayUp means polls return 200 (authenticated
    // + live) — not just "process running". This is the pill that must say
    // CONNECTED only when chatting actually works.
    final statusColor = !online
        ? Neu.inkSoft
        : (relayUp ? Neu.good : Neu.warn);
    final statusText = !online
        ? 'OFFLINE — toggle Go online in the three-dot menu'
        : (relayUp
            ? 'CONNECTED · live chat active'
            : 'CONNECTING… reaching the relay');
    final statusWeight = relayUp ? FontWeight.w800 : FontWeight.w600;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: relayUp
                    ? [BoxShadow(color: Neu.good.withOpacity(0.6), blurRadius: 5)]
                    : null),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(statusText,
                style: TextStyle(
                    fontSize: 11.5,
                    color: relayUp ? Neu.good : Neu.inkSoft,
                    fontWeight: statusWeight,
                    letterSpacing: relayUp ? 0.3 : 0)),
          ),
          if (_uploading)
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Neu.accentDeep)),
        ]),
      ),
      Expanded(child: _messagesArea(context)),
      _modelBar(),
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
          'the same brain you talk to on Discord.\n\n'
          '1) Pairing screen → generate your code\n'
          '2) Paste the 6 digits in your chat\n'
          '3) Come back here and just talk.\n\n'
          'Use ＋ to attach images, videos and files.',
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
            if (m.hasAttachment) _attachmentView(m, isUser),
            if (m.text.isNotEmpty && (m.text != '📎 ${m.attName}' || !m.hasAttachment))
              Padding(
                padding: EdgeInsets.only(top: m.hasAttachment ? 6 : 0),
                child: SelectableText(m.text,
                    style: const TextStyle(
                        fontSize: 14, height: 1.35, color: Neu.ink)),
              ),
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

  Widget _attachmentView(ChatMsg m, bool isUser) {
    final url = m.attUrl;
    if (m.attIsImage && url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
          child: Image.network(url,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, prog) => prog == null
                  ? child
                  : const Padding(
                      padding: EdgeInsets.all(18),
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Neu.accentDeep))),
              errorBuilder: (_, __, ___) => _fileChip(m, isUser)),
        ),
      );
    }
    return _fileChip(m, isUser);
  }

  Widget _fileChip(ChatMsg m, bool isUser) {
    final sizeKb = m.attSize == null ? '' : ' · ${(m.attSize! / 1024).round()}KB';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isUser ? Colors.white.withOpacity(0.25) : Neu.well,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_iconForAtt(m.attMime),
            size: 18, color: isUser ? Neu.ink : Neu.accentDeep),
        const SizedBox(width: 8),
        Flexible(
          child: Text('${m.attName ?? 'file'}$sizeKb',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Neu.ink)),
        ),
      ]),
    );
  }

  IconData _iconForAtt(String? mime) {
    if (mime == null) return Icons.insert_drive_file_rounded;
    if (mime.startsWith('image/')) return Icons.image_rounded;
    if (mime.startsWith('video/')) return Icons.videocam_rounded;
    if (mime.startsWith('audio/')) return Icons.headphones_rounded;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_rounded;
    return Icons.insert_drive_file_rounded;
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _modelBar() {
    // Model chips: hot-updatable via the updates system (model_map module).
    // Falls back to the built-in set when no module is installed.
    final models = Modules.modelLabels();
    final current = widget.store.model;
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
        children: [
          for (final m in models)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () async {
                  widget.store.model = m;
                  await widget.store.save();
                  if (mounted) setState(() {});
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(children: [
        Expanded(
          child: NeuInset(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: Row(children: [
              NeuIconBtn(
                Icons.add_rounded,
                size: 36,
                iconColor: Neu.accentDeep,
                onTap: _uploading ? null : _pickAttachment,
              ),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(fontSize: 14, color: Neu.ink),
                  decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'message Orubus.ai…',
                      hintStyle: TextStyle(color: Neu.inkSoft, fontSize: 13.5),
                      border: InputBorder.none),
                ),
              ),
            ]),
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
