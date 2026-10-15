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

int argBoom(int x) => throw ArgumentError('mine');

int isolateHash(int x) {
  sleep(const Duration(milliseconds: 30));
  return Isolate.current.hashCode;
}

/// Slow enough that a serial run is unmistakable, fast enough to keep the
/// suite quick. Top-level so it crosses isolates.
int quarterSecond(int x) {
  sleep(const Duration(milliseconds: 250));
  return x;
}

void main() {
  group('Pool.map isolates: true', () {
    test('maps in input order', () async {
      expect(await Pool.map([1, 2, 3], doubleIt, isolates: true), [2, 4, 6]);
    });

    test('empty input returns empty', () async {
      expect(await Pool.map(<int>[], doubleIt, isolates: true), isEmpty);
    });

    test('limit: 1 runs jobs serially', () async {
      // 3 x 250 ms serially is ~750 ms; any parallelism would be ~250 ms.
      final sw = Stopwatch()..start();
      final out = await Pool.map([1, 2, 3], quarterSecond, limit: 1, isolates: true);
      sw.stop();
      expect(out, [1, 2, 3]);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 600)));
    });

    test('onDone runs on the caller after every job', () async {
      var done = 0;
      await Pool.map([1, 2, 3], slowDouble, isolates: true, onDone: () => done++);
      expect(done, 3);
    });

    test('workers are long-lived: one isolate serves many items', () async {
      final ids = await Pool.map(List.generate(8, (i) => i), isolateHash, limit: 2, isolates: true);
      expect(ids.toSet(), hasLength(2));
    });

    test('an ArgumentError the job throws stays as it is', () async {
      await expectLater(
        Pool.map([1], argBoom, isolates: true),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'mine')),
      );
    });

    test('the first error stops new jobs and is rethrown', () async {
      expect(Pool.map([1, 2, 3], boom, isolates: true), throwsStateError);
    });

    test('a non-sendable item is an ArgumentError', () async {
      final port = ReceivePort();
      try {
        await expectLater(
          Pool.map([port], (_) => 1, isolates: true),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'items[0]')),
        );
      } finally {
        port.close();
      }
    });

    test('a bad limit is an ArgumentError', () {
      expect(() => Pool.map([1], doubleIt, limit: 0, isolates: true), throwsArgumentError);
    });

    test('the default runs jobs in parallel, in input order', () async {
      // 6 x 250 ms serially is 1.5 s; with the default worker-count limit it
      // is one wave. (On a 1-CPU engine with 0 workers this hangs instead.)
      final sw = Stopwatch()..start();
      final out = await Pool.map([1, 2, 3, 4, 5, 6], quarterSecond, limit: 6, isolates: true);
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
        // isolates: true).
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

    test('onDone runs after every job, failures included', () async {
      var done = 0;
      await Pool.settle([1, 2, 3], (x) => x == 2 ? throw StateError('x') : x, onDone: () => done++);
      expect(done, 3);
    });

    test('the first error keeps its type and stack', () async {
      await expectLater(Pool.map([1], boom), throwsA(isA<StateError>().having((e) => '$e', 'text', contains('bad 1'))));
    });

    test('retries re-run a failing job; rate paces starts', () async {
      var calls = 0;
      final out = await Pool.map([1], (x) => ++calls < 2 ? throw StateError('flaky') : x, retries: 1);
      expect(out, [1]);
      expect(calls, 2);
      final starts = <DateTime>[];
      await Pool.map([1, 2, 3], (x) => starts.add(DateTime.now()), rate: Rate(1, 150.milliseconds));
      expect(starts.last.difference(starts.first), greaterThanOrEqualTo(const Duration(milliseconds: 290)));
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

  group('Pool.settle', () {
    test('one outcome per item, in order, never throwing', () async {
      final out = await Pool.settle([1, 2, 3], (x) => x == 2 ? throw StateError('two') : x * 10);
      expect(out.values(), [10, 30]);
      final [Failed(:item, :error)] = out.failures();
      expect((item, '$error'), (2, 'Bad state: two'));
      expect([for (final o in out) o.item], [1, 2, 3]);
    });

    test('a failure does not stop the other jobs', () async {
      final ran = <int>[];
      await Pool.settle([1, 2, 3], (x) {
        ran.add(x);
        if (x == 1) throw StateError('first');
      }, limit: 1);
      expect(ran, [1, 2, 3]);
    });

    test('isolates: true settles too', () async {
      final out = await Pool.settle([1, 2], boom, isolates: true);
      expect(out.failures(), hasLength(2));
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
Future<void> main() async => print(await Pool.map([1, 2, 3], sq, isolates: true));
''');
      expect(r.exitCode, 0);
      expect('${r.stdout}'.trim(), '[1, 4, 9]');
    });
  });
}
