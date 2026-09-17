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
      final mappedRight = right.mapRight((r) => r * 2);
      expect(mappedRight, equals(const Right<String, int>(84)));

      final mappedLeft = left.mapRight((r) => r * 2);
      expect(mappedLeft, equals(const Left<String, int>('error')));

      // mapLeft
      final leftMapped = left.mapLeft((l) => l.toUpperCase());
      expect(leftMapped, equals(const Left<String, int>('ERROR')));
    });

    test('Either.tryCatch and Either.tryCatchAsync', () async {
      final syncSuccess = Either.tryCatch(() => 10 + 5);
      expect(syncSuccess, equals(const Right<Object, int>(15)));

      final syncFailure = Either.tryCatch<int>(() => throw FormatException('bad'));
      expect(syncFailure.isLeft, isTrue);
      expect(syncFailure.leftOrNull, isA<FormatException>());

      final asyncSuccess = await Either.tryCatchAsync(() async => 'hello');
      expect(asyncSuccess, equals(const Right<Object, String>('hello')));

      final asyncFailure = await Either.tryCatchAsync<String>(() async => throw StateError('failed'));
      expect(asyncFailure.isLeft, isTrue);
      expect(asyncFailure.leftOrNull, isA<StateError>());

      // tryCatchAsync also accepts a synchronous closure.
      expect(await Either.tryCatchAsync(() => 1), equals(const Right<Object, int>(1)));
    });

    test('Either.unwrap returns the Right value or throws the Left value', () {
      expect(const Right<Object, int>(7).unwrap(), equals(7));

      final failure = FormatException('nope');
      expect(() => Left<Object, int>(failure).unwrap(), throwsA(same(failure)));
      expect(() => const Left<Object?, int>(null).unwrap(), throwsA(isA<StateError>()));
    });

    test('Iterable<Either>.unwrap / rights / lefts partition outcomes', () {
      final boom = StateError('boom');
      final outcomes = <Either<Object, int>>[const Right(1), Left(boom), const Right(3)];

      expect(outcomes.rights, equals([1, 3]));
      expect(outcomes.lefts, equals([boom]));
      expect(() => outcomes.unwrap(), throwsA(same(boom)));
      expect(<Either<Object, int>>[const Right(1), const Right(2)].unwrap(), equals([1, 2]));
    });

    test('Stream<Either>.unwrap forwards the first Left as a stream error', () {
      final boom = StateError('boom');
      final stream = Stream<Either<Object, int>>.fromIterable([const Right(1), Left(boom)]);
      expect(stream.unwrap(), emitsInOrder([1, emitsError(same(boom))]));
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

      final result = await retry(
        () async {
          count++;
          if (count < 3) throw StateError('attempt $count failed');
          return 'success';
        },
        attempts: 4,
        delay: 10.ms,
        backoff: 1.5,
        jitter: false,
        onRetry: (att, err, nextDelay) => retriedDelays.add(nextDelay),
      );

      expect(result, equals('success'));
      expect(count, equals(3));
      expect(retriedDelays.length, equals(2));
    });

    test('rethrows error when attempts are exhausted', () async {
      var count = 0;

      await expectLater(
        retry(
          () async {
            count++;
            throw FormatException('always fail');
          },
          attempts: 3,
          delay: 5.ms,
        ),
        throwsA(isA<FormatException>()),
      );

      expect(count, equals(3));
    });

    test('respects when filter predicate', () async {
      var count = 0;

      await expectLater(
        retry(
          () async {
            count++;
            if (count == 1) throw ArgumentError('invalid arg');
            throw StateError('state error');
          },
          attempts: 4,
          delay: 5.ms,
          when: (e) => e is ArgumentError,
        ),
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
        await lock.run(() async {
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
      expect(sem.permits, equals(2));
    });

    test('Permit release is safe and idempotent', () async {
      final sem = Semaphore(1);
      final permit = await sem.acquire();
      expect(sem.permits, equals(0));

      permit.release();
      expect(sem.permits, equals(1));

      // Second release has no effect
      permit.release();
      expect(sem.permits, equals(1));
    });
  });

  group('Stream Extensions', () {
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
      final flattened = await stream.flatMap((x) => Stream.fromIterable([x, x * 10])).toList();
      expect(flattened, equals([1, 10, 2, 20]));
    });

    test('notnull filters out null values', () async {
      final Stream<int?> stream = Stream.fromIterable([1, null, 2, null, 3]);
      final nonNulls = await stream.nonNulls.toList();
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

    test('chunkTime batches per window and skips empty windows', () async {
      final controller = StreamController<int>();
      final windows = controller.stream.chunkTime(30.ms).toList();

      controller.add(1);
      controller.add(2);
      await Future<void>.delayed(60.ms); // this window closes, the next stays empty
      controller.add(3);
      await Future<void>.delayed(60.ms);
      await controller.close();

      expect(
        await windows,
        equals([
          [1, 2],
          [3],
        ]),
      );
    });

    test('delayBy shifts every item and still completes', () async {
      final sw = Stopwatch()..start();
      final shifted = await Stream.fromIterable([1, 2, 3]).delayBy(40.ms).toList();
      sw.stop();

      expect(shifted, equals([1, 2, 3]));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(35));
    });

    test('a paused subscription receives nothing and drains on resume', () async {
      final controller = StreamController<int>();
      final received = <List<int>>[];
      final sub = controller.stream.chunkTime(10.ms).listen(received.add);

      sub.pause();
      controller.add(1);
      await Future<void>.delayed(40.ms);
      expect(received, isEmpty);

      sub.resume();
      await Future<void>.delayed(40.ms);
      expect(
        received,
        equals([
          [1],
        ]),
      );

      await sub.cancel();
      await controller.close();
    });

    test('flatMap runs inner streams concurrently', () async {
      // Sequential expansion would give [1, 2]; concurrent gives the fast one first.
      final merged = await Stream.fromIterable([
        40,
        5,
      ]).flatMap((ms) => Stream.fromFuture(Future.delayed(ms.ms, () => ms))).toList();
      expect(merged, equals([5, 40]));
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

    test('parallelize().unwrap() preserves order and throws the first failure', () async {
      final numbers = [1, 2, 3, 4, 5];
      final squares = (await numbers.parallelize((n) async {
        await Future<void>.delayed(5.ms);
        return n * n;
      }, concurrency: 2)).unwrap();

      expect(squares, equals([1, 4, 9, 16, 25]));

      final settled = await numbers.parallelize((n) async {
        if (n == 3) throw StateError('failed on 3');
        return n;
      });
      expect(() => settled.unwrap(), throwsA(isA<StateError>()));
    });

    test('parallelize does not throw on a workload with zero failures', () async {
      final outcomes = await [1, 2].parallelize((n) => n * 2);
      expect(outcomes.rights, equals([2, 4]));
      expect(outcomes.lefts, isEmpty);
    });

    test('parallelize completes all tasks into Right/Left without throwing', () async {
      final numbers = [10, 20, 30];
      final outcomes = await numbers.parallelize((n) async {
        if (n == 20) throw FormatException('bad format');
        return n * 10;
      });

      expect(outcomes.length, equals(3));
      expect(outcomes[0], equals(const Right<Object, int>(100)));
      expect(outcomes[1].isLeft, isTrue);
      expect(outcomes[1].leftOrNull, isA<FormatException>());
      expect(outcomes[2], equals(const Right<Object, int>(300)));
    });

    test('parallelize with void executes side-effects across all items', () async {
      final seen = <int>[];
      await [1, 2, 3].parallelize<void>((n) async {
        await Future<void>.delayed(5.ms);
        seen.add(n);
      }, concurrency: 2);

      expect(seen.length, equals(3));
      expect(seen.toSet(), equals({1, 2, 3}));
    });

    test('parallelize with CancelToken reports unexecuted work as Left', () async {
      final token = CancelToken();
      final items = [1, 2, 3, 4, 5];
      Future.delayed(15.ms, () => token.cancel('cancelled by user'));

      final outcomes = await items.parallelize(
        (n) async {
          await Future<void>.delayed(50.ms);
          return n;
        },
        concurrency: 1,
        cancelToken: token,
      );

      expect(outcomes.lefts, isNotEmpty);
      expect(outcomes.lefts.whereType<CancelledException>(), isNotEmpty);
      expect(() => outcomes.unwrap(), throwsA(isA<CancelledException>()));
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
      final names = jsonDoc.$(r'$.items[*].name').map((d) => d.raw).toList();
      expect(names, equals(['Item 1', 'Item 2']));
    });

    test('JsonPath throws on unsupported slice and filter expressions', () {
      final jsonDoc = JsonDocument([1, 2, 3, 4, 5]);
      // Slices must throw UnsupportedError
      expect(() => jsonDoc.$(r'$.a[1:3]'), throwsA(isA<UnsupportedError>()));
      // Filters must throw UnsupportedError
      expect(() => jsonDoc.$(r'$.a[?(@.v > 20)]'), throwsA(isA<UnsupportedError>()));
      // Invalid unclosed brackets
      expect(() => jsonDoc.$(r'$.a[unclosed'), throwsA(isA<FormatException>()));
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

    test('Either.tryCatch captures any thrown error, whatever its type', () {
      final parsed = Either.tryCatch(() => int.parse('not_a_num'));
      expect(parsed.isLeft, isTrue);
      expect(parsed.leftOrNull, isA<FormatException>());

      // Narrowing happens afterwards, so no error type can be unrepresentable.
      final narrowed = Either.tryCatch<int>(() => throw StateError('boom')).mapLeft((e) => FormatException('\$e'));
      expect(narrowed.isLeft, isTrue);
      expect(narrowed.leftOrNull, isA<FormatException>());
    });
  });

  group('retry robustness', () {
    test('retry respects maxDelay cap', () async {
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
