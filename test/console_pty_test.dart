@Tags(['pty'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('pty (K1, K6, K10)', () {
    test('K1: the live line fits the width and clears to end of line',
        () async {
      final term = await _ptyBar(cols: 40);
      // Every redraw ends with erase-to-end-of-line.
      expect(term, contains('\x1b[K'));
      // A long label is cut with …: no redraw exceeds 40 cells.
      expect(term, contains('…'));
      for (final chunk in term.split('\r')) {
        final line = chunk.split('\x1b[').first;
        expect(
          _cells(line),
          lessThanOrEqualTo(40),
          reason: 'redraw too wide: $line',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a bar on an 8-column terminal never fills the last column', () async {
      final term = await _ptyBar(cols: 8);
      for (final chunk in term.split('\r')) {
        expect(_cells(chunk.split('\x1b[').first), lessThanOrEqualTo(7), reason: chunk);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('LC_ALL=C gets ASCII glyphs; NO_COLOR keeps the motion', () async {
      final ascii = await _ptyBar(cols: 40, mode: 'spin', env: {'LC_ALL': 'C'});
      expect(ascii, contains('+ working'));
      expect(ascii, isNot(contains('⠋')));
      final plain = await _ptyBar(cols: 40, mode: 'spin', env: {'NO_COLOR': '1'});
      expect(plain, contains('⠋'));
      expect(plain, isNot(contains('\x1b[3')));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('no accent by default: bar, spinner and choose emit no colour codes; accent restores it',
        () async {
      if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
      final root = Directory.current;
      Future<String> run(String mode, {bool accent = false}) async {
        final res = await Process.run('python3', [
          '${root.path}/test/console_pty/drive.py',
          '--size', '24', '80',
          if (mode == 'choose') ...['--ready', 'blue', '--feed', '1.0', r'\x0d'],
          '--', if (accent) ...['env', 'PROBE_ACCENT=1'],
          Platform.resolvedExecutable,
          '${root.path}/test/console_pty/probe.dart',
          '${Directory.systemTemp.path}/probe_nosuch.log', mode,
        ], workingDirectory: root.path, stdoutEncoding: null);
        return utf8.decode(res.stdout as List<int>, allowMalformed: true);
      }

      final colour = RegExp(r'\x1b\[([0-9;]*)m');
      bool hasColour(String s) => colour.allMatches(s).any((m) => m
          .group(1)!
          .split(';')
          .map((p) => int.tryParse(p) ?? 0)
          .any((n) => (n >= 30 && n <= 37) || (n >= 90 && n <= 97) || n == 38 || n == 48));
      for (final mode in ['bar', 'spin', 'choose']) {
        final out = await run(mode);
        expect(out, isNotEmpty, reason: mode);
        expect(hasColour(out), isFalse, reason: mode);
      }
      expect(await run('bar', accent: true), contains('38;5;173'));
      expect(await run('choose', accent: true), contains('38;5;173'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('H15: an unclosed bar does not keep the process alive', () async {
      if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
      final root = Directory.current;
      final res = await Process.run('python3', [
        '${root.path}/test/console_pty/drive.py',
        '--size', '24', '80', '--ready', 'ready-leak',
        '--', Platform.resolvedExecutable,
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log', 'leak',
      ], workingDirectory: root.path);
      expect(res.stderr, isNot(contains('did not exit')));
      expect(res.stderr, contains('exit=0'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('K6: interactive choose takes arrows+enter, escape gives or',
        () async {
      final pick = await _ptyChoose(feeds: const [
        (1.5, r'\x1b[B'),
        (2.0, r'\x0d'),
      ]);
      expect(pick, 'pick=green');
      final esc = await _ptyChoose(feeds: const [(1.5, r'\x1b')]);
      expect(esc, 'pick=red');
      // Two keys in one read are two presses.
      final burst = await _ptyChoose(feeds: const [(1.5, r'\x1b[B\x1b[B'), (2.0, r'\x0d')]);
      expect(burst, 'pick=blue');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('piped choose reads a number; ask reads a line', () async {
      final root = Directory.current;
      final probe = '${root.path}/test/console_pty/probe.dart';
      final log = File(
        '${Directory.systemTemp.path}/console-pty-${DateTime.now().microsecondsSinceEpoch}.log',
      );
      Future<String> run(List<String> args, String stdin) async {
        final proc = await Process.start(
          Platform.resolvedExecutable,
          [probe, log.path, ...args],
          workingDirectory: root.path,
        );
        proc.stdin.write(stdin);
        await proc.stdin.close();
        final code = await proc.exitCode.timeout(
          const Duration(seconds: 60),
        );
        expect(code, 0);
        return log.readAsString();
      }

      expect(await run(['choose'], '2\n'), contains('pick=green'));
      expect(await run(['ask'], 'hello\n'), contains('answer=hello'));
      expect(await run(['secret'], 's3cret\n'), contains('secret=s3cret'));
      // H16: CRLF is one line break, also across two prompts.
      expect(await run(['ask2'], 'x\r\ny\r\n'), contains('answer=x|y'));
      // A closed stdin gives each prompt its `or` (null without one, confirm false).
      expect(await run(['eof'], ''), contains('eof=null|dflt|true|false|null|y'));
      // An empty line gives `or`; without one the answer is empty.
      expect(await run(['empty'], '\n\n\n'), contains('empty=dflt||true'));
      try {
        await log.delete();
      } catch (_) {}
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('K3: SIGINT during a prompt exits 130 with the terminal restored',
        () async {
      if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
      final root = Directory.current;
      try {
        final py = await Process.run('python3', ['--version']);
        if (py.exitCode != 0) markTestSkipped('needs python3');
      } catch (_) {
        markTestSkipped('needs python3 for the pty driver');
      }
      final out = File(
        '${Directory.systemTemp.path}/console-sigint-${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      final res = await Process.run('python3', [
        '${root.path}/test/console_pty/sigint_drive.py',
        out.path,
        '6.0',
        '--',
        Platform.resolvedExecutable,
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'secret',
      ], workingDirectory: root.path);
      expect(res.stdout, contains('EXIT=exit=130'));
      try {
        await out.delete();
      } catch (_) {}
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

/// Display cells in a raw terminal line (escapes add none).
int _cells(String line) {
  var w = 0;
  final runes = line.runes.toList();
  var i = 0;
  while (i < runes.length) {
    if (runes[i] == 0x1b) {
      // Skip an escape sequence (to its final byte).
      i++;
      while (i < runes.length &&
          !(runes[i] >= 0x40 && runes[i] <= 0x7e)) {
        i++;
      }
      i++;
      continue;
    }
    w++;
    i++;
  }
  return w;
}

/// Run the bar probe under a 40-column pty; return the terminal bytes.
Future<String> _ptyBar({required int cols, String mode = 'bar', Map<String, String>? env}) async {
  if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
  final root = Directory.current;
  try {
    final py = await Process.run('python3', ['--version']);
    if (py.exitCode != 0) markTestSkipped('needs python3');
  } catch (_) {
    markTestSkipped('needs python3 for the pty driver');
  }
  final res = await Process.run('python3', [
    '${root.path}/test/console_pty/drive.py',
    '--size', '24', '$cols',
    '--', Platform.resolvedExecutable,
    '${root.path}/test/console_pty/probe.dart',
    '${Directory.systemTemp.path}/probe_nosuch.log', mode,
  ], workingDirectory: root.path, stdoutEncoding: null,
      environment: {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color', ...?env});
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  return utf8.decode(res.stdout as List<int>, allowMalformed: true);
}

/// Run the choose probe under a pty with key feeds; return the log line.
Future<String> _ptyChoose({required List<(double, String)> feeds}) async {
  if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
  final root = Directory.current;
  try {
    final py = await Process.run('python3', ['--version']);
    if (py.exitCode != 0) markTestSkipped('needs python3');
  } catch (_) {
    markTestSkipped('needs python3 for the pty driver');
  }
  final log = File(
    '${Directory.systemTemp.path}/console-pty-${DateTime.now().microsecondsSinceEpoch}.log',
  );
  final res = await Process.run('python3', [
    '${root.path}/test/console_pty/drive.py',
    '--size', '24', '80',
    // Feeds count from the menu's first draw, not from the process start.
    '--ready', 'blue',
    for (final (delay, bytes) in feeds) ...['--feed', '$delay', bytes],
    '--', Platform.resolvedExecutable,
    '${root.path}/test/console_pty/probe.dart', log.path, 'choose',
  ], workingDirectory: root.path, stdoutEncoding: null);
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  try {
    return (await log.readAsString()).trim();
  } finally {
    try {
      await log.delete();
    } catch (_) {}
  }
}
