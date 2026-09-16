import 'dart:async';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Core Either', () {
    test('Left and Right properties and pattern matching', () {
      final Either<String, int> right = Right(42);
      final Either<String, int> left = Left('error');

      expect(right.isRight, isTrue);
      expect(right.isLeft, isFalse);
      expect(right.rightOrNull, equals(42));
      expect(right.leftOrNull, isNull);

      expect(left.isLeft, isTrue);
      expect(left.isRight, isFalse);
      expect(left.leftOrNull, equals('error'));
      expect(left.rightOrNull, isNull);

      // fold
      expect(right.fold((l) => 'L: $l', (r) => 'R: $r'), equals('R: 42'));
      expect(left.fold((l) => 'L: $l', (r) => 'R: $r'), equals('L: error'));

      // map
      final mappedRight = right.map((r) => r * 2);
      expect(mappedRight, equals(const Right<String, int>(84)));

      final mappedLeft = left.map((r) => r * 2);
      expect(mappedLeft, equals(const Left<String, int>('error')));

      // mapLeft
      final leftMapped = left.mapLeft((l) => l.toUpperCase());
      expect(leftMapped, equals(const Left<String, int>('ERROR')));
    });

    test('Either.guard and Either.guardAsync', () async {
      final syncSuccess = Either.guard(() => 10 + 5);
      expect(syncSuccess, equals(const Right<Object, int>(15)));

      final syncFailure = Either.guard<int>(() => throw FormatException('bad'));
      expect(syncFailure.isLeft, isTrue);
      expect(syncFailure.leftOrNull, isA<FormatException>());

      final asyncSuccess = await Either.guardAsync(() async => 'hello');
      expect(asyncSuccess, equals(const Right<Object, String>('hello')));

      final asyncFailure = await Either.guardAsync<String>(() async => throw StateError('failed'));
      expect(asyncFailure.isLeft, isTrue);
      expect(asyncFailure.leftOrNull, isA<StateError>());
    });
  });

  group('Async parallelize on Iterable', () {
    test('preserves input order and isolates errors into Left', () async {
      final items = [1, 2, 3, 4, 5];

      final results = await items.parallelize((item) async {
        if (item == 3) {
          throw Exception('item 3 failed');
        }
        await Future<void>.delayed(((6 - item) * 10).ms);
        return 'res-$item';
      }, concurrency: 3);

      expect(results.length, equals(5));
      expect(results[0], equals(const Right<Object, String>('res-1')));
      expect(results[1], equals(const Right<Object, String>('res-2')));
      expect(results[2].isLeft, isTrue);
      expect((results[2].leftOrNull as Exception).toString(), contains('item 3 failed'));
      expect(results[3], equals(const Right<Object, String>('res-4')));
      expect(results[4], equals(const Right<Object, String>('res-5')));
    });

    test('respects concurrency limit', () async {
      final items = List.generate(10, (i) => i);
      var maxInFlight = 0;
      var currentInFlight = 0;

      await items.parallelize((item) async {
        currentInFlight++;
        if (currentInFlight > maxInFlight) maxInFlight = currentInFlight;
        await Future<void>.delayed(20.ms);
        currentInFlight--;
        return item;
      }, concurrency: 3);

      expect(maxInFlight, lessThanOrEqualTo(3));
    });
  });

  group('Async parallelize on Stream', () {
    test('emits outcomes concurrently as they complete', () async {
      final stream = Stream.fromIterable([1, 2, 3]);

      final results = await stream.parallelize((item) async {
        if (item == 2) throw Exception('fail 2');
        await Future<void>.delayed(((4 - item) * 10).ms);
        return item * 10;
      }, concurrency: 2).toList();

      expect(results.length, equals(3));
      // item 3 finishes first, item 2 fails, item 1 finishes last
      final rightValues = results.where((e) => e.isRight).map((e) => e.rightOrNull).toList();
      expect(rightValues, containsAll([10, 30]));

      final leftValues = results.where((e) => e.isLeft).toList();
      expect(leftValues.length, equals(1));
    });
  });

  group('Async Retry Builder', () {
    test('retries failed actions up to attempts count and succeeds', () async {
      var count = 0;
      final retriedDelays = <Duration>[];

      final result =
          await (() async {
                count++;
                if (count < 3) throw StateError('attempt $count failed');
                return 'success';
              })
              .retry()
              .attempts(4)
              .delay(10.ms)
              .backoff(1.5)
              .jitter(false)
              .listen((att, err, nextDelay) => retriedDelays.add(nextDelay));

      expect(result, equals('success'));
      expect(count, equals(3));
      expect(retriedDelays.length, equals(2));
    });

    test('rethrows error when attempts are exhausted', () async {
      var count = 0;

      await expectLater(
        (() async {
          count++;
          throw FormatException('always fail');
        }).retry().attempts(3).delay(5.ms),
        throwsA(isA<FormatException>()),
      );

      expect(count, equals(3));
    });

    test('respects when filter predicate', () async {
      var count = 0;

      await expectLater(
        (() async {
          count++;
          if (count == 1) throw ArgumentError('invalid arg');
          throw StateError('state error');
        }).retry().attempts(4).delay(5.ms).when((e) => e is ArgumentError),
        throwsA(isA<StateError>()),
      );

      expect(count, equals(2));
    });

    test('top-level retry() function retries and succeeds', () async {
      var count = 0;
      final result = await retry(
        () async {
          count++;
          if (count < 2) throw Exception('fail');
          return 'success';
        },
        attempts: 3,
        delay: 5.ms,
      );

      expect(result, equals('success'));
      expect(count, equals(2));
    });
  });

  group('Async Synchronization (Mutex & Semaphore)', () {
    test('Mutex protects critical sections exclusively', () async {
      final lock = Mutex();
      var activeWorkers = 0;
      var maxWorkers = 0;
      final output = <int>[];

      await [1, 2, 3].parallelize((id) async {
        await lock.protect(() async {
          activeWorkers++;
          if (activeWorkers > maxWorkers) maxWorkers = activeWorkers;
          await Future<void>.delayed(10.ms);
          output.add(id);
          activeWorkers--;
        });
      }, concurrency: 3);

      expect(maxWorkers, equals(1));
      expect(output.length, equals(3));
      expect(lock.isLocked, isFalse);
    });

    test('Semaphore limits concurrent access to maxPermits', () async {
      final sem = Semaphore(2);
      var inFlight = 0;
      var maxInFlight = 0;

      await List.generate(5, (i) => i).parallelize((id) async {
        await sem.run(() async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(15.ms);
          inFlight--;
        });
      }, concurrency: 5);

      expect(maxInFlight, lessThanOrEqualTo(2));
      expect(sem.availablePermits, equals(2));
    });

    test('Permit release is safe and idempotent', () async {
      final sem = Semaphore(1);
      final permit = await sem.acquire();
      expect(sem.availablePermits, equals(0));

      permit.release();
      expect(sem.availablePermits, equals(1));

      // Second release has no effect
      permit.release();
      expect(sem.availablePermits, equals(1));
    });
  });

  group('Stream Extensions (RxDart powered)', () {
    test('chunk batches stream events into fixed size lists', () async {
      final stream = Stream.fromIterable([1, 2, 3, 4, 5]);
      final chunks = await stream.chunk(2).toList();
      expect(
        chunks,
        equals([
          [1, 2],
          [3, 4],
          [5],
        ]),
      );
    });

    test('flatmap transforms and flattens streams', () async {
      final stream = Stream.fromIterable([1, 2]);
      final flattened = await stream.flatmap((x) => Stream.fromIterable([x, x * 10])).toList();
      expect(flattened, equals([1, 10, 2, 20]));
    });

    test('notnull filters out null values', () async {
      final Stream<int?> stream = Stream.fromIterable([1, null, 2, null, 3]);
      final nonNulls = await stream.notnull().toList();
      expect(nonNulls, equals([1, 2, 3]));
      expect(nonNulls, isA<List<int>>());
    });

    test('debounce suppresses rapid events', () async {
      final controller = StreamController<int>();
      final debounced = controller.stream.debounce(30.ms).toList();

      controller.add(1);
      await Future<void>.delayed(5.ms);
      controller.add(2);
      await Future<void>.delayed(5.ms);
      controller.add(3);
      await Future<void>.delayed(50.ms);
      await controller.close();

      expect(await debounced, equals([3]));
    });

    test('throttle limits emission rate', () async {
      final controller = StreamController<int>();
      final throttled = controller.stream.throttle(30.ms).toList();

      controller.add(1);
      controller.add(2);
      controller.add(3);
      await Future<void>.delayed(50.ms);
      controller.add(4);
      await controller.close();

      expect(await throttled, equals([1, 4]));
    });
  });

  group('Isolate Utilities', () {
    test('(() => computation()).isolate() executes on background isolate', () async {
      final res = await (() {
        var sum = 0;
        for (var i = 0; i < 1000; i++) {
          sum += i;
        }
        return sum;
      }).isolate();

      expect(res, equals(499500));
    });

    test('parallelize with isolate: true runs workers on background isolates', () async {
      final numbers = [10, 20, 30];
      final results = await numbers.parallelize((n) {
        if (n == 20) throw ArgumentError('bad 20');
        return n * 2;
      }, isolate: true);

      expect(results.length, equals(3));
      expect(results[0], equals(const Right<Object, int>(20)));
      expect(results[1].isLeft, isTrue);
      expect(results[2], equals(const Right<Object, int>(60)));
    });

    test('parallelMap throws on first error and preserves order on success', () async {
      final numbers = [1, 2, 3, 4, 5];
      final squares = await numbers.parallelMap((n) async {
        await Future<void>.delayed(5.ms);
        return n * n;
      }, concurrency: 2);

      expect(squares, equals([1, 4, 9, 16, 25]));

      // Throws on error
      await expectLater(
        numbers.parallelMap((n) async {
          if (n == 3) throw StateError('failed on 3');
          return n;
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('parallelSettle completes all tasks into Right/Left without throwing', () async {
      final numbers = [10, 20, 30];
      final outcomes = await numbers.parallelSettle((n) async {
        if (n == 20) throw FormatException('bad format');
        return n * 10;
      });

      expect(outcomes.length, equals(3));
      expect(outcomes[0], equals(const Right<Object, int>(100)));
      expect(outcomes[1].isLeft, isTrue);
      expect(outcomes[1].leftOrNull, isA<FormatException>());
      expect(outcomes[2], equals(const Right<Object, int>(300)));
    });

    test('parallelMap with void executes side-effects across all items', () async {
      final seen = <int>[];
      await [1, 2, 3].parallelMap<void>((n) async {
        await Future<void>.delayed(5.ms);
        seen.add(n);
      }, concurrency: 2);

      expect(seen.length, equals(3));
      expect(seen.toSet(), equals({1, 2, 3}));
    });

    test('parallelMap with CancellationToken cancels in-flight work', () async {
      final token = CancellationToken();
      final items = [1, 2, 3, 4, 5];
      Future.delayed(15.ms, () => token.cancel('cancelled by user'));

      await expectLater(
        items.parallelMap((n) async {
          await Future<void>.delayed(50.ms);
          return n;
        }, cancelToken: token),
        throwsA(isA<CancellationException>()),
      );
    });
  });

  group('JsonPath & String Pattern Evaluation', () {
    test('JsonPath parses and evaluates objects, arrays, and wildcards', () {
      final doc = {
        'items': [
          {'id': 1, 'name': 'Item 1'},
          {'id': 2, 'name': 'Item 2'},
        ],
      };
      final jsonDoc = JsonDocument(doc);
      final names = jsonDoc.$jsonpath(r'$.items[*].name').map((d) => d.raw).toList();
      expect(names, equals(['Item 1', 'Item 2']));
    });

    test('JsonPath throws on unsupported slice and filter expressions', () {
      final jsonDoc = JsonDocument([1, 2, 3, 4, 5]);
      // Slices must throw UnsupportedError
      expect(() => jsonDoc.$jsonpath(r'$.a[1:3]'), throwsA(isA<UnsupportedError>()));
      // Filters must throw UnsupportedError
      expect(() => jsonDoc.$jsonpath(r'$.a[?(@.v > 20)]'), throwsA(isA<UnsupportedError>()));
      // Invalid unclosed brackets
      expect(() => jsonDoc.$jsonpath(r'$.a[unclosed'), throwsA(isA<FormatException>()));
    });

    test('String.match handles plain strings and RegExps without regex coercion', () {
      // Plain string with dot
      expect('axb'.match('a.b'), isNull);
      expect('a.b'.match('a.b'), equals('a.b'));

      // RegExp pattern
      expect('axb'.match(RegExp(r'a.b')), equals('axb'));
      expect('track-01.mp3'.match(RegExp(r'track-(\d+)'), 1), equals('01'));
    });
  });

  group('Either Subtype Equality & Typed Guards', () {
    test('Either == works across compatible subtype parameters', () {
      const leftObj = Left<Object, int>('err');
      const leftStr = Left<String, num>('err');
      expect(leftObj == leftStr, isTrue);

      const rightObj = Right<Object, int>(42);
      const rightNum = Right<String, num>(42);
      expect(rightObj == rightNum, isTrue);
    });

    test('Either.tryCatch with typed error parameter', () {
      final outcome = Either.tryCatch<FormatException, int>(() => int.parse('not_a_num'));
      expect(outcome.isLeft, isTrue);
      expect(outcome.leftOrNull, isA<FormatException>());
    });
  });

  group('RetryBuilder Robustness', () {
    test('RetryBuilder throws StateError if mutated after execution started', () async {
      final builder = RetryBuilder(() async => 42);
      final future = builder.run();
      expect(await future, equals(42));
      expect(() => builder.attempts(5), throwsA(isA<StateError>()));
    });

    test('RetryBuilder respects maxDelay cap', () async {
      var attemptCount = 0;

      await retry(
        () {
          attemptCount++;
          if (attemptCount < 3) throw StateError('retry me');
          return true;
        },
        attempts: 4,
        delay: 50.ms,
        maxDelay: 60.ms,
        backoff: 3.0,
        jitter: false,
      );

      expect(attemptCount, equals(3));
    });
  });
}
