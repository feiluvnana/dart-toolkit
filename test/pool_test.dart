@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_toolkit/pool.dart';
import 'package:test/test.dart';

import 'support/child.dart';

int doubleIt(int x) => x * 2;

Future<int> slowDouble(int x) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return x * 2;
}

int boom(int x) => throw StateError('bad $x');

/// Slow enough that a serial run is unmistakable, fast enough to keep the
/// suite quick. Top-level so it crosses isolates.
int quarterSecond(int x) {
  sleep(const Duration(milliseconds: 250));
  return x;
}

void main() {

  group('Pool.runAll', () {
    test('maps in input order', () async {
      expect(await Pool.runAll([1, 2, 3], doubleIt), [2, 4, 6]);
    });

    test('empty input returns empty', () async {
      expect(await Pool.runAll(<int>[], doubleIt), isEmpty);
    });

    test('limit: 1 runs jobs serially', () async {
      // 3 x 250 ms serially is ~750 ms; any parallelism would be ~250 ms.
      final sw = Stopwatch()..start();
      final out = await Pool.runAll([1, 2, 3], quarterSecond, limit: 1);
      sw.stop();
      expect(out, [1, 2, 3]);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 600)));
    });

    test('onResult runs on the caller as each job finishes', () async {
      final seen = <int>[];
      await Pool.runAll([1, 2, 3], slowDouble, onResult: seen.add);
      expect(seen..sort(), [2, 4, 6]);
    });

    test('the first error stops new jobs and is rethrown', () async {
      expect(Pool.runAll([1, 2, 3], boom), throwsStateError);
    });

    test('a non-sendable item is an ArgumentError', () async {
      final port = ReceivePort();
      try {
        await expectLater(Pool.runAll([port], (_) => 1), throwsArgumentError);
      } finally {
        port.close();
      }
    });

    test('a bad limit is an ArgumentError', () {
      expect(() => Pool.runAll([1], doubleIt, limit: 0), throwsArgumentError);
    });

    test('the default runs jobs in parallel, in input order', () async {
      // 6 x 250 ms serially is 1.5 s; with the default worker-count limit it
      // is one wave. (On a 1-CPU engine with 0 workers this hangs instead.)
      final sw = Stopwatch()..start();
      final out = await Pool.runAll([1, 2, 3, 4, 5, 6], quarterSecond);
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

    test('limit caps lanes in flight', () async {
      var inflight = 0;
      var max = 0;
      Future<int> job(int x) async {
        inflight++;
        if (inflight > max) max = inflight;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        inflight--;
        return x;
      }

      final out = await Pool.map([1, 2, 3, 4, 5, 6], job, limit: 2);
      expect(out, [1, 2, 3, 4, 5, 6]);
      expect(max, 2);
    });

    test('the job can capture caller state (no isolate hop)', () async {
      final port = ReceivePort();
      try {
        // A bar, a client, a socket: none of it crosses isolates here, so a
        // job that captures a port is fine on lanes (and an ArgumentError on
        // runAll).
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

      await expectLater(Pool.map([1, 2, 3], job, limit: 1), throwsStateError);
      expect(started, [1]);
    });

    test('a bad limit is an ArgumentError', () {
      expect(() => Pool.map([1], (x) => x, limit: 0), throwsArgumentError);
    });
  });

  group('Pool', () {
    test('core is re-exported', () {
      final readers = <Reader>[];
      expect(readers, isEmpty);
    });
    test('a script that used workers exits by itself', () async {
      final r = await runDart('''
import 'package:dart_toolkit/pool.dart';
int sq(int x) => x * x;
Future<void> main() async => print(await Pool.runAll([1, 2, 3], sq));
''');
      expect(r.exitCode, 0);
      expect('${r.stdout}'.trim(), '[1, 4, 9]');
    });
  });
}
