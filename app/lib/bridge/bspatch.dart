import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Pure-Dart bspatch — applies a bsdiff-generated binary patch.
/// Lets the app rebuild a new APK from the installed one + a small delta
/// file (module-level updates without re-downloading the whole app).
///
/// Patch layout (BSDIFF40): 8-byte magic, then three big-endian int64
/// lengths (control, diff, newsize), then three consecutive bzip2 streams.
/// Control stream: 8-byte BE signed triples (add, seek, adjust).
Uint8List bspatch(Uint8List oldData, Uint8List patch) {
  if (patch.length < 32) throw const FormatException('patch too short');
  final head = ByteData.sublistView(patch, 0, 32);
  final magic = String.fromCharCodes(patch.sublist(0, 8));
  if (magic != 'BSDIFF40') throw const FormatException('bad magic: $magic');
  final ctrlLen = head.getInt64(8, Endian.big);
  final diffLen = head.getInt64(16, Endian.big);
  final newSize = head.getInt64(24, Endian.big);
  if (ctrlLen < 0 || diffLen < 0 || newSize < 0 || newSize > (1 << 30)) {
    throw const FormatException('bad patch header');
  }
  if (patch.length < 32 + ctrlLen + diffLen) {
    throw const FormatException('patch truncated');
  }

  final ctrl = _bzip2(patch.sublist(32, 32 + ctrlLen));
  final diff = _bzip2(patch.sublist(32 + ctrlLen, 32 + ctrlLen + diffLen));
  final extra = _bzip2(patch.sublist(32 + ctrlLen + diffLen));

  final newData = Uint8List(newSize);
  var oldPos = 0, newPos = 0, diffPos = 0, extraPos = 0, ctrlPos = 0;

  int i64(Uint8List b, int o) {
    final bd = ByteData.sublistView(b, o, o + 8);
    return bd.getInt64(0, Endian.big);
  }

  while (newPos < newSize) {
    if (ctrlPos + 24 > ctrl.length) throw const FormatException('control overrun');
    final add = i64(ctrl, ctrlPos);
    final seek = i64(ctrl, ctrlPos + 8);
    final adjust = i64(ctrl, ctrlPos + 16);
    ctrlPos += 24;

    final addN = add.toInt();
    if (addN < 0 || newPos + addN > newSize || diffPos + addN > diff.length) {
      throw const FormatException('diff overrun');
    }
    // diff bytes adjust the old bytes
    for (var i = 0; i < addN; i++) {
      final oldByte = (oldPos + i) < oldData.length ? oldData[oldPos + i] : 0;
      newData[newPos + i] = (oldByte + diff[diffPos + i]) & 0xff;
    }
    newPos += addN;
    diffPos += addN;
    oldPos += addN;

    final seekN = seek.toInt();
    if (seekN < 0 || newPos + seekN > newSize || extraPos + seekN > extra.length) {
      throw const FormatException('extra overrun');
    }
    // extra bytes copy verbatim
    newData.setRange(newPos, newPos + seekN, extra, extraPos);
    newPos += seekN;
    extraPos += seekN;
    oldPos += adjust.toInt();
  }
  return newData;
}

Uint8List _bzip2(List<int> raw) {
  final decoder = BZip2Decoder();
  final out = decoder.decodeBytes(Uint8List.fromList(raw));
  return out;
}
