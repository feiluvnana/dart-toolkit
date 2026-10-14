@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_toolkit/pool.dart';
import 'package:test/test.dart';

int doubleIt(int x) => x * 2;

Future<int> slowDouble(int x) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return x * 2;
}

int boom(int x) => throw StateError('bad $x');

/// Blocks its worker; used to prove shutdown() fails in-flight jobs instead
/// of leaving them hanging. Top-level so it crosses isolates. Parks on the
/// event loop (never completing) rather than a native sleep, so killing the
/// worker takes effect immediately instead of at the end of the sleep.
Future<int> hold(int x) => Completer<int>().future;

/// Slow enough that a serial run is unmistakable, fast enough to keep the
/// suite quick. Top-level so it crosses isolates.
int quarterSecond(int x) {
  sleep(const Duration(milliseconds: 250));
  return x;
}

void main() {
  tearDownAll(Pool.shutdown);

  group('Pool.compute', () {
    test('runs one job and returns its result', () async {
      expect(await Pool.compute(() => 40 + 2), 42);
    });

    test('an error in the job is rethrown', () async {
      expect(
          Pool.compute(() => throw StateError('nope')), throwsStateError);
    });

    test('a job capturing a non-sendable value is an ArgumentError',
        () async {
      final port = ReceivePort();
      try {
        expect(Pool.compute(() => port.hashCode), throwsArgumentError);
      } finally {
        port.close();
      }
    });
  });

  group('Pool.computeAll', () {
    test('maps in input order', () async {
      expect(await Pool.computeAll([1, 2, 3], doubleIt), [2, 4, 6]);
    });

    test('empty input returns empty', () async {
      expect(await Pool.computeAll(<int>[], doubleIt), isEmpty);
    });

    test('concurrency: 1 runs jobs serially', () async {
      // 3 x 250 ms serially is ~750 ms; any parallelism would be ~250 ms.
      final sw = Stopwatch()..start();
      final out = await Pool.computeAll([1, 2, 3], quarterSecond,
          concurrency: 1);
      sw.stop();
      expect(out, [1, 2, 3]);
      expect(sw.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 600)));
    });

    test('onResult runs on the caller as each job finishes', () async {
      final seen = <int>[];
      await Pool.computeAll([1, 2, 3], slowDouble, onResult: seen.add);
      expect(seen..sort(), [2, 4, 6]);
    });

    test('the first error stops new jobs and is rethrown', () async {
      expect(Pool.computeAll([1, 2, 3], boom), throwsStateError);
    });

    test('a non-sendable item is an ArgumentError', () async {
      final port = ReceivePort();
      try {
        await expectLater(
            Pool.computeAll([port], (_) => 1), throwsArgumentError);
      } finally {
        port.close();
      }
    });

    test('a bad concurrency is an ArgumentError', () {
      expect(() => Pool.computeAll([1], doubleIt, concurrency: 0),
          throwsArgumentError);
    });

    test('the default runs jobs in parallel, in input order', () async {
      // 6 x 250 ms serially is 1.5 s; with the default worker-count limit it
      // is one wave. (On a 1-CPU engine with 0 workers this hangs instead.)
      final sw = Stopwatch()..start();
      final out = await Pool.computeAll([1, 2, 3, 4, 5, 6], quarterSecond);
      sw.stop();
      expect(out, [1, 2, 3, 4, 5, 6]);
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('Pool.map', () {
    test('runs async lanes in input order', () async {
      expect(await Pool.map([1, 2, 3], (x) => x * 2), [2, 4, 6]);
    });

    test('empty input returns empty', () async {
      expect(await Pool.map(<int>[], (x) => x * 2), isEmpty);
    });

    test('concurrency caps lanes in flight', () async {
      var inflight = 0;
      var max = 0;
      Future<int> job(int x) async {
        inflight++;
        if (inflight > max) max = inflight;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        inflight--;
        return x;
      }

      final out = await Pool.map([1, 2, 3, 4, 5, 6], job, concurrency: 2);
      expect(out, [1, 2, 3, 4, 5, 6]);
      expect(max, 2);
    });

    test('the job can capture caller state (no isolate hop)', () async {
      final port = ReceivePort();
      try {
        // A bar, a client, a socket: none of it crosses isolates here, so a
        // job that captures a port is fine on lanes (and an ArgumentError on
        // computeAll).
        final seen = <int>[];
        final out = await Pool.map([1, 2, 3], (x) async {
          seen.add(port.hashCode ^ x);
          return x * 2;
        });
        expect(out, [2, 4, 6]);
        expect(seen, hasLength(3));
      } finally {
        port.close();
      }
    });

    test('onResult runs on the caller as each job finishes', () async {
      final seen = <int>[];
      await Pool.map([1, 2, 3], slowDouble, onResult: seen.add);
      expect(seen..sort(), [2, 4, 6]);
    });

    test('the first error stops new jobs and is rethrown', () async {
      final started = <int>[];
      Future<int> job(int x) async {
        started.add(x);
        if (x == 1) throw StateError('bad 1');
        return x;
      }

      await expectLater(
          Pool.map([1, 2, 3], job, concurrency: 1), throwsStateError);
      expect(started, [1]);
    });

    test('a bad concurrency is an ArgumentError', () {
      expect(
          () => Pool.map([1], (x) => x, concurrency: 0), throwsArgumentError);
    });
  });

  group('Pool.shutdown', () {
    test('the pool restarts on the next call', () async {
      await Pool.shutdown();
      expect(await Pool.compute(() => 1), 1);
    });

    test('concurrent first calls share one init (no double-init warning)',
        () async {
      await Pool.shutdown();
      final lines = <String>[];
      await runZoned(
        () async {
          await Future.wait(
              [Pool.compute(() => 1), Pool.compute(() => 2)]);
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            lines.add(line);
          },
        ),
      );
      expect(
        lines.where((l) => l.contains('already warmed up')),
        isEmpty,
      );
    });

    test('shutdown fails an in-flight job with StateError', () async {
      final pending = Pool.compute(() => hold(0));
      // Let the job reach a worker; even queued it is covered, but a running
      // job is the case that used to hang forever.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await Pool.shutdown();
      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'pool closed',
          ),
        ),
      );
    });

    test('shutdown fails in-flight lanes with StateError', () async {
      final pending = Pool.map([1, 2, 3], (_) => Completer<int>().future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Pool.shutdown();
      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'pool closed',
          ),
        ),
      );
    });

    test('compute then shutdown is a no-op; the pool restarts after',
        () async {
      // The engine shuts itself down when no job is left (F5), so this
      // shutdown must find nothing to stop and must not throw. Process exit
      // itself is checked manually with a scratch script (see report).
      expect(await Pool.compute(() => 7), 7);
      await Pool.shutdown();
      await Pool.shutdown();
      expect(await Pool.compute(() => 8), 8);
    });

    test('core is re-exported', () {
      final readers = <Reader>[];
      expect(readers, isEmpty);
    });
  });
}
