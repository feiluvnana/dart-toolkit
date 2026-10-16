import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/src/format.dart' as fmt;
import 'package:dart_toolkit/src/resume.dart' show replays;
import 'package:dart_toolkit/src/terminal.dart' as term;
import 'package:test/test.dart';

import 'support/child.dart';

void main() {
  test('Console.table aligns by cell width, numbers right, plain when piped', () async {
    final r = await runDart('''
import 'package:dart_toolkit/console.dart';
void main() => Console.table([['日本', 3, null], ['abc', 120, 'x']], header: ['name', 'n', 'note']);
''');
    expect(r.stdout, 'name  n    note\n日本    3\nabc   120  x\n');
  });

  test('Console.table: colour takes no cells and a tab is a space', () async {
    final r = await runDart(r'''
import 'package:dart_toolkit/console.dart';
void main() => Console.table([['\x1b[32mok\x1b[0m', 'a'], ['x\ty', 'b'], ['long', 'c']]);
''');
    expect(r.stdout, '\x1b[32mok\x1b[0m    a\nx y   b\nlong  c\n');
  });

  group('Speed', () {
    test('counts over a 5 s window; negative deltas are ignored', () {
      var now = 0;
      final m = fmt.Meter(() => now);
      expect(m.rate(), 0);
      m.add(1000);
      m.add(-500); // a counter that went back
      now = 2000;
      m.add(1000);
      expect(m.rate(), 1000); // 2000 bytes over 2 s
      now = 10000;
      expect(m.rate(), 0, reason: 'idle past the window');
    });

    test('as a pipe it passes bytes and leaves out replayed resume bytes', () async {
      final speed = Speed();
      replays[speed]!(3); // the resume path: 3 bytes come back from the .part
      final out = await (_Mem('hello') | speed).bytes();
      expect(utf8.decode(out), 'hello');
      expect(speed.rate(), 2, reason: '2 fresh bytes over the 1 s floor');
      expect(speed.add(-4).rate(), 2);
    });
  });

  test('notify sends OSC 777 with a title and a body', () {
    expect(term.notifyCodes('done'), matches(RegExp('\x1b]777;notify;[^;\x07]+;done\x07')));
  });

  group('Console.choose', () {
    test('empty items is an ArgumentError', () {
      expect(Console.choose('Pick', <String>[], label: (s) => s), throwsArgumentError);
    });

    test('an unknown keys binding is an ArgumentError, before any prompt', () {
      expect(Console.choose('Pick', ['a', 'b'], label: (s) => s, keys: {'notakey-xyz': 'a'}), throwsArgumentError);
    });

    test('an initial that is not an item is an ArgumentError', () {
      expect(Console.choose('Pick', ['a', 'b'], label: (s) => s, or: 'z'), throwsArgumentError);
    });
  });

  test('confirm on stdin from /dev/null gives its default instead of hanging', () async {
    final dir = await Directory.systemTemp.createTemp('devnull');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/main.dart').writeAsString('''
import 'package:dart_toolkit/console.dart';
Future<void> main() async => print('answer=\${await Console.confirm('ok?')}');
''');
    final packages = '${Directory.current.path}/.dart_tool/package_config.json';
    final r = await Process.run('/bin/sh', [
      '-c',
      '"${Platform.resolvedExecutable}" --packages="$packages" "${dir.path}/main.dart" < /dev/null',
    ]).timeout(const Duration(seconds: 20));
    expect(r.stdout, contains('answer=false'));
  }, testOn: '!windows');

  group('piped stdin', () {
    test('a line that arrives between prompts is kept', () async {
      final r = await runDart(
        '''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  final a = await Console.ask('first?');
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final b = await Console.ask('second?');
  print('a=\$a b=\$b');
}
''',
        stdin: const [(Duration.zero, 'one\n'), (Duration(milliseconds: 200), 'two\n')],
      );
      expect(r.stdout, contains('a=one b=two'));
      expect(r.exitCode, 0);
    });
  });

  group('piped stdin, async', () {
    test('ask on piped stdin keeps timers running while it waits', () async {
      final r = await runDart(
        '''
import 'dart:async';
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  var ticks = 0;
  final t = Timer.periodic(const Duration(milliseconds: 20), (_) => ticks++);
  final a = await Console.ask('first?');
  t.cancel();
  print('a=\$a ticks=\${ticks > 5}');
}
''',
        stdin: const [(Duration(milliseconds: 600), 'one\n')],
      );
      expect(r.stdout, contains('a=one ticks=true'));
      expect(r.exitCode, 0);
    });
  });

  group('exit hooks', () {
    test('a second SIGINT during cleanup exits at once', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX signals');
      final dir = await Directory.systemTemp.createTemp('sig2');
      addTearDown(() => dir.delete(recursive: true));
      final script = File('${dir.path}/main.dart')
        ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
import 'package:dart_toolkit/src/exit.dart' as exit;
Future<void> main() async {
  exit.onExit(() async {
    stdout.writeln('cleaning');
    await Future<void>.delayed(const Duration(seconds: 30));
  });
  stdout.writeln('ready');
  await Future<void>.delayed(const Duration(seconds: 60));
}
''');
      final p = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        script.path,
      ]);
      final lines = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
      await lines.firstWhere((l) => l == 'ready').timeout(const Duration(seconds: 30));
      p.kill(ProcessSignal.sigint);
      await lines.firstWhere((l) => l == 'cleaning').timeout(const Duration(seconds: 10));
      final sw = Stopwatch()..start();
      p.kill(ProcessSignal.sigint);
      // The hook would hold the exit for its 5 s bound.
      expect(await p.exitCode.timeout(const Duration(seconds: 20)), 130);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('Console.spin', () {
    test('returns the work result', () async {
      expect(await Console.spin('Work', Future.value(42)), 42);
    });

    test('rethrows the work error', () async {
      expect(Console.spin<void>('Work', Future.error(StateError('bad'))), throwsStateError);
    });
  });

  group('Bar', () {
    test('a bar ticked to its total closes itself; a second one may start', () async {
      final first = Console.bar(3, label: 'items');
      for (var i = 0; i < 3; i++) {
        first.tick();
      }
      await Future<void>.delayed(Duration.zero);
      final second = Console.bar(2)..tick(2);
      await Future<void>.delayed(Duration.zero);
      expect(() => Console.bar(1)..tick(), returnsNormally);
      await second.close();
    });

    test('two live bars may run at once', () async {
      final open = Console.bar(10);
      final other = Console.bar(5)..tick();
      await other.close();
      await open.close();
    });

    test('tick counts and stops at the total, returns the bar', () async {
      final bar = Console.bar(3, label: 'T');
      expect(identical(bar.tick(), bar), isTrue);
      bar.tick(5);
      await bar.close();
    });

    test('L3: counts past the total are kept, negative ticks ignored', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'over',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('5/3'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('keep: false leaves no final line; a failure still prints', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'keep',
      ], workingDirectory: root.path);
      expect(res.stdout, contains('done'));
      expect(res.stderr, contains('kept 2/2'));
      expect(res.stderr, isNot(contains('gone')));
      expect(res.stderr, contains('broken'));
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

    test('update fills in a total that arrives later; log prints above', () async {
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

    test('K2: a pipeline that fails before the bar runs frees the line', () async {
      final bar = Console.bar(5, label: 'stuck?');
      await expectLater(_Mem('hello') | bar > _ThrowBeforeRead(), throwsA(isA<ArgumentError>()));
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

    test('parallel spins and a spin inside a bar print one line each when piped', () async {
      final r = await runDart('''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  final bar = Console.bar(2, label: 'outer');
  await Future.wait([
    Console.spin('one', Future<void>.delayed(const Duration(milliseconds: 50))),
    Console.spin('two', Future<void>.delayed(const Duration(milliseconds: 10))),
  ]);
  bar.tick(2);
}
''');
      expect(r.exitCode, 0, reason: r.stderr as String);
      expect(r.stderr, '✓ two\n✓ one\nouter 2/2\n');
    });

    test('as a Pipe it counts bytes and closes itself', () async {
      final bar = Console.bar(5, label: 'P');
      final out = await (_Mem('hello') | bar).bytes();
      expect(out, utf8.encode('hello'));
      await bar.close(); // already closed by the pipe: no-op
    });

    test('a failed run prints and rethrows', () async {
      final bar = Console.bar(5);
      await expectLater(_Mem('x') | bar | _Boom() > null, throwsStateError);
    });

    test('works in a download pipeline', () async {
      final dir = await Directory.systemTemp.createTemp('bar_pipe');
      addTearDown(() => dir.delete(recursive: true));
      final hash = Hash.sha256();
      await (_Mem('0123456789') | Console.bar(10) | hash > _Writer(File('${dir.path}/out.bin')));
      expect(hash.hex().length, 64);
    });
  });
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

final class _Writer with Writer {
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
final class _ThrowBeforeRead with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    throw ArgumentError('cannot open target');
  }
}
