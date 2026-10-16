import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/src/format.dart' as fmt;
import 'package:dart_toolkit/src/progress.dart' show Run;
import 'package:dart_toolkit/src/terminal.dart' as term;
import 'package:test/test.dart';

import 'support/capture.dart';
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

  group('rate window', () {
    test('follows a change within about a second, not a 5 s average', () {
      var now = 0;
      final w = fmt.Window(() => now);
      expect(w.rate(), 0);
      void steady(int perStep, int ms) {
        for (final end = now + ms; now < end; now += 100) {
          w.add(perStep);
        }
      }

      steady(100, 3000); // 1000 per second for 3 s
      expect(w.rate(), closeTo(1000, 50));
      steady(500, 1000); // jumps to 5000 per second
      final after1s = w.rate();
      expect(after1s, greaterThan(3000), reason: 'a 5 s average would still read ~2300');
      steady(500, 2000);
      expect(w.rate(), closeTo(5000, 400));
      w.add(-500); // a counter that went back
      now += 5000;
      expect(w.rate(), 0, reason: 'idle for 5 s');
    });

    test('the first steps are not dragged towards zero', () {
      var now = 0;
      final w = fmt.Window(() => now);
      w.add(200);
      now = 100;
      w.add(200);
      now = 200;
      expect(w.rate(), closeTo(2000, 1));
    });
  });

  group('Meter', () {
    test('as a probe it learns the total and counts the run', () async {
      final m = Meter();
      final out = await (Reader.of(utf8.encode('hello')) & m).bytes();
      expect(utf8.decode(out), 'hello');
      expect((m.done(), m.total()), (5, 5));
    });

    test('sums the runs it watches; replayed resume bytes skip the rate', () async {
      final m = Meter();
      final a = Run([m]);
      await a.count(Stream.value(utf8.encode('hello')), total: 5, replay: 3).drain<void>();
      expect((m.done(), m.total()), (5, 5));
      expect(m.rate(), lessThanOrEqualTo(20), reason: '2 fresh bytes, not 5');
      final b = Run([m]);
      expect(m.total(), isNull, reason: 'a run with no total yet makes the sum unknown');
      b.report(1, 4, fmt.Unit.bytes);
      expect((m.done(), m.total()), (6, 9));
      b.end();
      a.end();
      expect((m.done(), m.total()), (9, 9), reason: 'a finished run counts as complete');
    });

    test('a meter that follows two kinds of work shows the latest one, not their sum', () {
      final m = Meter();
      Run([m])
        ..report(4000, 4000, fmt.Unit.bytes)
        ..end();
      expect((m.done(), m.total()), (4000, 4000));
      Run([m]).report(1000000, 3000000, fmt.Unit.time);
      expect((m.done(), m.total()), (1000000, 3000000), reason: 'the encode, not bytes + microseconds');
    });

    test('a failed run without a total does not leave the sum unknown', () {
      final m = Meter();
      Run([m])
        ..report(5, null, fmt.Unit.bytes)
        ..end(StateError('x'));
      Run([m])
        ..report(3, 3, fmt.Unit.bytes)
        ..end();
      expect((m.done(), m.total()), (8, 8));
    });

    test('update sets a count by hand', () {
      final m = Meter()..update(3, 10);
      expect((m.done(), m.total()), (3, 10));
    });
  });

  group('probes', () {
    test('a user Probe hears (done, total) summed over its runs', () async {
      final heard = <(int, int?)>[];
      final probe = _Heard(heard);
      await (Reader.of([1, 2, 3]) & probe > null);
      expect(heard, containsAllInOrder([(0, null), (0, 3), (3, 3)]));
      expect(heard.last, (3, 3));
    });

    test('a probe anywhere shows the source: after gzip it still reaches the total', () async {
      final m = Meter();
      final big = List<int>.filled(100000, 7);
      await (Reader.of(big) & m | _Halve() > null);
      expect((m.done(), m.total()), (100000, 100000));
    });

    test('a null probe is skipped', () async {
      expect(await (Reader.of([1]) & null).bytes(), [1]);
      expect(await (Future.value(2) & null), 2);
    });

    test('a probe on a plain future passes its value and its error', () async {
      expect(await (Future.value(42) & Console.bar('Work')), 42);
      await expectLater(Future<void>.error(StateError('bad')) & Console.bar('Work'), throwsStateError);
    });

    test('a probe on a future of a reader watches its bytes, not the request', () async {
      final m = Meter();
      await (Future.value(Reader.of([1, 2, 3, 4])) & m > null);
      expect(m.total(), 4);
    });
  });

  test('notify sends OSC 777 with a title and a body', () {
    expect(term.notifyCodes('done'), matches(RegExp('\x1b]777;notify;[^;\x07]+;done\x07')));
  });

  group('Console.choose', () {
    test('empty items is an ArgumentError', () {
      expect(Console.choose('Pick', <String>[], (s) => s), throwsArgumentError);
    });

    test('an unknown keys binding is an ArgumentError, before any prompt', () {
      expect(Console.choose('Pick', ['a', 'b'], (s) => s, keys: {'notakey-xyz': 'a'}), throwsArgumentError);
    });

    test('an initial that is not an item is an ArgumentError', () {
      expect(Console.choose('Pick', ['a', 'b'], (s) => s, or: 'z'), throwsArgumentError);
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
      final p = await startDart('''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  final a = await Console.ask('first?');
  print('got \$a');
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final b = await Console.ask('second?');
  print('a=\$a b=\$b');
}
''');
      final lines = linesOf(p);
      p.stdin.write('one\n');
      await lines.firstWhere((l) => l == 'got one').timeout(const Duration(seconds: 30));
      p.stdin.write('two\n'); // during the 600 ms between the prompts
      await p.stdin.close();
      expect(await lines.firstWhere((l) => l.startsWith('a=')), 'a=one b=two');
      expect(await p.exitCode, 0);
    });
  });

  group('piped stdin, async', () {
    test('ask on piped stdin keeps timers running while it waits', () async {
      final p = await startDart('''
import 'dart:async';
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  var ticks = 0;
  final t = Timer.periodic(const Duration(milliseconds: 20), (_) => ticks++);
  print('asking');
  final a = await Console.ask('first?');
  t.cancel();
  print('a=\$a ticks=\${ticks > 5}');
}
''');
      final lines = linesOf(p);
      await lines.firstWhere((l) => l == 'asking').timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 400)); // ticks while the ask waits
      p.stdin.write('one\n');
      await p.stdin.close();
      expect(await lines.firstWhere((l) => l.startsWith('a=')), 'a=one ticks=true');
      expect(await p.exitCode, 0);
    });
  });

  group('exit hooks', () {
    test('a second SIGINT during cleanup exits at once', () async {
      if (Platform.isWindows) return markTestSkipped('needs POSIX signals');
      final p = await startDart('''
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
      final lines = linesOf(p);
      await lines.firstWhere((l) => l == 'ready').timeout(const Duration(seconds: 30));
      p.kill(ProcessSignal.sigint);
      await lines.firstWhere((l) => l == 'cleaning').timeout(const Duration(seconds: 10));
      final sw = Stopwatch()..start();
      p.kill(ProcessSignal.sigint);
      // The hook would hold the exit for its 5 s bound.
      expect(await p.exitCode.timeout(const Duration(seconds: 20)), 130);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    }, timeout: const Timeout(Duration(seconds: 60)), tags: 'slow');
  });

  group('prompts time out', () {
    test('confirm, choose and key give their or when nobody answers', () async {
      final p = await startDart('''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  final t = 300.milliseconds;
  print('confirm=\${await Console.confirm('ok?', or: true, timeout: t)}');
  print('choose=\${await Console.choose('pick', ['a', 'b'], (s) => s, or: 'b', timeout: t)}');
  print('key=\${await Console.key('', or: 'none', timeout: t)}');
}
''');
      final out = await p.stdout.transform(utf8.decoder).join(); // stdin stays open: nobody answers
      expect(await p.exitCode.timeout(const Duration(seconds: 30)), 0);
      expect(out, 'confirm=true\nchoose=b\nkey=none\n');
    });
  });

  test('Console.log(failed:) marks the line; Console.logged() is the run\'s log as content', () async {
    final r = await runDart('''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  Console.log('one');
  Console.log('two', failed: true);
  print(await Console.logged().text());
}
''');
    expect(r.stderr, 'one\n✗ two\n');
    expect(r.stdout, matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  one\n\S+ \S+  ✗ two\n')));
  });

  group('stdin and stdout', () {
    test('Console.input() and out() make a script a filter', () async {
      final r = await runDart(
        '''
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async => Console.input() | Shell.filter(['sort']) > Console.out();
''',
        stdin: [(Duration.zero, 'b\na\nc\n')],
      );
      expect(r.exitCode, 0, reason: r.stderr as String);
      expect(r.stdout, 'a\nb\nc\n');
    }, testOn: '!windows');
  });

  group('Bar', () {
    test('a bar ticked to its total closes itself; a second one may start', () async {
      final first = Console.bar('items', total: 3);
      for (var i = 0; i < 3; i++) {
        first.tick();
      }
      await Future<void>.delayed(Duration.zero);
      final second = Console.bar('', total: 2)..tick(2);
      await Future<void>.delayed(Duration.zero);
      expect(() => Console.bar('', total: 1)..tick(), returnsNormally);
      await second.close();
    });

    test('two live bars may run at once', () async {
      final run = await capture(() async {
        final open = Console.bar('A', total: 10);
        final other = Console.bar('B', total: 5)..tick();
        await other.close();
        await open.close();
      });
      expect(run.err, 'B 1/5\nA 0/10\n');
    });

    test('tick counts past the total and returns the bar', () async {
      final run = await capture(() async {
        final bar = Console.bar('T', total: 3);
        expect(identical(bar.tick(), bar), isTrue);
        bar.tick(5);
        await bar.close();
      });
      expect(run.err, 'T 6/3\n');
    });

    test('L3: counts past the total are kept, negative ticks ignored', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'over',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('5/3'));
    }, timeout: const Timeout(Duration(seconds: 60)), tags: 'slow');

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
    }, timeout: const Timeout(Duration(seconds: 60)), tags: 'slow');

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
    }, timeout: const Timeout(Duration(seconds: 60)), tags: 'slow');

    test('update fills in a total that arrives later; log prints above', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'total',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('T 2/4'));
      expect(res.stderr, contains('logged above\n'));
    }, timeout: const Timeout(Duration(seconds: 60)), tags: 'slow');

    test('no total means unknown, like 0', () async {
      final run = await capture(() async {
        final bar = Console.bar('U');
        bar.tick(11);
        await bar.close();
      });
      expect(run.err, startsWith('U 11 '));
    });

    test('K2: a pipeline that fails before the bar runs frees the line', () async {
      final bar = Console.bar('stuck?');
      await expectLater(_Mem('hello') & bar > _ThrowBeforeRead(), throwsA(isA<ArgumentError>()));
      // The line must be free: the next bar builds without StateError.
      final next = Console.bar('free', total: 1);
      await next.close();
    });

    test('unknown totals count up', () async {
      final run = await capture(() async {
        final bar = Console.bar('Z', total: 0);
        bar.tick();
        bar.tick(10);
        await bar.close();
      });
      expect(run.err, startsWith('Z 11 '));
    });

    test('close is idempotent', () async {
      final run = await capture(() async {
        final bar = Console.bar('C', total: 1);
        await bar.close();
        await bar.close();
      });
      expect(run.err, 'C 0/1\n');
    });

    test('parallel watched futures and a bar print one line each when piped', () async {
      final r = await runDart('''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  final bar = Console.bar('outer', total: 2);
  await Future.wait([
    Future<void>.delayed(const Duration(milliseconds: 50)) & Console.bar('one'),
    Future<void>.delayed(const Duration(milliseconds: 10)) & Console.bar('two'),
  ]);
  bar.tick(2);
}
''');
      expect(r.exitCode, 0, reason: r.stderr as String);
      expect(r.stderr, '✓ two\n✓ one\nouter 2/2\n');
    });

    test('as a probe it counts bytes and closes itself', () async {
      final bar = Console.bar('P');
      final out = await (_Mem('hello') & bar).bytes();
      expect(out, utf8.encode('hello'));
      await bar.close(); // already closed by the pipe: no-op
    });

    test('a failed run prints and rethrows', () async {
      final bar = Console.bar('');
      await expectLater(_Mem('x') & bar | _Boom() > null, throwsStateError);
    });

    test('works in a download pipeline', () async {
      final dir = await Directory.systemTemp.createTemp('bar_pipe');
      addTearDown(() => dir.delete(recursive: true));
      final hash = Hash.sha256();
      await (_Mem('0123456789') & Console.bar('') | hash > _Writer(File('${dir.path}/out.bin')));
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

/// A user's own probe: what it heard.
final class _Heard with Probe {
  _Heard(this._heard);
  final List<(int, int?)> _heard;
  @override
  void update(int done, int? total) => _heard.add((done, total));
}

/// A transforming pipe: half the bytes come out (like a compressor).
final class _Halve with Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) => input.map((c) => c.sublist(0, c.length ~/ 2));
}
