import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Platform task handlers (protocol v1). Safe mode = guardrails, not a jail.
class PlatformOps {
  final String workspace;
  final String mode;
  PlatformOps({required this.workspace, required this.mode});

  static const _chan = MethodChannel('harness/device');
  static const maxOut = 200000;
  static const defaultTmo = 60;
  static const maxTmo = 600;

  static const List<String> _blocked = [
    r'\bsudo\b', r'\bdoas\b', r'\bsu\s+-', r'\bshutdown\b', r'\breboot\b',
    r'\bpoweroff\b', r'\bmkfs\b', r'\bdd\s+if=', r'\bchown\b', r'\bpasswd\b',
    r'\bcrontab\b', r'\bssh\b', r'\bscp\b', r'\bncat?\b', r'\bnc\s+-e\b',
    r'rm\s+-rf\s+/(\s|$)', r'rm\s+-fr\s+/(\s|$)', r':\(\)\{.*\};:',
    r'curl[^|]*\|\s*(ba)?sh', r'wget[^|]*\|\s*(ba)?sh', r'\|\s*(ba)?sh\b',
    r'\bhistory\s+-c\b',
  ];

  List<String> guard(String cmd) {
    if (mode != 'safe') return const [];
    return _blocked.where((p) => RegExp(p).hasMatch(cmd)).toList();
  }

