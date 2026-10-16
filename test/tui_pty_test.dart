@Tags(['pty'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/child.dart';
import 'support/term.dart';

void main() {
  group('pty', () {
    test('keys route to bindings; shift+tab; bound ctrl+c lives', () async {
      final (log, _, _) = await _pty(
        mode: 'keys',
        feeds: const [(1.0, r'aq'), (1.3, r'\x1b[Z'), (1.5, r'\x1b[A'), (1.7, r' '), (1.9, r'\x03'), (2.5, r'\x1b')],
      );
      expect(log.split('\n'), ['a', 'q', 'shift+tab', 'up', 'space', 'ctrl+c', 'escape']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('with stdin piped, keys come from the terminal and its modes come back', () async {
      final root = Directory.current.path;
      final log = File('${Directory.systemTemp.path}/tui-piped-$pid.log');
      addTearDown(() => log.exists().then((e) => e ? log.delete() : null));
      final res = await Process.run('python3', [
        '$root/test/tui_pty/drive.py',
        '--size',
        '10',
        '40',
        '--feed',
        '0.5',
        'a',
        '--feed',
        '0.8',
        r'\x1b',
        '--',
        '/bin/sh',
        '-c',
        'echo hi | "\$0" "\$1" "\$2" keys; stty -a',
        Platform.resolvedExecutable,
        '$root/test/tui_pty/probe.dart',
        log.path,
      ], workingDirectory: root);
      expect('${res.stderr}', contains('exit=0'));
      expect((await log.readAsString()).trim().split('\n'), ['a', 'escape']);
      final stty = '${res.stdout}';
      expect(stty, contains(' icanon'));
      expect(stty, contains(' isig'));
      expect(stty, contains(' echo '));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('exit() in a handler still restores the modes and leaves the alternate screen', () async {
      final root = Directory.current.path;
      final log = File('${Directory.systemTemp.path}/tui-exit-$pid.log');
      addTearDown(() => log.exists().then((e) => e ? log.delete() : null));
      final res = await Process.run('python3', [
        '$root/test/tui_pty/drive.py',
        '--size',
        '10',
        '40',
        '--feed',
        '0.5',
        'q',
        '--',
        '/bin/sh',
        '-c',
        '"\$0" "\$1" "\$2" late; sleep 0.3; stty -a',
        Platform.resolvedExecutable,
        '$root/test/tui_pty/probe.dart',
        log.path,
      ], workingDirectory: root);
      expect('${res.stderr}', contains('exit=0'));
      final out = '${res.stdout}';
      expect(out.substring(out.lastIndexOf('\x1b[?1049h')), contains('\x1b[?1049l'));
      expect(out, contains(' icanon'));
      expect(out, contains(' isig'));
      expect(out, contains(' echo '));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('modifiers, insert, SS3, alt; focus reports and clicks add no keys', () async {
      final (log, _, _) = await _pty(
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
      expect(log.split('\n'), ['ctrl+delete', 'f1', 'insert', 'home', 'ctrl+up', 'alt+x', 'escape']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('CJK rows render in place, autowrap off, leave restores', () async {
      final (_, bytes, _) = await _pty(mode: 'cjk', rows: 10, cols: 30);
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(out, contains('\x1b[?7l'));
      final t = Term(30, 10)..feed(out.substring(0, out.indexOf('\x1b[?1049l')));
      expect(t.row(0), '日 本 語abc${' ' * 19}');
      expect(t.row(1), 'plain row two${' ' * 17}');
      for (final mode in ['?7h', '?1049l', '?1000l', '?1003l', '?1006l', '?1004l', '?2004l', '?25h', '<u']) {
        expect(out, contains('\x1b[$mode'), reason: 'restores $mode');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('tabs expand, controls become U+FFFD, newlines split rows', () async {
      final (_, bytes, _) = await _pty(mode: 'controls');
      final out = utf8.decode(bytes, allowMalformed: true);
      final t = Term(80, 24)..feed(out.substring(out.indexOf('\x1b[?1049h') + 8, out.indexOf('\x1b[?1049l')));
      expect(t.row(0).trimRight(), 'x       y');
      expect(t.row(1).trimRight(), 'a�b�c');
      expect([t.row(2), t.row(3), t.row(4)].map((r) => r.trimRight()), ['l1', 'l2', 'l3']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    // _pty fails when the probe does not exit by itself after main returns.
    test('after Tui.run returns, nothing keeps the VM alive (no exit() needed)', () async {
      final (log, _, code) = await _pty(mode: 'after', feeds: const [(1.0, 'q'), (1.4, 'y'), (1.6, r'\r')]);
      expect(log, 'after n=3');
      expect(code, 0);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a second run in the same process works', () async {
      final (log, _, _) = await _pty(mode: 'second');
      expect(log, 'second-ok');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('widgets: input, list click and keys, button', () async {
      final (log, _, _) = await _pty(
        mode: 'widgets',
        feeds: const [
          (1.5, r'hi'),
          (1.8, r'\x7f'),
          (2.1, r'\x1b[<0;2;5M'), // click row 4 of the screen = item 3
          (2.4, r'\x1b[B'),
          (2.7, r'\t\r'), // focus the button, press it
          (3.0, r'\x1b'),
        ],
      );
      expect(log.split('\n'), ['escape', 'query=h', 'sel=4', 'go=true']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('LANG=C draws ASCII; NO_COLOR drops colours', () async {
      final (_, bytes, _) = await _pty(
        mode: 'ascii',
        // PYTHONCOERCECLOCALE=0: python would set LC_CTYPE=C.UTF-8 for the child.
        env: {'LANG': 'C', 'LC_ALL': '', 'LC_CTYPE': 'C', 'NO_COLOR': '1', 'PYTHONCOERCECLOCALE': '0'},
      );
      final out = utf8.decode(bytes, allowMalformed: true);
      final body = out.substring(out.indexOf('\x1b[?1049h'), out.indexOf('\x1b[?1049l'));
      expect(body, contains('+- t -'));
      expect(body, isNot(matches(RegExp('[─━│┌]'))));
      expect(body, isNot(contains('38;5;')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('work landing inside the 60 fps gap is still painted', () async {
      final (_, bytes, _) = await _pty(mode: 'late', feeds: const [(1.5, 'a'), (2.5, 'q')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      final t = Term(80, 24)..feed(out);
      expect(t.row(0).trimRight(), 'two');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('external SIGINT becomes ctrl+c and restores the terminal', () async {
      final (_, bytes, code) = await _pty(mode: 'sigint', feeds: const [], signals: const [(0.5, 'INT')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      final end = out.indexOf('\x1b[?1049l');
      expect(end, isNot(-1));
      final t = Term(80, 24)..feed(out.substring(0, end));
      expect(t.row(0).trimRight(), 'saw ctrl+c');
      expect(code, 0);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('ctrl+z stops the app with the terminal restored; fg takes it back', () async {
      final root = Directory.current.path;
      final res = await Process.run('python3', [
        '$root/test/tui_pty/suspend_drive.py',
        '--',
        Platform.resolvedExecutable,
        '$root/test/tui_pty/probe.dart',
        '${Directory.systemTemp.path}/tui-suspend-$pid.log',
        'keys',
      ], workingDirectory: root);
      expect(
        '${res.stdout}'.trim(),
        'isig_off=True stopped=True left=True isig_back=True reentered=True isig_off_again=True exit=0',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    // Regression: the loop ran inside the redraw zone, so its own timers
    // woke it forever: timers, I/O and signals starved, spinners froze.
    test('while idle, spinners advance, timers paint and SIGTERM restores', () async {
      final (_, bytes, code) = await _pty(mode: 'alive', feeds: const [], signals: const [(1.5, 'TERM')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(code, 143);
      final end = out.indexOf('\x1b[?1049l');
      expect(end, isNot(-1), reason: 'SIGTERM restores the terminal');
      final frames = {for (final m in RegExp('[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]').allMatches(out)) m[0]};
      expect(frames.length, greaterThanOrEqualTo(3));
      final t = Term(80, 24)..feed(out.substring(0, end));
      expect(t.row(1).trimRight(), 'timer fired');
    }, timeout: const Timeout(Duration(seconds: 60)));

    // Regression: the zone woke the loop before a callback ran, so a state
    // set in a future's continuation painted only on the next event.
    test('a change made in a future continuation paints with no further event', () async {
      final (_, bytes, code) = await _pty(mode: 'idle', feeds: const [], signals: const [(1.5, 'TERM')]);
      final out = utf8.decode(bytes, allowMalformed: true);
      expect(code, 143);
      final t = Term(80, 24)..feed(out.substring(0, out.indexOf('\x1b[?1049l')));
      expect(t.row(0).trimRight(), 'loaded');
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, skip: noPty);
}

/// Run the probe helper under a real pty; return (log text, terminal bytes).
/// Skips (not fails) where a pty is unavailable: Windows, or no python3.
Future<(String, List<int>, int?)> _pty({
  required String mode,
  List<(double, String)> feeds = const [(1.0, r'\x1b')],
  List<(double, String)> signals = const [],
  int rows = 24,
  int cols = 80,
  Map<String, String> env = const {},
}) async {
  // `dart test` compiles the test into a temp dir, so Platform.script is
  // useless for locating helpers; the working directory is the package root.
  final root = Directory.current.path;
  final log = File('${Directory.systemTemp.path}/tui-pty-${DateTime.now().microsecondsSinceEpoch}.log');
  final res = await Process.run(
    'python3',
    [
      '$root/test/tui_pty/drive.py',
      '--size',
      '$rows',
      '$cols',
      for (final (delay, bytes) in feeds) ...['--feed', '$delay', bytes],
      for (final (delay, name) in signals) ...['--signal', '$delay', name],
      '--',
      Platform.resolvedExecutable,
      '$root/test/tui_pty/probe.dart',
      log.path,
      mode,
    ],
    workingDirectory: root,
    environment: {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color', ...env},
    stdoutEncoding: null,
  );
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  // Regression: a stdin listener kept every app alive after Tui.run.
  if ('${res.stderr}'.contains('did not exit')) {
    fail('the probe did not exit after Tui.run returned');
  }
  final code = RegExp(r'exit=(-?\d+)').firstMatch('${res.stderr}')?[1];
  var text = '';
  try {
    text = (await log.readAsString()).trim();
    await log.delete();
  } catch (_) {}
  return (text, res.stdout as List<int>, code == null ? null : int.parse(code));
}
