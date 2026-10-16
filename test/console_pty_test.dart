@Tags(['pty'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/child.dart';
import 'support/io.dart';

void main() {
  group('pty (K1, K6, K10)', () {
    // Regression: the 80 ms repaint of a live spinner landed on the prompt
    // and the typed answer.
    test('a prompt parks the live block: no spinner frame while it waits', () async {
      final root = Directory.current;
      final log = tempFile('probe-park.log');
      final res = await Process.run(
        'python3',
        [
          '${root.path}/test/console_pty/drive.py',
          '--size', '24', '80', //
          '--ready', 'Name?',
          '--feed', '0.6', 'ada',
          '--feed', '0.9', r'\x0d',
          '--',
          Platform.resolvedExecutable,
          '${root.path}/test/console_pty/probe.dart',
          log.path,
          'park',
        ],
        workingDirectory: root.path,
        stdoutEncoding: null,
        environment: {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color'},
      );
      if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
      final out = utf8.decode(res.stdout as List<int>, allowMalformed: true);
      final asked = out.indexOf('Name?');
      final answered = out.indexOf('ada', asked);
      expect(asked, isNot(-1));
      expect(answered, isNot(-1));
      expect(out.substring(asked, answered), isNot(matches(RegExp('[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'))));
      expect(out.substring(answered), matches(RegExp('[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]')), reason: 'the spinner comes back');
      expect(await log.readAsString(), 'answer=ada\n');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('P3: under TERM=dumb notify and copy print no escapes', () async {
      final root = Directory.current;
      final res = await Process.run(
        'python3',
        [
          '${root.path}/test/console_pty/drive.py',
          '--size', '24', '80', //
          '--',
          Platform.resolvedExecutable,
          '${root.path}/test/console_pty/probe.dart',
          tempFile('probe-dumb.log').path,
          'dumb',
        ],
        workingDirectory: root.path,
        stdoutEncoding: null,
        environment: {'LANG': 'en_US.UTF-8', 'TERM': 'dumb'},
      );
      if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
      final out = utf8.decode(res.stdout as List<int>, allowMalformed: true);
      expect(out, contains('done'));
      expect(out, isNot(contains('\x1b]')));
    }, timeout: const Timeout(Duration(seconds: 90)));

    // Regression (ARCHITECTURE A6): an unanswered piped prompt kept the VM
    // alive until a line arrived.
    test('ask(timeout:) on an open pipe gives or and lets the script exit', () async {
      final root = Directory.current;
      final log = tempFile('probe-asktimeout.log');
      final proc = await Process.start(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        log.path,
        'asktimeout',
      ], workingDirectory: root.path);
      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.drain<void>());
      // stdin stays open and silent.
      final code = await proc.exitCode.timeout(const Duration(seconds: 20), onTimeout: () {
        proc.kill();
        return -1;
      });
      expect(code, 0, reason: 'exits on its own');
      expect(await log.readAsString(), 'answer=anon\n');
      await proc.stdin.close();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('ask(timeout:) on a terminal gives or and stops the reader', () async {
      final root = Directory.current;
      final log = tempFile('probe-ttytimeout.log');
      final res = await Process.run('python3', [
        '${root.path}/test/console_pty/drive.py',
        '--size', '24', '80', //
        '--ready', 'Name?',
        '--',
        Platform.resolvedExecutable,
        '${root.path}/test/console_pty/probe.dart',
        log.path,
        'asktimeout',
      ], workingDirectory: root.path);
      expect('${res.stderr}', contains('exit=0'));
      expect('${res.stderr}', isNot(contains('did not exit')));
      expect(await log.readAsString(), 'answer=anon\n');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('K1: the live line fits the width and clears to end of line', () async {
      final term = await _ptyBar(cols: 40);
      // Every redraw ends with erase-to-end-of-line.
      expect(term, contains('\x1b[K'));
      // A long label is cut with …: no redraw exceeds 40 cells.
      expect(term, contains('…'));
      for (final chunk in term.split('\r')) {
        final line = chunk.split('\x1b[').first;
        expect(_cells(line), lessThanOrEqualTo(40), reason: 'redraw too wide: $line');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('on a narrow terminal the bar gives up cells before the rate is cut', () async {
      final term = await _ptyBar(cols: 40, mode: 'short');
      final lines = [
        for (final c in term.split('\r')) c.split('\x1b[K').first.replaceAll(RegExp('\x1b\\[[0-9;?]*[a-zA-Z]'), ''),
      ];
      final shown = lines.where((l) => l.contains('12/40'));
      expect(shown, isNotEmpty);
      expect(shown.where((l) => l.contains('…')), isEmpty, reason: '$shown');
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

    test('bar, spinner and choose emit no colour codes', () async {
      final root = Directory.current;
      Future<String> run(String mode) async {
        final res = await Process.run(
          'python3',
          [
            '${root.path}/test/console_pty/drive.py',
            '--size',
            '24',
            '80',
            if (mode == 'choose') ...['--ready', 'blue', '--feed', '1.0', r'\x0d'],
            '--',
            Platform.resolvedExecutable,
            '${root.path}/test/console_pty/probe.dart',
            tempFile('probe.log').path,
            mode,
          ],
          workingDirectory: root.path,
          stdoutEncoding: null,
        );
        return utf8.decode(res.stdout as List<int>, allowMalformed: true);
      }

      final colour = RegExp(r'\x1b\[([0-9;]*)m');
      bool hasColour(String s) => colour
          .allMatches(s)
          .any(
            (m) => m
                .group(1)!
                .split(';')
                .map((p) => int.tryParse(p) ?? 0)
                .any((n) => (n >= 30 && n <= 37) || (n >= 90 && n <= 97) || n == 38 || n == 48),
          );
      for (final mode in ['bar', 'spin', 'choose']) {
        final out = await run(mode);
        expect(out, isNotEmpty, reason: mode);
        expect(hasColour(out), isFalse, reason: mode);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('P12: after a narrowing resize the live block moves up past its reflowed rows', () async {
      final root = Directory.current;
      final res = await Process.run(
        'python3',
        [
          '${root.path}/test/console_pty/drive.py',
          '--size', '24', '80', //
          '--ready', 'alpha',
          '--resize', '1.0', '24', '20',
          '--',
          Platform.resolvedExecutable,
          '${root.path}/test/console_pty/probe.dart',
          tempFile('probe-narrow.log').path,
          'narrow',
        ],
        workingDirectory: root.path,
        stdoutEncoding: null,
        environment: {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color'},
      );
      final out = utf8.decode(res.stdout as List<int>, allowMalformed: true);
      expect(out, contains('narrowed'));
      // Two 39-cell rows reflow to two rows each at 20 columns: up three.
      expect(out, contains('\r\x1b[3A'), reason: out);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('live lines stack: a bar and two spinners each keep a row', () async {
      final out = await _ptyBar(cols: 40, mode: 'stack');
      expect(out, contains('stacked'));
      // The block redraws from its top row: one move-up per extra row.
      expect(out, contains('\x1b[2A'));
      for (final done in ['✓ beta', '✓ alpha', 'files ━']) {
        expect(out, contains(done));
      }
      for (final chunk in out.split(RegExp('[\r\n]'))) {
        expect(_cells(chunk.split('\x1b[').first), lessThanOrEqualTo(39), reason: chunk);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the tty reader child dies with us: exit(), a crash, a cancel', () async {
      final root = Directory.current;
      for (final mode in ['orphan-exit', 'orphan-crash', 'orphan-cancel']) {
        final log = tempFile('console-orphan.log');
        // A shell owns the pty (like a login shell), so our exit sends no
        // SIGHUP that would end an orphan for us; it holds the pty open
        // while the probe's detached checker looks.
        final res = await Process.run('python3', [
          '${root.path}/test/console_pty/drive.py',
          '--size',
          '24',
          '80',
          '--ready',
          'cat=',
          '--',
          '/bin/sh',
          '-c',
          r'"$@"; sleep 1.5',
          'sh',
          Platform.resolvedExecutable,
          '${root.path}/test/console_pty/probe.dart',
          log.path,
          mode,
        ], workingDirectory: root.path);
        expect(res.stdout, matches(RegExp(r'cat=\d+')), reason: mode);
        if (mode == 'orphan-cancel') {
          expect(res.stdout, contains('alive=false'));
        } else {
          expect((await log.readAsString()).trim(), 'gone', reason: mode);
        }
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('H15: an unclosed bar does not keep the process alive', () async {
      final root = Directory.current;
      final res = await Process.run('python3', [
        '${root.path}/test/console_pty/drive.py',
        '--size',
        '24',
        '80',
        '--ready',
        'ready-leak',
        '--',
        Platform.resolvedExecutable,
        '${root.path}/test/console_pty/probe.dart',
        tempFile('probe.log').path,
        'leak',
      ], workingDirectory: root.path);
      expect(res.stderr, isNot(contains('did not exit')));
      expect(res.stderr, contains('exit=0'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('K6: interactive choose takes arrows+enter, escape gives or', () async {
      final pick = await _ptyChoose(feeds: const [(1.5, r'\x1b[B'), (2.0, r'\x0d')]);
      expect(pick, 'pick=green');
      final esc = await _ptyChoose(feeds: const [(1.5, r'\x1b')]);
      expect(esc, 'pick=red');
      // Two keys in one read are two presses.
      final burst = await _ptyChoose(feeds: const [(1.5, r'\x1b[B\x1b[B'), (2.0, r'\x0d')]);
      expect(burst, 'pick=blue');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('M7: interactive pick: arrows move, space ticks, a ticks all, enter returns; escape gives or', () async {
      // green starts ticked and under the cursor: down, tick blue, enter.
      expect(
        await _ptyChoose(mode: 'pick', ready: 'cyan', feeds: const [(1.5, r'\x1b[B'), (2.0, ' '), (2.5, r'\x0d')]),
        'picked=green,blue',
      );
      // untick green, tick red above it.
      expect(
        await _ptyChoose(
          mode: 'pick',
          ready: 'cyan',
          feeds: const [(1.5, ' '), (2.0, r'\x1b[A'), (2.5, ' '), (3.0, r'\x0d')],
        ),
        'picked=red',
      );
      expect(
        await _ptyChoose(mode: 'pick', ready: 'cyan', feeds: const [(1.5, 'a'), (2.0, r'\x0d')]),
        'picked=red,green,blue,cyan',
      );
      expect(await _ptyChoose(mode: 'pick', ready: 'cyan', feeds: const [(1.5, ' '), (2.0, r'\x1b')]), 'picked=green');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('M7: pick under TERM=dumb reads numbers and ranges', () async {
      final out = await _pty(['pick'], feeds: [r'1,3-4\x0d'], env: {'TERM': 'dumb'}, ready: 'cyan');
      expect(out.$2, 'picked=red,blue,cyan');
      expect(out.$1, isNot(contains('\x1b[')), reason: out.$1);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('P8: choose under TERM=dumb is the numbered list; under LC_ALL=C its hint is ASCII', () async {
      final root = Directory.current;
      Future<(String, String)> run(Map<String, String> env, List<String> feeds) async {
        final log = tempFile('probe-p8.log');
        final res = await Process.run(
          'python3',
          [
            '${root.path}/test/console_pty/drive.py',
            '--size', '24', '80', //
            '--ready', 'blue',
            for (final f in feeds) ...['--feed', '1.0', f],
            '--',
            Platform.resolvedExecutable,
            '${root.path}/test/console_pty/probe.dart',
            log.path,
            'choose',
          ],
          workingDirectory: root.path,
          stdoutEncoding: null,
          environment: {'LANG': 'en_US.UTF-8', ...env},
        );
        if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
        return (utf8.decode(res.stdout as List<int>, allowMalformed: true), (await log.readAsString()).trim());
      }

      final (dumb, dumbPick) = await run({'TERM': 'dumb'}, [r'2\x0d']);
      expect(dumbPick, 'pick=green');
      expect(dumb, isNot(contains('\x1b[')), reason: dumb);
      final (ascii, _) = await run({'TERM': 'xterm-256color', 'LC_ALL': 'C'}, [r'\x0d']);
      expect(ascii, contains('enter select'));
      expect(ascii, isNot(contains('↑↓')));
      expect(ascii, isNot(contains('·')));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a menu repaint after a resize clears the rows the old paint left', () async {
      final root = Directory.current;
      final res = await Process.run(
        'python3',
        [
          '${root.path}/test/console_pty/drive.py',
          '--size',
          '24',
          '80',
          '--ready',
          'blue',
          '--resize',
          '0.5',
          '5',
          '80',
          '--feed',
          '1.5',
          r'\x1b[B',
          '--feed',
          '2.5',
          r'\x0d',
          '--',
          Platform.resolvedExecutable,
          '${root.path}/test/console_pty/probe.dart',
          tempFile('probe.log').path,
          'choose',
        ],
        workingDirectory: root.path,
        stdoutEncoding: null,
      );
      final out = utf8.decode(res.stdout as List<int>, allowMalformed: true);
      // Three items and the hint were painted at 24 rows; at 5 rows only two
      // items fit, so the repaint goes up four rows and clears below.
      expect(out, contains('\x1b[4A\r\x1b[J'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('piped choose reads a number; ask reads a line', () async {
      final root = Directory.current;
      final probe = '${root.path}/test/console_pty/probe.dart';
      final log = tempFile('console-pty.log');
      Future<String> run(List<String> args, String stdin) async {
        final proc = await Process.start(Platform.resolvedExecutable, [
          probe,
          log.path,
          ...args,
        ], workingDirectory: root.path);
        proc.stdin.write(stdin);
        await proc.stdin.close();
        final code = await proc.exitCode.timeout(const Duration(seconds: 60));
        expect(code, 0);
        return log.readAsString();
      }

      expect(await run(['choose'], '2\n'), contains('pick=green'));
      expect(await run(['pick'], '4 1\n'), contains('picked=red,cyan'));
      expect(await run(['pick'], 'x\n2-9\n3\n'), contains('picked=blue'), reason: 're-asks until the line reads');
      expect(await run(['pick'], '\n'), contains('picked=green'), reason: 'an empty line keeps or');
      expect(await run(['pick'], ''), contains('picked=green'), reason: 'a closed stdin gives or');
      expect(await run(['ask'], 'hello\n'), contains('answer=hello'));
      expect(await run(['secret'], 's3cret\n'), contains('secret=s3cret'));
      // H16: CRLF is one line break, also across two prompts.
      expect(await run(['ask2'], 'x\r\ny\r\n'), contains('answer=x|y'));
      // A closed stdin gives each prompt its `or` (null without one, confirm false).
      expect(await run(['eof'], ''), contains('eof=|dflt|true|false|null|y'));
      // An empty line gives `or`; without one the answer is empty.
      expect(await run(['empty'], '\n\n\n'), contains('empty=dflt||true'));
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('K3: SIGINT during a prompt exits 130 with the terminal restored', () async {
      final root = Directory.current;
      final out = tempFile('console-sigint.bin');
      final res = await Process.run('python3', [
        '${root.path}/test/console_pty/sigint_drive.py',
        out.path,
        '6.0',
        '--',
        Platform.resolvedExecutable,
        '${root.path}/test/console_pty/probe.dart',
        tempFile('probe.log').path,
        'secret',
      ], workingDirectory: root.path);
      expect(res.stdout, contains('EXIT=exit=130'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: noPty);
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
      while (i < runes.length && !(runes[i] >= 0x40 && runes[i] <= 0x7e)) {
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
  final root = Directory.current;
  final res = await Process.run(
    'python3',
    [
      '${root.path}/test/console_pty/drive.py',
      '--size',
      '24',
      '$cols',
      '--',
      Platform.resolvedExecutable,
      '${root.path}/test/console_pty/probe.dart',
      tempFile('probe.log').path,
      mode,
    ],
    workingDirectory: root.path,
    stdoutEncoding: null,
    environment: {'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color', ...?env},
  );
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  return utf8.decode(res.stdout as List<int>, allowMalformed: true);
}

/// Run a probe [mode] under a pty with [feeds] (1 s apart, from the first
/// draw that shows [ready]); return its output and log line.
Future<(String, String)> _pty(
  List<String> mode, {
  required List<String> feeds,
  required String ready,
  Map<String, String>? env,
}) async {
  final root = Directory.current;
  final log = tempFile('probe-pty.log');
  final res = await Process.run(
    'python3',
    [
      '${root.path}/test/console_pty/drive.py',
      '--size', '24', '80', //
      '--ready', ready,
      for (final f in feeds) ...['--feed', '1.0', f],
      '--',
      Platform.resolvedExecutable,
      '${root.path}/test/console_pty/probe.dart',
      log.path,
      ...mode,
    ],
    workingDirectory: root.path,
    stdoutEncoding: null,
    environment: {'LANG': 'en_US.UTF-8', ...?env},
  );
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  return (utf8.decode(res.stdout as List<int>, allowMalformed: true), (await log.readAsString()).trim());
}

/// Run the choose probe under a pty with key feeds; return the log line.
Future<String> _ptyChoose({required List<(double, String)> feeds, String mode = 'choose', String ready = 'blue'}) async {
  final root = Directory.current;
  final log = tempFile('console-pty.log');
  final res = await Process.run(
    'python3',
    [
      '${root.path}/test/console_pty/drive.py',
      '--size', '24', '80',
      // Feeds count from the menu's first draw, not from the process start.
      '--ready', ready,
      for (final (delay, bytes) in feeds) ...['--feed', '$delay', bytes],
      '--', Platform.resolvedExecutable,
      '${root.path}/test/console_pty/probe.dart', log.path, mode,
    ],
    workingDirectory: root.path,
    stdoutEncoding: null,
  );
  if (res.exitCode != 0) fail('pty driver failed: ${res.stderr}');
  return (await log.readAsString()).trim();
}
