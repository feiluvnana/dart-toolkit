import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/src/terminal.dart' as term;
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

void main() {
  group('key decoder (unit)', () {
    List<term.TermEvent> events(String raw) =>
        term.decodeKeys(utf8.encode(raw)).events;

    test('printable text arrives as one typed event', () {
      final r = term.decodeKeys(utf8.encode('aq'));
      expect(r.consumed, 2);
      final e = r.events.single as term.TermType;
      expect(e.text, 'aq');
      expect(e.paste, isFalse);
    });

    test('split UTF-8 is held, never mojibake', () {
      final eAcute = utf8.encode('é');
      final first = term.decodeKeys(eAcute.sublist(0, 1));
      expect(first.events, isEmpty);
      expect(first.consumed, 0);
      final second = term.decodeKeys([...eAcute.sublist(0, 1), eAcute[1]]);
      expect((second.events.single as term.TermType).text, 'é');
    });

    test('lone ESC is held for the next read', () {
      final r = term.decodeKeys([0x1b]);
      expect(r.events, isEmpty);
      expect(r.consumed, 0);
    });

    test('ESC ESC is escape; ESC + char is alt+char', () {
      expect(
        (events('\x1b\x1b').single as term.TermKey).name,
        'escape',
      );
      expect(
        (events('\x1bx').single as term.TermKey).name,
        'alt+x',
      );
    });

    test('ESC + multibyte char decodes as one alt+char', () {
      final bytes = [0x1b, ...utf8.encode('é')];
      final r = term.decodeKeys(bytes);
      expect((r.events.single as term.TermKey).name, 'alt+é');
      expect(r.consumed, bytes.length);
    });

    test('enter variants: CR, LF, and CRLF as one enter', () {
      for (final raw in ['\r', '\n', '\r\n']) {
        expect(
          (events(raw).single as term.TermKey).name,
          'enter',
          reason: 'for ${raw.codeUnits}',
        );
      }
      expect(term.decodeKeys(utf8.encode('\r\n')).consumed, 2);
    });

    test('tab, backspace, ctrl letters and ctrl symbols', () {
      expect((events('\t').single as term.TermKey).name, 'tab');
      expect((events('\x7f').single as term.TermKey).name, 'backspace');
      expect((events('\x08').single as term.TermKey).name, 'backspace');
      expect((events('\x01').single as term.TermKey).name, 'ctrl+a');
      expect((events('\x1a').single as term.TermKey).name, 'ctrl+z');
      expect((events('\x00').single as term.TermKey).name, 'ctrl+space');
      expect((events('\x1c').single as term.TermKey).name, r'ctrl+\');
      expect((events('\x1d').single as term.TermKey).name, 'ctrl+]');
      expect((events('\x1e').single as term.TermKey).name, 'ctrl+^');
      expect((events('\x1f').single as term.TermKey).name, 'ctrl+_');
    });

    test('CSI arrows, home/end, insert/delete, pages, function keys', () {
      final cases = {
        '\x1b[A': 'up',
        '\x1b[B': 'down',
        '\x1b[C': 'right',
        '\x1b[D': 'left',
        '\x1b[H': 'home',
        '\x1b[F': 'end',
        '\x1b[1~': 'home',
        '\x1b[7~': 'home',
        '\x1b[2~': 'insert', // was wrongly 'enter'
        '\x1b[3~': 'delete',
        '\x1b[4~': 'end',
        '\x1b[8~': 'end',
        '\x1b[5~': 'pageup',
        '\x1b[6~': 'pagedown',
        '\x1b[11~': 'f1',
        '\x1b[15~': 'f5',
        '\x1b[17~': 'f6',
        '\x1b[24~': 'f12',
      };
      for (final entry in cases.entries) {
        expect(
          (events(entry.key).single as term.TermKey).name,
          entry.value,
          reason: 'for ${entry.key.codeUnits}',
        );
      }
    });

    test('CSI modifiers become prefixes; shift+tab', () {
      final cases = {
        '\x1b[1;5A': 'ctrl+up',
        '\x1b[1;2A': 'shift+up',
        '\x1b[1;3C': 'alt+right',
        '\x1b[1;8A': 'ctrl+alt+shift+up',
        '\x1b[Z': 'shift+tab',
        '\x1b[3;5~': 'ctrl+delete',
        '\x1b[2;2~': 'shift+insert',
      };
      for (final entry in cases.entries) {
        expect(
          (events(entry.key).single as term.TermKey).name,
          entry.value,
          reason: 'for ${entry.key.codeUnits}',
        );
      }
    });

    test('unknown and focus sequences are ignored, never escape', () {
      for (final raw in ['\x1b[999X', '\x1b[?25h', '\x1b[I', '\x1b[O']) {
        expect(events(raw), isEmpty, reason: 'for ${raw.codeUnits}');
      }
    });

    test('SS3: F1-F4 plus arrows/home/end; unknown ignored', () {
      final cases = {
        '\x1bOP': 'f1',
        '\x1bOQ': 'f2',
        '\x1bOR': 'f3',
        '\x1bOS': 'f4',
        '\x1bOA': 'up',
        '\x1bOB': 'down',
        '\x1bOC': 'right',
        '\x1bOD': 'left',
        '\x1bOH': 'home',
        '\x1bOF': 'end',
      };
      for (final entry in cases.entries) {
        expect(
          (events(entry.key).single as term.TermKey).name,
          entry.value,
          reason: 'for ${entry.key.codeUnits}',
        );
      }
      expect(events('\x1bOX'), isEmpty);
    });

    test('SGR mouse: left press clicks; rest ignored; no throw', () {
      final click = events('\x1b[<0;10;20M').single as term.TermClick;
      expect(click.x, 9);
      expect(click.y, 19);
      // Release, right/middle buttons: no click.
      expect(events('\x1b[<0;10;20m'), isEmpty);
      expect(events('\x1b[<2;10;20M'), isEmpty);
      expect(events('\x1b[<1;10;20M'), isEmpty);
      // Wheel reports keys.
      expect(
        (events('\x1b[<64;5;5M').single as term.TermKey).name,
        'wheelup',
      );
      expect(
        (events('\x1b[<65;5;5M').single as term.TermKey).name,
        'wheeldown',
      );
      // Malformed SGR never throws.
      expect(events('\x1b[<M'), isEmpty);
      expect(events('\x1b[<0M'), isEmpty);
    });

    test('split CSI is held for the next read', () {
      final r = term.decodeKeys(utf8.encode('\x1b['));
      expect(r.events, isEmpty);
      expect(r.consumed, 0);
    });

    test('bracketed paste arrives typed-only, CR included', () {
      final r = term.decodeKeys(utf8.encode('\x1b[200~a\r\nb\x1b[201~'));
      final e = r.events.single as term.TermType;
      expect(e.text, 'a\r\nb');
      expect(e.paste, isTrue);
      expect(r.consumed, greaterThan(0));
    });

    test('unterminated paste is held, split paste merges', () {
      final part = utf8.encode('\x1b[200~ab');
      final first = term.decodeKeys(part);
      expect(first.events, isEmpty);
      expect(first.consumed, 0);
      final rest = [...part, ...utf8.encode('cd\x1b[201~')];
      final second = term.decodeKeys(rest);
      final e = second.events.single as term.TermType;
      expect(e.text, 'abcd');
      expect(e.paste, isTrue);
    });
  });

  group('cell widths (unit)', () {
    test('wide CJK and emoji take two cells', () {
      expect(cellWidth('日'.runes.single), 2);
      expect(cellWidth('a'.runes.single), 1);
      expect(cellWidth('✅'.runes.single), 2);
      expect(cellWidth('←'.runes.single), 1);
    });

    test('combining marks, ZWJ and variation selectors are zero-width', () {
      expect(isZeroWidth(0x0301), isTrue);
      expect(isZeroWidth(0x200d), isTrue);
      expect(isZeroWidth(0xfe0f), isTrue);
      expect(isZeroWidth(0x1f3fb), isTrue);
      expect(isZeroWidth('a'.runes.single), isFalse);
    });
  });

  group('Tui.run', () {
    test('throws StdoutException when stdout is not a terminal', () async {
      if (stdout.hasTerminal) {
        markTestSkipped('needs a piped stdout');
      }
      expect(
        Tui.run((screen) async {}),
        throwsA(isA<StdoutException>()),
      );
    });

    test('pty: letters are pressed+typed after frame; shift+tab; ctrl+c lives',
        () async {
      final (log, _) = await _pty(
        mode: 'keys',
        feeds: const [
          (1.0, r'aq'),
          (1.3, r'\x1b[Z'),
          (1.5, r'\x1b[A'),
          (1.7, r' '),
          (1.9, r'\x03'),
          (2.5, r'\x1b'),
        ],
      );
      expect(log, contains('pressed-a'));
      expect(log, contains('typed=aq'));
      expect(log, contains('shift+tab'));
      expect(log, isNot(contains('bare-escape-after-shift-tab')));
      expect(log, contains('up'));
      expect(log, contains('space'));
      expect(log, contains('ctrl+c'));
      expect(log.trimRight().split('\n').last, endsWith('escape'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('pty: modifiers, insert, SS3, alt; focus events ignored', () async {
      final (log, _) = await _pty(
        mode: 'keys',
        feeds: const [
          (1.0, r'\x1b[3;5~'),
          (1.2, r'\x1b[I'),
          (1.4, r'\x1bOP'),
          (1.6, r'\x1b[2~'),
          (1.8, r'\x1bOH'),
          (2.0, r'\x1b[1;5A'),
          (2.2, r'\x1bx'),
          (2.6, r'\x1b[M\x00\x05\x06'),
          (3.0, r'\x1b'),
        ],
      );
      for (final key in [
        'ctrl+delete',
        'f1',
        'insert',
        'home',
        'ctrl+up',
        'alt+x',
      ]) {
        expect(log, contains(key));
      }
      // The focus event and the mouse click add no key lines.
      final lines = log.trimRight().split('\n');
      expect(lines.where((l) => l.endsWith('escape')).length, 1);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('pty: CJK rows address per row, autowrap off, leave restores',
        () async {
      final (_, termBytes) = await _pty(
        mode: 'cjk',
        rows: 10,
        cols: 30,
        feeds: const [(2.0, r'\x1b')],
      );
      final out = utf8.decode(termBytes, allowMalformed: true);
      expect(out, contains('\x1b[?7l'));
      expect(out, contains('\x1b[1;1H'));
      expect(out, contains('\x1b[2;1H'));
      // Row 1 is exactly 30 cells: 日 本 語abc + 19 spaces (no 3-col blowup).
      final row1 = out.split('\x1b[1;1H')[1].split('\x1b[2;1H')[0];
      expect(row1, '日 本 語abc${' ' * 19}');
      expect(out, contains('\x1b[?7h'));
      expect(out, contains('\x1b[?1049l'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('pty: tabs expand, controls become U+FFFD, newlines split rows',
        () async {
      final (_, termBytes) = await _pty(
        mode: 'controls',
        feeds: const [(2.0, r'\x1b')],
      );
      final out = utf8.decode(termBytes, allowMalformed: true);
      expect(out.codeUnits, isNot(contains(0x09)));
      expect(out, contains('x${' ' * 7}y'));
      expect(out, contains('�'));
      final l1 = out.indexOf('l1');
      final l2 = out.indexOf('l2');
      final l3 = out.indexOf('l3');
      expect(l1, isNot(-1));
      expect(l2, greaterThan(l1));
      expect(l3, greaterThan(l2));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('pty: a second run in the same process works', () async {
      final (log, _) = await _pty(mode: 'second');
      expect(log.trim(), 'second-ok');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('pty: widgets — input, list, button', () async {
      final (log, _) = await _pty(
        mode: 'widgets',
        feeds: const [
          (1.5, r'hi'),
          (1.8, r'\x7f'),
          (2.1, r'\x1b[<0;2;5M'),
          (2.4, r'\x1b[B'),
          (2.7, r'\x0d'),
          (3.0, r'\x1b'),
        ],
      );
      expect(log, contains('query=h'));
      expect(log, contains('sel=4'));
      expect(log, contains('go=true'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('pty: external SIGINT becomes ctrl+c and restores the terminal',
        () async {
      final termBytes = await _ptySigint();
      final out = utf8.decode(termBytes, allowMalformed: true);
      expect(out, contains('saw ctrl+c'));
      expect(out, contains('\x1b[?1049l'));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

/// Run the probe helper under a real pty; return (log text, terminal bytes).
/// Skips (not fails) where a pty is unavailable: Windows, or no python3.
Future<(String, List<int>)> _pty({
  required String mode,
  List<(double, String)> feeds = const [(2.0, r'\x1b')],
  int rows = 24,
  int cols = 80,
}) async {
  if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
  // `dart test` compiles the test into a temp dir, so Platform.script is
  // useless for locating helpers; the working directory is the package root.
  final root = Directory.current;
  final drive = File('${root.path}/test/tui_pty/drive.py');
  final probe = File('${root.path}/test/tui_pty/probe.dart');
  if (!await drive.exists() || !await probe.exists()) {
    markTestSkipped('missing pty helpers');
  }
  late final ProcessResult py;
  try {
    py = await Process.run('python3', ['--version']);
  } catch (_) {
    markTestSkipped('needs python3 for the pty driver');
  }
  if (py.exitCode != 0) markTestSkipped('needs python3 for the pty driver');
  final log = File(
    '${Directory.systemTemp.path}/tui-pty-${DateTime.now().microsecondsSinceEpoch}.log',
  );
  final dartExe = Platform.resolvedExecutable;
  final args = [
    drive.path,
    '--size', '$rows', '$cols',
    for (final (delay, bytes) in feeds) ...['--feed', '$delay', bytes],
    '--',
    dartExe, probe.path, log.path, mode, '400',
  ];
  final res = await Process.run(
    'python3',
    args,
    workingDirectory: root.path,
    stdoutEncoding: null,
  );
  if (res.exitCode != 0) {
    fail('pty driver failed: ${res.stderr}');
  }
  var logText = '';
  try {
    logText = await log.readAsString();
  } catch (_) {}
  // Normalize the raw key log into stable assertions:
  logText = _normalizeKeys(logText);
  try {
    await log.delete();
  } catch (_) {}
  return (logText, (res.stdout as List<int>));
}

String _normalizeKeys(String log) {
  final out = <String>[];
  var sawShiftTab = false;
  for (final line in log.split('\n')) {
    if (line.isEmpty) continue;
    final key = line.split(':').last;
    if (key == 'a') out.add('pressed-a');
    if (key.startsWith('typed=')) out.add(line.split(':').last);
    if (key == 'shift+tab') {
      out.add('shift+tab');
      sawShiftTab = true;
      continue;
    }
    if (sawShiftTab && key == 'escape') {
      out.add('bare-escape-after-shift-tab');
      sawShiftTab = false;
      continue;
    }
    sawShiftTab = false;
    out.add(key);
  }
  return out.join('\n');
}

Future<List<int>> _ptySigint() async {
  if (Platform.isWindows) markTestSkipped('needs a POSIX pty');
  final root = Directory.current;
  try {
    final py = await Process.run('python3', ['--version']);
    if (py.exitCode != 0) markTestSkipped('needs python3');
  } catch (_) {
    markTestSkipped('needs python3 for the pty driver');
  }
  final out = File(
    '${Directory.systemTemp.path}/tui-sigint-${DateTime.now().microsecondsSinceEpoch}.bin',
  );
  final res = await Process.run('python3', [
    '${root.path}/test/tui_pty/sigint_drive.py',
    out.path,
    '4.0',
    '--',
    Platform.resolvedExecutable,
    '${root.path}/test/tui_pty/sigint.dart',
  ], workingDirectory: root.path);
  if (res.exitCode != 0) fail('sigint driver failed: ${res.stderr}');
  try {
    return await out.readAsBytes();
  } finally {
    try {
      await out.delete();
    } catch (_) {}
  }
}
