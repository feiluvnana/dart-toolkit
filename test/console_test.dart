import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:test/test.dart';

void main() {
  group('Console.choose', () {
    test('empty items is an ArgumentError', () {
      expect(
        Console.choose('Pick', <String>[], label: (s) => s),
        throwsArgumentError,
      );
    });

    test('an unknown keys binding is an ArgumentError, before any prompt',
        () {
      expect(
        Console.choose('Pick', ['a', 'b'],
            label: (s) => s, keys: {'notakey-xyz': 'a'}),
        throwsArgumentError,
      );
    });

    test('an initial that is not an item is an ArgumentError', () {
      expect(
        Console.choose('Pick', ['a', 'b'], label: (s) => s, or: 'z'),
        throwsArgumentError,
      );
    });
  });

  group('Console.spin', () {
    test('returns the work result', () async {
      expect(await Console.spin('Work', Future.value(42)), 42);
    });

    test('rethrows the work error', () async {
      expect(
        Console.spin<void>('Work', Future.error(StateError('bad'))),
        throwsStateError,
      );
    });
  });

  group('Bar', () {
    test('tick counts and stops at the total, returns the bar', () async {
      final bar = Console.bar(3, label: 'T');
      expect(identical(bar.tick(), bar), isTrue);
      bar.tick(5);
      await bar.close();
    });

    test('L3: counts past the total are kept, negative ticks ignored',
        () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'over',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('5/3'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('L2: control characters in labels are neutralised', () async {
      final root = Directory.current;
      final proc = await Process.start(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'evil',
      ], workingDirectory: root.path);
      proc.stdin.write('1\n');
      await proc.stdin.close();
      final err = await proc.stderr.transform(utf8.decoder).join();
      await proc.exitCode;
      expect(err, contains('a\u{FFFD}[31mb\u{FFFD}c'));
      expect(err, isNot(contains('\x1b')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('setTotal fills in a total that arrives later; log prints above', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'total',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('T 2/4'));
      expect(res.stderr, contains('logged above\n'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('null total means unknown, like 0', () async {
      final bar = Console.bar(null, label: 'U');
      bar.tick(11);
      await bar.close();
    });

    test('K2: a pipeline that fails before the bar runs frees the line',
        () async {
      final bar = Console.bar(5, label: 'stuck?');
      await expectLater(
        _Mem('hello') | bar > _ThrowBeforeRead(),
        throwsA(isA<ArgumentError>()),
      );
      // The line must be free: the next bar builds without StateError.
      final next = Console.bar(1, label: 'free');
      await next.close();
    });

    test('unknown totals count up', () async {
      final bar = Console.bar(0);
      bar.tick();
      bar.tick(10);
      await bar.close();
    });

    test('close is idempotent', () async {
      final bar = Console.bar(1);
      await bar.close();
      await bar.close();
    });

    test('a second live line is a StateError', () async {
      final bar = Console.bar(1);
      expect(() => Console.bar(2), throwsStateError);
      expect(() => Console.spin('x', Future<void>.value()), throwsStateError);
      await bar.close();
      final ok = Console.bar(1);
      await ok.close();
    });

    test('as a Pipe it counts bytes and closes itself', () async {
      final bar = Console.bar(5, label: 'P');
      final out = await (_Mem('hello') | bar).bytes();
      expect(out, utf8.encode('hello'));
      await bar.close(); // already closed by the pipe: no-op
    });

    test('a failed run prints and rethrows', () async {
      final bar = Console.bar(5);
      await expectLater(
        _Mem('x') | bar | _Boom() > null,
        throwsStateError,
      );
    });

    test('works in a download pipeline', () async {
      final file = File('${Directory.systemTemp.path}/bar_pipe.bin');
      try {
        final hash = Hash.sha256();
        await (_Mem('0123456789') | Console.bar(10) | hash > _Writer(file));
        expect(hash.hex().length, 64);
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
  });

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
Future<String> _ptyBar({required int cols}) async {
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
    '${Directory.systemTemp.path}/probe_nosuch.log', 'bar',
  ], workingDirectory: root.path, stdoutEncoding: null);
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

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(utf8.encode(_text));
}

final class _Boom implements Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    await for (final _ in input) {
      throw StateError('boom');
    }
  }

  @override
  void abort(Object error) {}
}

final class _Writer implements Writer {
  _Writer(this._file);
  final File _file;
  @override
  Future<void> consume(Stream<List<int>> input) async {
    final sink = _file.openWrite();
    await sink.addStream(input);
    await sink.close();
  }
}

/// Fails before ever listening (an unopenable target).
final class _ThrowBeforeRead implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    throw ArgumentError('cannot open target');
  }
}
