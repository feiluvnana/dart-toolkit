import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Cancel.scope', () {
    test('the token is ambient: retry and cancellable find it without being passed one', () async {
      final stop = CancelToken();
      var attempts = 0;

      await expectLater(
        Cancel.scope(() async {
          expect(Cancel.token, same(stop));
          expect(Cancel.isCancelled, isFalse);
          return retry(
            () {
              attempts++;
              if (attempts == 2) stop.cancel('enough');
              throw StateError('again');
            },
            attempts: 5,
            delay: Duration.zero,
          );
        }, token: stop),
        throwsA(isA<CancelledException>()),
      );
      expect(attempts, 2, reason: 'the loop stopped at the cancel, not at attempt 5');
    });

    test('cancellable takes the scope token, and says so when there is none', () async {
      final stop = CancelToken();
      final controller = StreamController<int>();
      final received = <int>[];

      final done = Cancel.scope(() {
        final out = controller.stream.cancellable.forEach(received.add);
        controller.add(1);
        return out;
      }, token: stop);

      await Future<void>.delayed(Duration.zero);
      stop.cancel();
      controller.add(2);
      await done;
      expect(received, [1]);
      await controller.close();

      expect(() => Stream<int>.empty().cancellable.toList(), throwsStateError);
    });

    test('the ambient readings mirror the token, and are quiet outside a scope', () async {
      final stop = CancelToken();
      await Cancel.scope(token: stop, () async {
        expect(Cancel.isCancelled, isFalse);
        expect(Cancel.reason, isNull);
        expect(Cancel.throwIfCancelled, returnsNormally);

        stop.cancel('enough');
        expect(Cancel.isCancelled, isTrue);
        expect(Cancel.reason, 'enough');
        expect(Cancel.throwIfCancelled, throwsA(isA<CancelledException>()));
      });

      // No scope: nothing has cancelled it, so the readings say so rather than throwing.
      expect(Cancel.isCancelled, isFalse);
      expect(Cancel.reason, isNull);
      expect(Cancel.throwIfCancelled, returnsNormally);
      // The adapter is the one that refuses, because it would otherwise do nothing at all.
      expect(() => Stream<int>.empty().cancellable, throwsStateError);
      expect(() => Future<int>.value(1).cancellable, throwsStateError);
    });

    test('scopes nest, and the inner token wins inside it', () async {
      final outer = CancelToken();
      final inner = CancelToken();
      await Cancel.scope(() async {
        expect(Cancel.token, same(outer));
        await Cancel.scope(() async => expect(Cancel.token, same(inner)), token: inner);
        expect(Cancel.token, same(outer));
      }, token: outer);
    });

    test('a scope with no token of its own still has one', () async {
      await Cancel.scope(() async => expect(Cancel.token, isNotNull));
      expect(Cancel.token, isNull, reason: 'and nothing leaks out of it');
    });
  });

  group('Uniform cancellation composition', () {
    test('Stream.cancellable stops delivery once the scope fires', () async {
      final token = CancelToken();
      final controller = StreamController<int>();
      final received = <int>[];

      await Cancel.scope(token: token, () async {
        final done = controller.stream.cancellable.forEach(received.add);

        controller.add(1);
        await Future<void>.delayed(Duration.zero);
        token.cancel('enough');
        controller.add(2);
        await Future<void>.delayed(Duration.zero);

        await done;
      });
      expect(received, equals([1]));
      await controller.close();
    });

    test('a cancelled stream ends with what it had; Cancel.isCancelled says why', () async {
      final token = CancelToken();
      final controller = StreamController<int>();

      await Cancel.scope(token: token, () async {
        final collected = controller.stream.cancellable.toList();
        controller.add(1);
        await Future<void>.delayed(Duration.zero);
        expect(Cancel.isCancelled, isFalse);
        token.cancel('halt');

        expect(await collected, [1], reason: 'it closes rather than failing');
        expect(Cancel.isCancelled, isTrue, reason: 'and the use site decides what that means');
      });
      await controller.close();
    });

    test('Stream.cancellable on an already-cancelled token yields nothing', () async {
      final token = CancelToken()..cancel();
      final items = await Cancel.scope(token: token, () => Stream.fromIterable([1, 2, 3]).cancellable.toList());
      expect(items, isEmpty);
    });

    test('onCancel returns a working unregister', () async {
      final token = CancelToken();
      var fired = 0;

      final unregister = token.onCancel(() => fired++);
      token.onCancel(() => fired++);
      unregister();

      // Work that completes normally deregisters itself; not observable from here
      // beyond "it still behaves", but it is what stops a long-lived token from
      // retaining every listener it was ever given.
      final controller = StreamController<int>();
      await Cancel.scope(token: token, () async {
        await Future<int>.value(1).cancellable;
        final drained = controller.stream.cancellable.toList();
        await controller.close();
        await drained;
      });

      token.cancel('now');
      expect(fired, equals(1));
    });

    test('Future.cancellable rejects as soon as the token fires', () async {
      final token = CancelToken();
      final slow = Future<int>.delayed(const Duration(seconds: 5), () => 1);
      await Cancel.scope(token: token, () async {
        final guarded = slow.cancellable;
        token.cancel('stop');
        await expectLater(guarded, throwsA(isA<CancelledException>()));
      });
    });

    test('Future.cancellable passes the value through when not cancelled', () async {
      final token = CancelToken();
      final value = await Cancel.scope(token: token, () => Future<int>.value(7).cancellable);
      expect(value, equals(7));
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

    test('throttle(trailing: true) emits pending item before error (ASYNC-2)', () async {
      final controller = StreamController<int>();
      final items = <int>[];
      Object? receivedError;
      final completer = Completer<void>();

      controller.stream
          .throttle(100.ms, leading: true, trailing: true)
          .listen(
            items.add,
            onError: (Object e) {
              receivedError = e;
              completer.complete();
            },
          );

      controller.add(1); // emitted immediately (leading)
      controller.add(2); // pending (trailing)
      controller.addError(StateError('boom'));

      await completer.future;
      expect(items, equals([1, 2]));
      expect(receivedError, isA<StateError>());
      await controller.close();
    });

    test('chunkEvery batches per window and skips empty windows', () async {
      final controller = StreamController<int>();
      final windows = controller.stream.chunkEvery(30.ms).toList();

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
      final sub = controller.stream.chunkEvery(10.ms).listen(received.add);

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

      final outcomes = await Cancel.scope(
        () => items.parallelize((n) async {
          await Future<void>.delayed(50.ms);
          return n;
        }, concurrency: 1),
        token: token,
      );

      expect(outcomes.lefts, isNotEmpty);
      expect(outcomes.lefts.whereType<CancelledException>(), isNotEmpty);
      expect(() => outcomes.unwrap(), throwsA(isA<CancelledException>()));
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

  group('async', () {
    test('Stream.parallelize holds the source while the consumer is paused', () async {
      var produced = 0;
      final source = StreamController<int>();
      final out = source.stream
          .map((i) {
            produced++;
            return i;
          })
          .parallelize((i) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return i;
          }, concurrency: 2);
      final sub = out.listen((_) {});
      source
        ..add(1)
        ..add(2);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sub.pause();
      for (var i = 3; i <= 20; i++) {
        source.add(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(produced, lessThanOrEqualTo(4), reason: 'nothing pulled on a paused consumer\'s behalf');
      sub.resume();
      await source.close();
      await sub.asFuture<void>();
      expect(produced, equals(20));
    });

    test('throttle rejects the combination that emits nothing', () {
      expect(() => Stream<int>.empty().throttle(1.ms, leading: false), throwsArgumentError);
    });
  });

  group('audit: what the bugs pointed at', () {
    test('Stream.parallelize(isolate: true) returns values, not unsendable Lefts', () async {
      final out = await Stream.fromIterable([1, 2, 3]).parallelize(_double, isolate: true).toList();
      expect(out.rights.toList()..sort(), [2, 4, 6]);
    });

    test('Stream.parallelize(isolate: true) cancelled early cleans up workers', () async {
      final res = await Stream.fromIterable([1, 2, 3, 4, 5]).parallelize(_double, isolate: true, concurrency: 4).first;
      expect(res.isRight, isTrue);
    });

    test('Iterable.parallelize(isolate: true) sends the item, not the list around it', () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final mixed = <Object>[1, port, 3];
      final out = await mixed.parallelize((x) => x is int ? x : 0, isolate: true);
      expect(out[0], const Right<Object, int>(1));
      expect(out[1].isLeft, isTrue, reason: 'the port cannot cross, and fails only itself');
      expect(out[2], const Right<Object, int>(3));
    });

    test('retry stops mid-backoff when its scope is cancelled', () async {
      final token = CancelToken();
      final watch = Stopwatch()..start();
      Timer(50.ms, token.cancel);
      await expectLater(
        Cancel.scope(() => retry(() => throw StateError('x'), delay: 10.s, jitter: false), token: token),
        throwsA(isA<CancelledException>()),
      );
      expect(watch.elapsed, lessThan(5.s));
    });

    test('merge pauses its sources when its listener pauses', () async {
      var produced = 0;
      Stream<int> source() async* {
        for (var i = 0; i < 1000; i++) {
          produced++;
          yield i;
          await Future<void>.delayed(Duration.zero);
        }
      }

      final sub = [source(), source()].merge().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      sub.pause();
      final before = produced;
      await Future<void>.delayed(100.ms);
      expect(produced - before, lessThanOrEqualTo(2));
      await sub.cancel();
    });

    test('a cancelled debounce leaves no timer behind', () async {
      final source = StreamController<int>();
      final sub = source.stream.debounce(1.h).listen((_) {});
      source.add(1);
      await sub.cancel();
      await source.close();
      // Nothing to assert on directly: a leaked hour-long timer is what would keep this
      // test's isolate alive, and `dart test` would then never finish.
    });
  });

  group('Pool and Worker', () {
    test('init runs once per isolate, and what it builds stays there', () async {
      final pool = await Pool.spawn(_Counting.new, size: 2);
      addTearDown(pool.close);
      final seen = await Future.wait([for (var i = 0; i < 20; i++) pool.run(i)]);
      expect(seen.map((s) => s.$1).toSet(), {1}, reason: 'each isolate ran init once, not once per item');
      expect(seen.map((s) => s.$2).toSet().length, lessThanOrEqualTo(2));
    });

    test('a failing item fails alone', () async {
      final pool = await Pool.spawn(_Picky.new, size: 1);
      addTearDown(pool.close);
      await expectLater(pool.run(-1), throwsA(isA<ArgumentError>()));
      expect(await pool.run(2), 4);
    });

    test('a dead isolate is replaced before the next item', () async {
      final pool = await Pool.spawn(_Picky.new, size: 1);
      addTearDown(pool.close);
      await expectLater(pool.run(0), throwsA(isA<RemoteError>())); // 0 ends its isolate
      expect(await pool.run(3), 6);
    });

    test('what init throws, spawn throws', () async {
      await expectLater(Pool.spawn(_Broken.new, size: 2), throwsA(isA<StateError>()));
    });

    test('close is idempotent, runs every close, and refuses more work', () async {
      _Local.closes = 0;
      final pool = await Pool.spawn(_Local.new, size: 3, isolate: false);
      expect(await pool.run(1), 1);
      final first = pool.close();
      expect(identical(first, pool.close()), isTrue);
      await first;
      expect(_Local.closes, 3);
      await expectLater(pool.run(1), throwsStateError);
    });

    test('a cancelled scope stops an item in flight on an isolate', () async {
      final pool = await Pool.spawn(_Sleepy.new, size: 1);
      addTearDown(pool.close);
      final token = CancelToken();
      Timer(100.ms, token.cancel);
      final watch = Stopwatch()..start();
      await expectLater(Cancel.scope(() => pool.run(10), token: token), throwsA(isA<CancelledException>()));
      expect(watch.elapsed, lessThan(5.s));
      expect(await pool.run(0), 0, reason: 'the killed isolate was replaced');
    });

    test('map keeps at most size items in flight', () async {
      final pool = await Pool.spawn(_Tracking.new, size: 2, isolate: false);
      addTearDown(pool.close);
      _Tracking.peak = _Tracking.now = 0;
      final out = await pool.map(Stream.fromIterable(List.generate(20, (i) => i))).toList();
      expect(out.rights.length, 20);
      expect(_Tracking.peak, 2);
    });
  });

  group('second audit', () {
    test('close runs every worker\'s close, the busy ones\' too', () async {
      _Slow.closes = 0;
      final pool = await Pool.spawn(_Slow.new, size: 2, isolate: false);
      final inFlight = [pool.run(1), pool.run(2)];
      await pool.close();
      expect(await Future.wait(inFlight), [1, 2]);
      expect(_Slow.closes, 2);
    });

    test('an isolate pool closed with items in flight ends its isolates', () async {
      final pool = await Pool.spawn(_Sleepy.new, size: 2);
      final inFlight = [pool.run(0), pool.run(0)];
      await pool.close().timeout(5.s);
      expect(await Future.wait(inFlight), [0, 0]);
    });

    test('Pool.close() completes already-queued runs and refuses new ones (ASYNC-3)', () async {
      final pool = await Pool.spawn(_Slow.new, size: 1, isolate: false);
      final first = pool.run(1);
      final queued = pool.run(2);
      final closing = pool.close();
      expect(() => pool.run(3), throwsA(isA<StateError>()));
      await closing;
      expect(await first, equals(1));
      expect(await queued, equals(2));
    });

    test('the queue is first come, first served', () async {
      final pool = await Pool.spawn(_Tracking.new, size: 1, isolate: false);
      addTearDown(pool.close);
      final order = <int>[];
      final first = [for (var i = 0; i < 3; i++) pool.run(i).then(order.add)];
      await Future<void>.delayed(1.ms);
      final later = [for (var i = 100; i < 103; i++) pool.run(i).then(order.add)];
      await Future.wait([...first, ...later]);
      expect(order, [0, 1, 2, 100, 101, 102]);
    });

    test('a scope inside another hears the outer one', () async {
      final outer = CancelToken();
      final watch = Stopwatch()..start();
      final done = Cancel.scope(() => Cancel.scope(() => 5.s.delay()), token: outer);
      Timer(50.ms, outer.cancel);
      await expectLater(done, throwsA(isA<CancelledException>()));
      expect(watch.elapsed, lessThan(4.s));
    });

    test('an inner scope does not keep listening once it ends', () async {
      final outer = CancelToken();
      CancelToken? inner;
      await Cancel.scope(() => Cancel.scope(() => inner = Cancel.token), token: outer);
      outer.cancel();
      expect(inner!.isCancelled, isFalse);
    });

    test('Cancel.scope(timeout:) cancels after that long', () async {
      final watch = Stopwatch()..start();
      await expectLater(Cancel.scope(() => 5.s.delay(), timeout: 50.ms), throwsA(isA<CancelledException>()));
      expect(watch.elapsed, lessThan(4.s));
      expect(await Cancel.scope(() => 1, timeout: 1.s), 1);
    });

    test('Cancel.scope(token: shared, timeout:) does not cancel the shared token on timeout (CORE-1)', () async {
      final shared = CancelToken();
      await expectLater(
        Cancel.scope(() => 5.s.delay(), token: shared, timeout: 50.ms),
        throwsA(isA<CancelledException>()),
      );
      expect(shared.isCancelled, isFalse);
    });

    test('delay, Semaphore and Mutex stop when the scope is cancelled', () async {
      final stop = CancelToken();
      final lock = Mutex();
      final held = Completer<void>();
      unawaited(lock.run(() => held.future));
      final waiting = Cancel.scope(() => lock.run(() => 'got it'), token: stop);
      final delayed = Cancel.scope(() => 5.s.delay(), token: stop);
      Timer(20.ms, stop.cancel);
      await expectLater(waiting, throwsA(isA<CancelledException>()));
      await expectLater(delayed, throwsA(isA<CancelledException>()));
      held.complete();
      expect(await lock.run(() => 'free'), 'free'); // the cancelled waiter left the queue
    });

    test('a flatMap mapper that throws is the stream\'s error', () async {
      final events = await Stream.fromIterable([1, 2, 3])
          .flatMap<int>((x) => x == 2 ? throw StateError('boom') : Stream.value(x))
          .map<Object>((x) => x)
          .handleError((Object e) => 'error')
          .toList();
      expect(events, [1, 3]);
    });

    test('debounce and delayBy keep their timing with one timer', () async {
      final controller = StreamController<int>();
      final out = controller.stream.debounce(40.ms).toList();
      controller.add(1);
      await Future<void>.delayed(10.ms);
      controller.add(2);
      await Future<void>.delayed(80.ms);
      controller.add(3);
      await controller.close();
      expect(await out, [2, 3]);

      final watch = Stopwatch()..start();
      final delayed = await Stream.fromIterable([1, 2, 3]).delayBy(30.ms).toList();
      expect(delayed, [1, 2, 3]);
      expect(watch.elapsed, greaterThanOrEqualTo(30.ms));
    });

    test('a sub-millisecond retry delay is not rounded to nothing', () async {
      const step = Duration(microseconds: 900);
      final waits = <Duration>[];
      await expectLater(
        retry(() => throw StateError('x'), attempts: 3, delay: step, jitter: false, onRetry: (_, _, d) => waits.add(d)),
        throwsStateError,
      );
      expect(waits, [step, step * 2]);
    });

    test('parallelize keeps order and settles failures, on an isolate too', () async {
      final local = await [1, -1, 3].parallelize((x) => x < 0 ? throw ArgumentError() : x * 2);
      expect(local.rights, [2, 6]);
      expect(local[1].isLeft, isTrue);
      final remote = await [1, 2, 3, 4, 5].parallelize(_double, isolate: true, concurrency: 2);
      expect(remote.rights, [2, 4, 6, 8, 10]);
    });
  });
}

int _double(int x) => x * 2;

final class _Counting extends Worker<int, (int, int)> {
  static var inits = 0;
  late final int id;

  @override
  void init() {
    inits++;
    id = identityHashCode(Object());
  }

  @override
  (int, int) run(int item) => (inits, id);
}

final class _Picky extends Worker<int, int> {
  @override
  int run(int item) {
    if (item < 0) throw ArgumentError('negative');
    if (item == 0) Isolate.exit();
    return item * 2;
  }
}

final class _Broken extends Worker<int, int> {
  @override
  void init() => throw StateError('no model');

  @override
  int run(int item) => item;
}

final class _Local extends Worker<int, int> {
  static var closes = 0;

  @override
  int run(int item) => item;

  @override
  void close() => closes++;
}

final class _Slow extends Worker<int, int> {
  static var closes = 0;

  @override
  Future<int> run(int item) async {
    await Future<void>.delayed(20.ms);
    return item;
  }

  @override
  void close() => closes++;
}

final class _Sleepy extends Worker<int, int> {
  @override
  int run(int seconds) {
    sleep(Duration(seconds: seconds));
    return seconds;
  }
}

final class _Tracking extends Worker<int, int> {
  static var now = 0;
  static var peak = 0;

  @override
  Future<int> run(int item) async {
    peak = max(peak, ++now);
    await Future<void>.delayed(2.ms);
    now--;
    return item;
  }
}
