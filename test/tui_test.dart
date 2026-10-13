import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/src/terminal.dart' as term;
import 'package:dart_toolkit/src/tui.dart' show testInput, testScreen;
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
    int w(String ch) => term.cellWidth(ch.runes.first);

    test('wide CJK and emoji take two cells', () {
      expect(w('日'), 2);
      expect(w('a'), 1);
      expect(w('✅'), 2);
      expect(w('😀'), 2);
      expect(w('⭐'), 2);
    });

    test('symbols terminals draw narrow stay one cell', () {
      // Regression: the whole U+2600–27BF / U+2B00 blocks were counted wide,
      // shifting every row that used ✻ ❯ ✓ ✗.
      for (final ch in ['✻', '❯', '✓', '✗', '★', '⚠', '←', '⬆', '…', '│', '█']) {
        expect(w(ch), 1, reason: ch);
      }
    });

    test('combining marks, ZWJ and variation selectors are zero-width', () {
      expect(term.isZeroWidth(0x0301), isTrue);
      expect(term.isZeroWidth(0x200d), isTrue);
      expect(term.isZeroWidth(0xfe0f), isTrue);
      expect(term.isZeroWidth(0x1f3fb), isTrue);
      expect(term.isZeroWidth('a'.runes.single), isFalse);
    });
  });

  group('painter (in-memory terminal)', () {
    test('a partial change redraws in place (no cursor drift)', () async {
      // Regression: unchanged cells advanced the tracked cursor, so
      // "changed, unchanged, changed" drew the third cell one column left.
      final t = _Term(10, 2);
      final s = testScreen(t.feed, 10, 2);
      await s.frame((r) => r.write('abcdef'));
      await s.frame((r) => r.write('aXcdYf'));
      expect(t.row(0), 'aXcdYf    ');
      await s.frame((r) => r.write('count = 9'));
      await s.frame((r) => r.write('count = 10'));
      expect(t.row(0), 'count = 10');
    });

    test('wide chars take two cells with no extra space', () async {
      final t = _Term(12, 2);
      final s = testScreen(t.feed, 12, 2);
      await s.frame((r) => r.write('日本語abc').write('✻ rawfree'));
      expect(t.row(0), '日本語abc   ');
      expect(t.row(1), '✻ rawfree   ');
      await s.frame((r) => r.write('日x語abc').write('❯ beta'));
      expect(t.row(0), '日x語abc    ');
      expect(t.row(1), '❯ beta      ');
    });

    test('a width the terminal disagrees on damages only its own cell',
        () async {
      // The terminal draws ✻ two cells wide; we think one. The next cell is
      // addressed explicitly, so "rawfree" still lands where it belongs.
      final t = _Term(12, 1, wide: {'✻'});
      final s = testScreen(t.feed, 12, 1);
      await s.frame((r) => r.write('✻ rawfree'));
      expect(t.row(0).substring(2), 'rawfree   ');
    });

    test('combining marks join their base (Vietnamese NFD)', () async {
      final t = _Term(10, 1);
      final s = testScreen(t.feed, 10, 1);
      const nfd = 'Nguyễn';
      await s.frame((r) => r.write(nfd));
      expect(t.cells(0).take(7).toList(),
          ['N', 'g', 'u', 'y', 'ễ', 'n', ' ']);
    });

    test('a style never leaks into the next cell', () async {
      final t = _Term(6, 2);
      final s = testScreen(t.feed, 6, 2);
      await s.frame((r) => r.write('ab', bold: true, color: 1).write('cd', color: 2));
      expect(t.styleAt(0, 0), {'bold', 'fg1'});
      expect(t.styleAt(0, 1), {'fg2'});
      expect(t.styleAt(2, 0), isEmpty);
    });

    test('a resize repaints every cell at the new size', () async {
      var size = (20, 4);
      final t = _Term(20, 4);
      final s = testScreen(t.feed, 0, 0, size: () => size);
      await s.frame((r) => r.write('wide screen text'));
      size = (8, 2);
      t.resize(8, 2); // a fresh terminal: anything we skip stays blank
      await s.frame((r) => r.write('narrow').write('row two'));
      expect(t.row(0), 'narrow  ');
      expect(t.row(1), 'row two ');
    });

    test('control characters never reach the terminal raw', () async {
      final out = StringBuffer();
      final s = testScreen(out.write, 20, 3);
      await s.frame((r) => r.write('a\tb\x01c\x1b[31mred\x1b[0m\rz'));
      final raw = out.toString().replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '');
      expect(raw.codeUnits.where((c) => c < 0x20), isEmpty);
      expect(raw, contains('a       b�cred�z'));
    });

    test('nothing changed writes nothing', () async {
      final out = StringBuffer();
      final s = testScreen(out.write, 10, 2);
      await s.frame((r) => r.write('same'));
      final first = out.length;
      await s.frame((r) => r.write('same'));
      expect(out.length, first);
    });
  });

  group('input (in-memory)', () {
    test('input stays readable after frame returns; letters are pressed',
        () async {
      final s = testScreen((_) {}, 10, 2);
      testInput(s, utf8.encode('q'));
      await s.frame((r) {});
      expect(s.pressed('q'), isTrue);
      expect(s.typed(), 'q');
      await s.frame((r) {});
      expect(s.pressed('q'), isFalse);
    });

    test('presses in one frame all count, in order', () async {
      final s = testScreen((_) {}, 20, 6);
      var sel = 0;
      var text = '';
      testInput(s, utf8.encode('\x1b[B\x1b[Bab\x7fc'));
      await s.frame((r) {
        final [a, b] = r.rows([1, 0]);
        text = a.input(text);
        sel = b.list(['0', '1', '2', '3'], sel);
      });
      expect(sel, 2);
      expect(text, 'ac');
    });

    test('a lone ESC waits briefly, then is escape', () async {
      final s = testScreen((_) {}, 10, 2);
      testInput(s, [0x1b]);
      await s.frame((r) {});
      expect(s.pressed('escape'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await s.frame((r) {});
      expect(s.pressed('escape'), isTrue);
    });

    test('a sequence split across reads is one key, not escape', () async {
      final s = testScreen((_) {}, 10, 2);
      testInput(s, [0x1b]);
      await s.frame((r) {});
      testInput(s, utf8.encode('[A'));
      await s.frame((r) {});
      expect(s.pressed('up'), isTrue);
      expect(s.pressed('escape'), isFalse);
      expect(s.typed(), isEmpty);
    });

    test('a pasted newline becomes a space in input()', () async {
      final out = StringBuffer();
      final s = testScreen(out.write, 20, 2);
      var v = '';
      testInput(s, utf8.encode('\x1b[200~one\ntwo\x1b[201~'));
      await s.frame((r) => v = r.input(v));
      expect(v, 'one two');
      expect(s.pressed('enter'), isFalse);
    });

    test('list scrolls by the least needed and clicks pick what was shown',
        () async {
      final s = testScreen((_) {}, 10, 3);
      final items = [for (var i = 0; i < 10; i++) 'item $i'];
      var sel = 0;
      for (var i = 0; i < 3; i++) {
        testInput(s, utf8.encode('\x1b[B'));
        await s.frame((r) => sel = r.list(items, sel));
      }
      expect(sel, 3); // rows show items 1..3, not a page jump to 3..5
      testInput(s, utf8.encode('\x1b[<0;1;1M')); // click the top row
      await s.frame((r) => sel = r.list(items, sel));
      expect(sel, 1);
    });

    test('a button below the region edge is not drawn and cannot fire',
        () async {
      final out = StringBuffer();
      final s = testScreen(out.write, 20, 2);
      var fired = <bool>[];
      testInput(s, utf8.encode('\r'));
      await s.frame((r) {
        final [top] = r.rows([1]);
        fired = [top.button('one'), top.button('two')];
      });
      expect(fired, [true, false]);
      expect(out.toString(), isNot(contains('two')));
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

    test('pty: CJK rows render in place, autowrap off, leave restores',
        () async {
      final (_, termBytes) = await _pty(
        mode: 'cjk',
        rows: 10,
        cols: 30,
        feeds: const [(2.0, r'\x1b')],
      );
      final out = utf8.decode(termBytes, allowMalformed: true);
      expect(out, contains('\x1b[?7l'));
      final t = _Term(30, 10)..feed(out.substring(0, out.indexOf('\x1b[?1049l')));
      expect(t.row(0), '日 本 語abc${' ' * 19}');
      expect(t.row(1), 'plain row two${' ' * 17}');
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
  // Regression: a stdin listener kept every app alive after Tui.run.
  if ('${res.stderr}'.contains('did not exit')) {
    fail('the probe did not exit after Tui.run returned');
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

/// A tiny VT100 for assertions: CUP, SGR, `?` modes, chars with widths
/// from the same table as the engine unless [wide] says otherwise.
final class _Term {
  _Term(this.w, this.h, {this.wide = const {}}) : _cells = _blank(w, h);

  int w;
  int h;
  final Set<String> wide;
  List<List<(String, Set<String>)>> _cells;
  var _x = 0;
  var _y = 0;
  var _style = <String>{};

  static List<List<(String, Set<String>)>> _blank(int w, int h) =>
      List.generate(h, (_) => List.filled(w, (' ', const <String>{})));

  void resize(int nw, int nh) {
    w = nw;
    h = nh;
    _cells = _blank(w, h);
    _x = _y = 0;
  }

  String row(int y) => _cells[y].map((c) => c.$1).join();
  List<String> cells(int y) => _cells[y].map((c) => c.$1).toList();
  Set<String> styleAt(int x, int y) => _cells[y][x].$2;

  void feed(String s) {
    final runes = s.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final r = runes[i];
      if (r == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        final params = String.fromCharCodes(runes.sublist(i + 2, j));
        final fin = String.fromCharCode(runes[j]);
        if (fin == 'H' && !params.startsWith('?')) {
          final p = params.isEmpty ? ['1', '1'] : params.split(';');
          _y = int.parse(p[0]) - 1;
          _x = int.parse(p[1]) - 1;
        } else if (fin == 'm') {
          final codes = params.split(';').map(int.tryParse).toList();
          for (var k = 0; k < codes.length; k++) {
            final code = codes[k];
            if (code == null || code == 0) _style = {};
            if (code == 1) _style = {..._style, 'bold'};
            if (code == 7) _style = {..._style, 'inverse'};
            if (code == 38 && k + 2 < codes.length) {
              _style = {..._style, 'fg${codes[k + 2]}'};
              k += 2;
            }
          }
        } else if (fin == 'J') {
          _cells = _blank(w, h);
        }
        i = j + 1;
        continue;
      }
      i++;
      if (r < 0x20) {
        fail('raw control ${r.toRadixString(16)} reached the terminal');
      }
      final ch = String.fromCharCode(r);
      if (term.isZeroWidth(r)) {
        final px = (_x - 1).clamp(0, w - 1);
        _cells[_y][px] = ('${_cells[_y][px].$1}$ch', _cells[_y][px].$2);
        continue;
      }
      final cw = wide.contains(ch) ? 2 : term.cellWidth(r);
      if (_y < 0 || _y >= h) continue;
      final x = _x.clamp(0, w - 1);
      _cells[_y][x] = (ch, _style);
      if (cw == 2 && x + 1 < w) _cells[_y][x + 1] = ('', _style);
      // Autowrap is off: the cursor sticks at the last column.
      _x = x + cw >= w ? w - 1 : x + cw;
    }
  }
}
