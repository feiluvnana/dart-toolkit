import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/process.dart';
import 'package:test/test.dart';

/// One counted job: posts its id on start and on end, answers its id.
Future<int> _job(({SendPort port, int id}) job) async {
  await Chan.post(job.port, job.id);
  final end = DateTime.now().add(const Duration(milliseconds: 50));
  while (DateTime.now().isBefore(end)) {}
  await Chan.post(job.port, -job.id);
  return job.id;
}

/// A job whose failure never reaches its own future: it kills the isolate
/// after scheduling one, so the error is uncaught at the isolate level.
Future<int> _stray() async {
  await Future<void>.delayed(Duration.zero);
  unawaited(Future<void>.delayed(Duration.zero).then((_) => throw FormatException('stray')));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return 1;
}

void main() {
  test('Task.run of a busy loop does not block a timer', () async {
    var timerFired = false;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 10)).then((_) => timerFired = true));
    await Task.run(() {
      final end = DateTime.now().add(const Duration(milliseconds: 300));
      while (DateTime.now().isBefore(end)) {}
    });
    expect(timerFired, isTrue);
  });

  test('Task.run(timeout:) throws TimeoutException', () async {
    await expectLater(
      Task.run(() {
        final end = DateTime.now().add(const Duration(milliseconds: 300));
        while (DateTime.now().isBefore(end)) {}
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('Pool.map keeps order with bounded concurrency', () async {
    final chan = Chan<int>(10);
    final running = <int>{};
    var maxRunning = 0;
    Future<void> drain() async {
      await for (final id in chan.recv()) {
        if (id >= 0) {
          running.add(id);
          maxRunning = max(maxRunning, running.length);
        } else {
          running.remove(-id);
        }
      }
    }

    final pool = Pool(2);
    final draining = drain();
    final ids = await pool.map([for (var i = 1; i <= 6; i++) (port: chan.port, id: i)], _job);
    await pool.close();
    await chan.close();
    await draining;
    expect(ids, [1, 2, 3, 4, 5, 6]);
    expect(maxRunning, lessThanOrEqualTo(2));
    expect(maxRunning, greaterThan(1));
    expect(running, isEmpty);
  });

  test('a bounded Chan never holds more than cap', () async {
    final chan = Chan<int>(3);
    await chan.send(1);
    await chan.send(2);
    await chan.send(3);
    var fourthDone = false;
    unawaited(chan.send(4).then((_) => fourthDone = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fourthDone, isFalse);
    final seen = <int>[];
    await for (final v in chan.recv()) {
      seen.add(v);
      if (seen.length == 4) break;
    }
    expect(seen, [1, 2, 3, 4]);
    expect(fourthDone, isTrue);
    await chan.close();
  });

  test('recv() ends when close() is called', () async {
    final chan = Chan<int>(10);
    await chan.send(1);
    final seen = <int>[];
    await for (final v in chan.recv()) {
      seen.add(v);
      await chan.close();
    }
    expect(seen, [1]);
  });

  group('Task.all', () {
    test('answers in item order, at most concurrency at once, with progress', () async {
      var running = 0;
      var peak = 0;
      final seen = <(int, int)>[];
      final out = await Task.all(
        [5, 1, 4, 2, 3],
        (int n) async {
          peak = max(peak, ++running);
          await Future<void>.delayed(Duration(milliseconds: n * 5));
          running--;
          return n * 10;
        },
        concurrency: 2,
        onProgress: (done, total) => seen.add((done, total)),
      );
      expect(out, [50, 10, 40, 20, 30]);
      expect(peak, 2);
      expect(seen.first, (0, 5));
      expect(seen.last, (5, 5));
    });

    test('the first failure stops new items and is rethrown', () async {
      final started = <int>[];
      await expectLater(
        Task.all([1, 2, 3, 4], (int n) async {
          started.add(n);
          if (n == 1) throw StateError('boom');
          return n;
        }, concurrency: 1),
        throwsA(isA<StateError>()),
      );
      expect(started, [1]);
    });

    test('nothing to do answers an empty list and reports 0 of 0', () async {
      final seen = <(int, int)>[];
      expect(await Task.all(<int>[], (int n) => n, onProgress: (d, t) => seen.add((d, t))), isEmpty);
      expect(seen, [(0, 0)]);
    });
  });

  group('hang and leak regressions', () {
    test('Task.run of an unsendable result throws StateError', () async {
      await expectLater(Task.run(() => ReceivePort()), throwsA(isA<StateError>()));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('Task.run of an uncaught async error throws StateError', () async {
      await expectLater(Task.run(_stray), throwsA(isA<StateError>()));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('a script with a crashed pool worker exits after close()', () async {
      final dir = await io.Directory.systemTemp.createTemp('poolcrash_');
      try {
        io.File('${dir.path}/crash.dart').writeAsStringSync('''
import 'dart:isolate';
import 'package:dart_toolkit/async.dart';
Never die() { Isolate.exit(); }
Future<void> main() async {
  final pool = Pool(1);
  try {
    await pool.run(die);
  } catch (_) {}
  await pool.close();
}
''');
        final pkgConfig = '${io.Directory.current.path}/.dart_tool/package_config.json';
        final probe = Process(io.Platform.executable, ['--packages=$pkgConfig', '${dir.path}/crash.dart']);
        expect(await probe.check(), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('Chan<int?> keeps null items', () async {
      final chan = Chan<int?>(10);
      await chan.send(null);
      await chan.send(1);
      await chan.close();
      expect(await chan.recv().toList(), [null, 1]);
    });

    test('post after close answers false instead of hanging', () async {
      final chan = Chan<int>(10);
      final port = chan.port;
      await chan.close();
      expect(await Chan.post(port, 1, wait: false), isFalse);
      await expectLater(Chan.post(port, 2), throwsA(isA<StateError>()));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('cancelling recv neither hangs nor swallows the next send', () async {
      final chan = Chan<int>(10);
      final sub = chan.recv().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      await chan.send(7);
      expect(await chan.recv().first, 7);
      await chan.close();
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('Chan(0) is an ArgumentError', () async {
      expect(() => Chan<int>(0), throwsArgumentError);
    });
  });
}
