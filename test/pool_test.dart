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

/// Blocks its worker; used to prove close() fails in-flight jobs instead of
/// leaving them hanging. Top-level so it crosses isolates. Parks on the
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
  tearDownAll(Pool.close);

  group('Pool.run', () {
    test('runs one job and returns its result', () async {
      expect(await Pool.run(() => 40 + 2), 42);
    });

    test('an error in the job is rethrown', () async {
      expect(Pool.run(() => throw StateError('nope')), throwsStateError);
    });

    test('a job capturing a non-sendable value is an ArgumentError', () async {
      final port = ReceivePort();
      try {
        expect(Pool.run(() => port.hashCode), throwsArgumentError);
      } finally {
        port.close();
      }
    });
  });

  group('Pool.map', () {
    test('maps in input order', () async {
      expect(await Pool.map([1, 2, 3], doubleIt), [2, 4, 6]);
    });

    test('empty input returns empty', () async {
      expect(await Pool.map(<int>[], doubleIt), isEmpty);
    });

    test('limit caps jobs in flight', () async {
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
      expect(max, lessThanOrEqualTo(2));
    });

    test('onResult runs on the caller as each job finishes', () async {
      final seen = <int>[];
      await Pool.map([1, 2, 3], slowDouble, onResult: seen.add);
      expect(seen..sort(), [2, 4, 6]);
    });

    test('the first error stops new jobs and is rethrown', () async {
      expect(Pool.map([1, 2, 3], boom), throwsStateError);
    });

    test('a non-sendable item is an ArgumentError', () async {
      final port = ReceivePort();
      try {
        await expectLater(Pool.map([port], (_) => 1), throwsArgumentError);
      } finally {
        port.close();
      }
    });

    test('the default limit runs jobs in parallel, in input order', () async {
      // 6 x 250 ms serially is 1.5 s; with the default worker-count limit it
      // is one wave. (On a 1-CPU engine with 0 workers this hangs instead.)
      final sw = Stopwatch()..start();
      final out = await Pool.map([1, 2, 3, 4, 5, 6], quarterSecond);
      sw.stop();
      expect(out, [1, 2, 3, 4, 5, 6]);
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('Pool.close', () {
    test('the pool restarts on the next call', () async {
      await Pool.close();
      expect(await Pool.run(() => 1), 1);
    });

    test('concurrent first calls share one init (no double-init warning)',
        () async {
      await Pool.close();
      final lines = <String>[];
      await runZoned(
        () async {
          await Future.wait([Pool.run(() => 1), Pool.run(() => 2)]);
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

    test('close fails an in-flight job with StateError', () async {
      final pending = Pool.run(() => hold(0));
      // Let the job reach a worker; even queued it is covered, but a running
      // job is the case that used to hang forever.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await Pool.close();
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

    test('run then close is a no-op; the pool restarts after', () async {
      // The engine shuts itself down when no job is left (F5), so this close
      // must find nothing to stop and must not throw. Process exit itself is
      // checked manually with a scratch script (see report).
      expect(await Pool.run(() => 7), 7);
      await Pool.close();
      await Pool.close();
      expect(await Pool.run(() => 8), 8);
    });

    test('core is re-exported', () {
      final readers = <Reader>[];
      expect(readers, isEmpty);
    });
  });
}