  /// Normalize a path lexically (no filesystem access, works for not-yet-existing files).
  static String _norm(String path) {
    final prefix = Platform.isWindows
        ? (path.length >= 3 && path[1] == ':' ? path.substring(0, 3) : path)
        : Platform.pathSeparator;
    final rest = path.substring(prefix.length);
    final out = <String>[];
    for (final s in rest.split(Platform.pathSeparator)) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(s);
    }
    return prefix + out.join(Platform.pathSeparator);
  }

  /// Resolve a protocol path strictly inside the workspace.
  String resolve(String p) {
    final rel = p.trim().isEmpty ? '.' : p.trim();
    final isAbs = rel.startsWith(Platform.pathSeparator) ||
        (Platform.isWindows && rel.length > 2 && rel[1] == ':');
    final raw = isAbs ? rel : '$workspace${Platform.pathSeparator}$rel';
    final abs = _norm(raw);
    final root = _norm(workspace);
    if (abs != root && !abs.startsWith('$root${Platform.pathSeparator}')) {
      throw const FileSystemException('path escapes workspace');
    }
    return abs;
  }

  Future<Map<String, dynamic>> dispatch(String kind, Map<String, dynamic> task,
      Map<String, Map<int, String>> putBuf) async {
    switch (kind) {
      case 'run':
        return _run((task['cmd'] ?? '').toString(), _tmo(task, defaultTmo));
      case 'py':
        return _py((task['code'] ?? '').toString(), _tmo(task, defaultTmo));
      case 'ls':
        return _ls((task['path'] ?? '.').toString());
      case 'get':
        return _get((task['path'] ?? '').toString());
      case 'put':
        return _put(task, putBuf);
      case 'status':
        return status(0);
      case 'screenshot':
        return _screenshot();
      case 'device':
        return _device();
      case 'skills':
        return _skills();
      case 'skill_install':
        return _skillInstall(task, putBuf);
      case 'grant':
        return _grant(task);
      case 'special':
        return _special(task);
      case 'openurl':
        return _openUrl(task);
      case 'location':
      case 'contacts':
      case 'calls':
      case 'sms':
      case 'send_sms':
      case 'apps':
      case 'calendar':
      case 'net':
      case 'wifi':
      case 'clipboard':
      case 'accounts':
      case 'notifications':
        return _deviceRead(kind, task);
      default:
        return {'ok': false, 'out': 'unknown kind: $kind'};
    }
  }

  // ---- skills (Claude-style SKILL.md packs) --------------------------------
  String get _skillsDir =>
      '$workspace${Platform.pathSeparator}skills';

  Future<Map<String, dynamic>> _skills() async {
    final root = Directory(_skillsDir);
    if (!root.existsSync()) {
      return {'ok': true, 'out': '(no skills installed)'};
    }
    final rows = <String>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final name = d.path.split(Platform.pathSeparator).last;
      final skill = File(
          '${d.path}${Platform.pathSeparator}SKILL.md');
      final nFiles = d.listSync(recursive: true).length;
      var desc = '(no SKILL.md)';
      if (skill.existsSync()) {
        desc = skill.readAsLinesSync().take(3).join(' ');
        if (desc.length > 90) desc = desc.substring(0, 90);
      }
      rows.add('$name  files=$nFiles  desc="$desc"');
    }
    return {'ok': true, 'out': rows.isEmpty ? '(no skills installed)' : rows.join('\n')};
  }

  Future<Map<String, dynamic>> _skillInstall(Map<String, dynamic> task,
      Map<String, Map<int, String>> buf) async {
    var skill = ((task['skill'] ?? '') as String).trim();
    skill = skill.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (skill.isEmpty) return {'ok': false, 'out': 'skill_install: missing skill name'};
    final name =
        ((task['name'] ?? '') as String).split(Platform.pathSeparator).last;
    if (name.isEmpty) return {'ok': false, 'out': 'skill_install: missing file name'};
    final key = '${task['task_id'] ?? ''}:$skill:$name';
    final parts = buf.putIfAbsent(key, () => {});
    parts[((task['part'] ?? 1) as num).toInt()] = (task['data'] ?? '') as String;
    final of = ((task['of'] ?? 1) as num).toInt();
    if (of > parts.length) {
      return {'ok': true, 'out': 'chunk ${parts.length}/$of'};
    }
    buf.remove(key);
    final raw = base64.decode(parts.values.join());
    if (task['sha256'] != null && sha256Hex(raw) != task['sha256']) {
      return {'ok': false, 'out': 'sha256 MISMATCH — skill transfer corrupted'};
    }
    final dir = Directory('$_skillsDir${Platform.pathSeparator}$skill');
    dir.createSync(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    f.writeAsBytesSync(raw);
    return {'ok': true, 'out': 'skill "$skill": wrote ${f.path} (${raw.length} bytes)'};
  }

  // ---- permissions / device reads -----------------------------------------
  Future<Map<String, dynamic>> _grant(Map<String, dynamic> task) async {
    final perms = ((task['perms'] ?? []) as List).map((e) => e.toString()).toList();
    if (Platform.isAndroid) {
      try {
        final r = await _chan
            .invokeMethod<Map<dynamic, dynamic>>('requestPerms', {'perms': perms});
        return {'ok': true, 'out': (r ?? {}).map((k, v) => MapEntry('$k', '$v')).entries
            .map((e) => '${e.key}=${e.value}').join('\n')};
      } on PlatformException catch (e) {
        return {'ok': false, 'out': 'grant failed: ${e.code} ${e.message}'};
      }
    }
    return {'ok': true, 'out': 'desktop build: permissions are OS-level, nothing to request'};
  }

  Future<Map<String, dynamic>> _special(Map<String, dynamic> task) async {
    final which = (task['which'] ?? '').toString();
    if (Platform.isAndroid) {
      try {
        final r = await _chan.invokeMethod<bool>('openSpecial', {'which': which});
        return {'ok': r == true, 'out': r == true ? 'opened $which panel' : 'unknown panel: $which'};
      } on PlatformException catch (e) {
        return {'ok': false, 'out': 'special failed: ${e.code} ${e.message}'};
      }
    }
    return {'ok': true, 'out': 'desktop build: no special-access panels'};
  }

  Future<Map<String, dynamic>> _openUrl(Map<String, dynamic> task) async {
    final url = (task['url'] ?? '').toString();
    if (url.isEmpty) return {'ok': false, 'out': 'openurl: missing url'};
    if (Platform.isAndroid) {
      try {
        await _chan.invokeMethod('openUrl', {'url': url});
        return {'ok': true, 'out': 'opened: $url'};
      } on PlatformException catch (e) {
        return {'ok': false, 'out': 'openUrl failed: ${e.code} ${e.message}'};
      }
    }
    return _run('Start-Process "$url"', 15);
  }

  Future<Map<String, dynamic>> _deviceRead(String kind, Map<String, dynamic> task) async {
    if (Platform.isAndroid) {
      final method = kind == 'send_sms' ? 'sendSms' : kind;
      final args = <String, dynamic>{
        if (kind == 'send_sms') ...{'to': task['to'] ?? '', 'body': task['body'] ?? ''},
      };
      try {
        final r = await _chan.invokeMethod<Map<dynamic, dynamic>>(method, args);
        return {'ok': r?['ok'] == true, 'out': (r?['out'] ?? '').toString()};
      } on PlatformException catch (e) {
        return {'ok': false, 'out': '$kind failed: ${e.code} ${e.message}'};
      }
    }
    // Windows fallbacks for the few that make sense on desktop.
    switch (kind) {
      case 'net':
        return _run('Get-NetAdapter | Format-Table -AutoSize; Get-NetIPAddress -AddressFamily IPv4 '
            '| Format-Table InterfaceAlias,IPAddress -AutoSize', 30);
      case 'clipboard':
        return _run('Get-Clipboard', 15);
      case 'apps':
        return _run('Get-ItemProperty HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*,'
            'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\* '
            '| Select-Object DisplayName,DisplayVersion | Format-Table -AutoSize', 60);
      default:
        return {'ok': false, 'out': '$kind is a mobile reader — not available on this platform'};
    }
  }

  int _tmo(Map<String, dynamic> task, int def) =>
      ((task['timeout'] ?? def) as num).clamp(1, maxTmo).toInt();

  // ---- process execution with real timeout+kill ---------------------------
  Future<Map<String, dynamic>> _exec(List<String> cmd, String cwd, int tmo) async {
    Process p;
    try {
      p = await Process.start(cmd.first, cmd.sublist(1), workingDirectory: cwd);
    } catch (e) {
      return {'ok': false, 'rc': null, 'out': 'spawn failed: $e'};
    }
    final killTimer = Timer(Duration(seconds: tmo), () {
      try {
        p.kill();
      } catch (_) {}
    });
    try {
      final parts = await Future.wait<dynamic>([
        p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
        p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join(),
        p.exitCode,
      ]).timeout(Duration(seconds: tmo + 10));
      killTimer.cancel();
      var s = '${parts[0]}${parts[1]}';
      if (s.length > maxOut) s = '${s.substring(0, maxOut)}\n...[truncated]';
      return {'ok': parts[2] == 0, 'rc': parts[2], 'out': s};
    } on TimeoutException {
      killTimer.cancel();
      try {
        p.kill();
      } catch (_) {}
      return {'ok': false, 'rc': null, 'out': 'TIMEOUT after ${tmo}s'};
    }
  }

  Future<Map<String, dynamic>> _run(String cmd, int tmo) async {
    final v = guard(cmd);
    if (v.isNotEmpty) {
      return {
        'ok': false,
        'rc': null,
        'out': 'REFUSED (safe mode): blocked pattern: ${v.join("; ")}'
      };
    }
    if (cmd.trim().isEmpty) return {'ok': false, 'rc': null, 'out': 'empty command'};
    final isWin = Platform.isWindows;
    return _exec(
        isWin
            ? ['powershell.exe', '-NoProfile', '-Command', cmd]
            : ['sh', '-c', cmd],
        workspace,
        tmo);
  }

  Future<Map<String, dynamic>> _py(String code, int tmo) async {
    final exe = Platform.isWindows ? 'python' : 'python3';
    return _exec([exe, '-c', code], workspace, tmo);
  }

  // ---- files ---------------------------------------------------------------
  Future<Map<String, dynamic>> _ls(String path) async {
    final d = Directory(resolve(path));
    if (!d.existsSync()) return {'ok': false, 'out': 'not a dir: $path'};
    final rows = <String>[];
    final entries = d.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries.take(200)) {
      final t = e.statSync();
      rows.add('${e is Directory ? 'd' : '-'} ${t.size.toString().padLeft(10)}  '
          '${e.path.split(Platform.pathSeparator).last}');
    }
    return {'ok': true, 'out': rows.isEmpty ? '(empty)' : rows.join('\n')};
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final f = File(resolve(path));
    if (!f.existsSync()) return {'ok': false, 'out': 'not found: $path'};
    final st = f.statSync();
    if (st.size > 8 * 1024 * 1024) {
      return {'ok': false, 'out': 'file too big for bridge: ${st.size}B (8MB cap)'};
    }
    final data = f.readAsBytesSync();
    return {
      'ok': true,
      'name': f.path.split(Platform.pathSeparator).last,
      'size': st.size,
      'sha256': sha256Hex(data),
      'b64': base64.encode(data),
    };
  }

  Future<Map<String, dynamic>> _put(
      Map<String, dynamic> task, Map<String, Map<int, String>> buf) async {
    final name =
        ((task['name'] ?? '') as String).split(Platform.pathSeparator).last;
    if (name.isEmpty) return {'ok': false, 'out': 'put: missing file name'};
    final key = '${task['task_id'] ?? ''}:$name';
    final parts = buf.putIfAbsent(key, () => {});
    parts[((task['part'] ?? 1) as num).toInt()] = (task['data'] ?? '') as String;
    final of = ((task['of'] ?? 1) as num).toInt();
    if (of > parts.length) {
      return {'ok': true, 'out': 'chunk ${parts.length}/$of'};
    }
    buf.remove(key);
    final raw = base64.decode(parts.values.join());
    if (task['sha256'] != null && sha256Hex(raw) != task['sha256']) {
      return {'ok': false, 'out': 'sha256 MISMATCH — transfer corrupted'};
    }
    final f = File(resolve(name));
    f.writeAsBytesSync(raw);
    return {'ok': true, 'out': 'wrote ${f.path} (${raw.length} bytes)'};
  }

  // ---- platform specifics --------------------------------------------------
  Future<Map<String, dynamic>> _screenshot() async {
    if (Platform.isAndroid) {
      try {
        final path = await _chan.invokeMethod<String>('takeScreenshot');
        if (path == null) return {'ok': false, 'out': 'screenshot: null path'};
        return _get(path);
      } on PlatformException catch (e) {
        return {'ok': false, 'out': 'screenshot failed: ${e.code} ${e.message}'};
      }
    }
    if (Platform.isWindows) {
      final shotDir = Directory('$workspace${Platform.pathSeparator}screenshots');
      shotDir.createSync(recursive: true);
      final out = '${shotDir.path}${Platform.pathSeparator}'
          'shot_${DateTime.now().millisecondsSinceEpoch}.png';
      final ps = '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
\$b = New-Object System.Drawing.Bitmap([System.Windows.Forms.SystemInformation]::VirtualScreen.Width, [System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
\$g = [System.Drawing.Graphics]::FromImage(\$b)
\$g.CopyFromScreen(0, 0, 0, 0, \$b.Size)
\$b.Save("$out", [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output "$out"
''';
      final script =
          File('${Directory.systemTemp.path}${Platform.pathSeparator}harness_shot.ps1');
      script.writeAsStringSync(ps);
      final r = await _exec([
        'powershell.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path
      ], workspace, 60);
      if (r['ok'] != true || !File(out).existsSync()) {
        return {'ok': false, 'out': 'screenshot failed: ${r['out']}'};
      }
      return _get(out);
    }
    return {'ok': false, 'out': 'screenshot unsupported on ${Platform.operatingSystem}'};
  }

  Future<Map<String, dynamic>> _device() async {
    if (Platform.isAndroid) {
      try {
        final m = await _chan.invokeMethod<Map<dynamic, dynamic>>('deviceInfo');
        return {
          'ok': true,
          'out': (m ?? {})
              .map((k, v) => MapEntry('$k', '$v'))
              .entries
              .map((e) => '${e.key}=${e.value}')
              .join('\n'),
        };
      } on PlatformException catch (e) {
        return {'ok': false, 'out': 'deviceInfo failed: ${e.code}'};
      }
    }
    return _run(
        'Get-CimInstance Win32_OperatingSystem | '
        'Select-Object Caption,LastBootUpTime,TotalVisibleMemorySize,FreePhysicalMemory | Format-List; '
        '"CPU=\$env:NUMBER_OF_PROCESSORS"; "USER=\$env:USERNAME"; "HOST=\$env:COMPUTERNAME"',
        90);
  }

  Map<String, dynamic> status(int upSec) => {
        'ok': true,
        'out': 'harness v1.0 | mode=$mode | up=${upSec}s | '
            'platform=${Platform.operatingSystem} ${Platform.operatingSystemVersion.split(' ').first} | '
            'host=${Platform.localHostname} | work=$workspace',
      };

  static String sha256Hex(List<int> data) => _Sha256().hex(data);
}

/// Minimal SHA-256 (FIPS 180-4). Avoids adding the crypto package dependency.
class _Sha256 {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  String hex(List<int> data) {
    var h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
      0x1f83d9ab, 0x5be0cd19
    ];
    final bitLen = data.length * 8;
    final msg = List<int>.from(data)..add(0x80);
    while (msg.length % 64 != 56) {
      msg.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      msg.add((bitLen >> (i * 8)) & 0xff);
    }
    final w = List<int>.filled(64, 0);
    for (var off = 0; off < msg.length; off += 64) {
      for (var t = 0; t < 16; t++) {
        w[t] = (msg[off + t * 4] << 24) |
            (msg[off + t * 4 + 1] << 16) |
            (msg[off + t * 4 + 2] << 8) |
            msg[off + t * 4 + 3];
      }
      for (var t = 16; t < 64; t++) {
        final s0 =
            _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ ((w[t - 15] >>> 3) & 0x1fffffff);
        final s1 =
            _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ ((w[t - 2] >>> 10) & 0x3fffff);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var t = 0; t < 64; t++) {
        final S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (hh + S1 + ch + _k[t] + w[t]) & 0xffffffff;
        final S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (S0 + maj) & 0xffffffff;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }
      h = [
        (h[0] + a) & 0xffffffff, (h[1] + b) & 0xffffffff,
        (h[2] + c) & 0xffffffff, (h[3] + d) & 0xffffffff,
        (h[4] + e) & 0xffffffff, (h[5] + f) & 0xffffffff,
        (h[6] + g) & 0xffffffff, (h[7] + hh) & 0xffffffff,
      ];
    }
    return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
}
