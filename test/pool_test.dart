@Timeout(Duration(minutes: 2))
library;

import 'dart:isolate';

import 'package:dart_toolkit/pool.dart';
import 'package:test/test.dart';

int doubleIt(int x) => x * 2;

Future<int> slowDouble(int x) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return x * 2;
}

int boom(int x) => throw StateError('bad $x');

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
  });

  group('Pool.close', () {
    test('the pool restarts on the next call', () async {
      await Pool.close();
      expect(await Pool.run(() => 1), 1);
    });
  });
}
