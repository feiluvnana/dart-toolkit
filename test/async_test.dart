// Worker, Pool and Job in this program, isolate pools, Semaphore and the stream operators.
// Detached jobs and the store are in `jobs_test.dart`.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_toolkit/async.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

/// What every [_Steps] worker did, in order: `init`, `setup done`, `<item> cleanup (<how>)`.
final _log = <String>[];

/// Counts three steps a few milliseconds apart, then answers its item upper-cased. `fail…`
/// throws a PathNotFoundException the first time; `slow…` takes a second a step.
final class _Steps extends Worker<String, String> {
  static final _failed = <String>{};

  @override
  Future<void> init(Work setup) async {
    _log.add('init');
    setup.defer(() => _log.add('setup done'));
  }

  @override
  Future<String> run(String item, Work work) async {
    work.defer(
      () => _log.add(
        '$item cleanup (${work.ended is Stopped
            ? 'Stopped'
            : work.ended is Done
            ? 'Done'
            : 'Failed'})',
      ),
    );
    for (var i = 1; i <= 3; i++) {
      await (item.startsWith('slow') ? 1.s : 5.ms).delay();
      work.amount(i, total: 3, unit: Unit.items);
    }
    if (item.startsWith('fail') && _failed.add(item)) {
      throw PathNotFoundException(item, const OSError(), 'first try fails');
    }
    return item.toUpperCase();
  }
}

/// A worker whose init fails the first time, after deferring a cleanup.
final class _BadInit extends Worker<int, int> {
  static var tries = 0;

  @override
  void init(Work setup) {
    setup.defer(() => _log.add('half-made cleanup'));
    if (tries++ == 0) throw const FormatException('cannot start');
  }

  @override
  int run(int item, Work work) => item * 2;
}

/// A worker that returns a task: its progress is the item's.
final class _Delegating extends Worker<int, int> {
  @override
  Task<int> run(int item, Work work) => Task.run('inner $item', (inner) async {
    inner.amount(7, total: 9, unit: Unit.items);
    await 10.ms.delay();
    return item + 1;
  });
}

/// Throws an exception that cannot leave its isolate.
final class _Unsendable extends Worker<int, int> {
  @override
  int run(int item, Work work) => throw _HoldsPort(RawReceivePort());
}

final class _HoldsPort implements Exception {
  final RawReceivePort port;
  _HoldsPort(this.port);

  @override
  String toString() => 'holds a port';
}

Future<Status<String, String>> _until(Job<String, String> job, bool Function(Status<String, String> s) test) =>
    job.statuses.firstWhere(test).timeout(10.s);

void main() {
  setUp(_log.clear);

  group('Pool', () {
    test('nothing starts until it is used; init runs once per worker; close runs its cleanups', () async {
      final pool = Pool(_Steps.new, concurrency: 2);
      expect(_log, isEmpty);
      expect(await pool.map(['a', 'b', 'c', 'd']), ['A', 'B', 'C', 'D']);
      expect(_log.where((l) => l == 'init'), hasLength(2));
      await pool.close();
      expect(_log.where((l) => l == 'setup done'), hasLength(2));
      expect(() => pool.map(['e']), throwsStateError);
      expect(() => pool.add('e'), throwsStateError);
    });

    test('a failing item fails alone; awaiting throws one BatchException', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      final batch = pool.map(['a', 'fail-1', 'b']);
      final error = await batch.then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<BatchException<String, String>>().having((e) => e.values, 'values', ['A', 'B']));
    });

    test('map takes retry and timeout as parallelize does', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      expect(await pool.map(['fail-2'], retry: const Retry(1, backoff: Duration.zero)), ['FAIL-2']);
      final timedOut = await pool.map(['slow-1'], timeout: 50.ms).settled;
      expect(timedOut.single, isA<Failed<String, String>>().having((f) => f.error, 'error', isA<TimeoutException>()));
    });

    test('a worker\'s progress and a task it returns are the item\'s progress', () async {
      final steps = Pool(_Steps.new);
      final delegating = Pool(_Delegating.new);
      addTearDown(steps.close);
      addTearDown(delegating.close);
      final statuses = await steps.map(['a']).statuses.toList();
      expect(statuses.whereType<Running<String, String>>().map((r) => r.received), containsAll([1, 2, 3]));
      final inner = await delegating.map([1]).statuses.toList();
      expect(inner.whereType<Running<int, int>>().map((r) => (r.received, r.total)), contains((7, 9)));
      expect(inner.last, isA<Done<int, int>>().having((d) => d.value, 'value', 2));
    });

    test('a worker that fails to start fails its item, runs what it deferred, and is tried again (ASY-17)', () async {
      _BadInit.tries = 0;
      final pool = Pool(_BadInit.new, concurrency: 1);
      addTearDown(pool.close);
      final first = await pool.map([1]).settled;
      expect(first.single, isA<Failed<int, int>>().having((f) => f.error, 'error', isFormatException));
      expect(_log, ['half-made cleanup']);
      expect(await pool.map([2]), [4]);
    });

    test('at most concurrency items run at once, across every map on the pool', () async {
      var running = 0, most = 0;
      final pool = Pool(
        () => _Probe(() => running++, () => running--, (n) => most = n > most ? n : most),
        concurrency: 3,
      );
      addTearDown(pool.close);
      await Future.wait([pool.map(List.generate(10, (i) => i)), pool.map(List.generate(10, (i) => i))]);
      expect(most, 3);
    });

    test('a cancelled map stops its items in flight; the pool runs on (ASY-16)', () async {
      final pool = Pool(_Steps.new, concurrency: 2);
      addTearDown(pool.close);
      final batch = pool.map(['slow-a', 'slow-b', 'c']);
      await 50.ms.delay();
      batch.cancel('enough');
      final settled = await batch.settled;
      expect(settled.whereType<Stopped<String, String>>(), hasLength(3));
      expect(_log, containsAll(['slow-a cleanup (Stopped)', 'slow-b cleanup (Stopped)']));
      expect(await pool.map(['d']), ['D']);
    });

    test('close stops what runs (Stopped), waits for its cleanups, and ends every job (ASY-2)', () async {
      final pool = Pool(_Steps.new, concurrency: 2);
      final batch = pool.map(['slow-a']);
      final job = pool.add('slow-b');
      await 50.ms.delay();
      await pool.close();
      expect((await batch.settled).single, isA<Stopped<String, String>>());
      expect(job.status, isA<Stopped<String, String>>());
      expect(_log, containsAll(['slow-a cleanup (Stopped)', 'slow-b cleanup (Stopped)']));
      expect(_log.last, 'setup done');
      await expectLater(job, throwsA(isA<CancelledException>()));
    });

    test('through runs a stream\'s events', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      expect(await Stream.fromIterable(['x', 'y']).through(pool), ['X', 'Y']);
    });

    test('bad settings are ArgumentErrors at the call', () {
      expect(() => Pool(_Steps.new, concurrency: 0), throwsArgumentError);
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      expect(() => pool.add('a', detached: true), throwsArgumentError, reason: 'a detached job needs a folder store');
    });

    test('an item that does not make the round trip to a folder store is refused at add', () async {
      final pool = Pool(_Records.new, store: Store(tempDir()));
      addTearDown(pool.close);
      expect(() => pool.add((1, 2)), throwsArgumentError);
    });
  });

  group('isolate pools', () {
    test(
      'init runs once per isolate; values, progress and failures cross, failures keeping their type (ASY-14)',
      () async {
        final pool = Pool(_Steps.new, concurrency: 2, isolate: true);
        addTearDown(pool.close);
        final batch = pool.map(['a', 'b', 'fail-iso']);
        final statuses = batch.statuses.toList();
        final settled = await batch.settled;
        expect(
          [
            for (final s in settled)
              if (s case Done(:final value)) value,
          ],
          ['A', 'B'],
        );
        expect(
          settled.last,
          isA<Failed<String, String>>().having((f) => f.error, 'error', isA<PathNotFoundException>()),
        );
        expect((await statuses).whereType<Running<String, String>>().map((r) => r.received), contains(3));
      },
    );

    test('an error that cannot leave the isolate comes back as its text', () async {
      final pool = Pool(_Unsendable.new, concurrency: 1, isolate: true);
      addTearDown(pool.close);
      final settled = await pool.map([1]).settled;
      expect(settled.single, isA<Failed<int, int>>().having((f) => '${f.error}', 'error', 'holds a port'));
    });

    test('a cancel stops an item in flight on its isolate', () async {
      final pool = Pool(_Steps.new, concurrency: 1, isolate: true);
      addTearDown(pool.close);
      final batch = pool.map(['slow-iso']);
      await 300.ms.delay();
      final at = DateTime.now();
      batch.cancel();
      expect((await batch.settled).single, isA<Stopped<String, String>>());
      expect(DateTime.now().difference(at), lessThan(900.ms));
    });
  });

  group('Job', () {
    test('a job waits, runs as its worker reports, and comes to its value', () async {
      final pool = Pool(_Steps.new, concurrency: 1);
      addTearDown(pool.close);
      final first = pool.add('slow-1');
      final second = pool.add('b');
      expect(second.status, isA<Waiting<String, String>>());
      final seen = second.statuses.toList();
      first.remove();
      expect(await second, 'B');
      final statuses = await seen;
      expect(statuses.first, isA<Waiting<String, String>>());
      expect(statuses.whereType<Running<String, String>>().map((r) => r.received), containsAll([1, 2, 3]));
      expect(statuses.last, isA<Done<String, String>>());
      expect(second.id, matches(RegExp(r'^[0-9a-f]{12}$')));
    });

    test('pause stops its run (its cleanup sees why) and holds it; resume runs it again', () async {
      final pool = Pool(_Steps.new, concurrency: 1);
      addTearDown(pool.close);
      final job = pool.add('slow-p');
      await _until(job, (s) => s is Running);
      job.pause();
      await _until(job, (s) => s is Paused);
      expect(_log, contains('slow-p cleanup (Stopped)'));
      job.resume();
      await _until(job, (s) => s is Running);
      job.remove();
      expect(await job.settled, isA<Stopped<String, String>>().having((s) => s.reason, 'reason', 'removed'));
    });

    test('a failure is held, never unhandled; resume runs it again and awaiting it then gives the value', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      final job = pool.add('fail-job');
      expect(await job.settled, isA<Failed<String, String>>());
      await expectLater(job, throwsA(isA<PathNotFoundException>()));
      job.resume();
      expect(await job, 'FAIL-JOB');
    });

    test('an equal unfinished item gives the job it has; a finished one a new job (ASY-15)', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      final job = pool.add('same');
      expect(pool.add('same'), same(job));
      await job;
      final again = pool.add('same');
      expect(again, isNot(same(job)));
      expect(pool.job('same'), same(again));
      expect(pool.job('none'), isNull);
    });

    test('remove stops it, runs its cleanups and forgets it', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      final job = pool.add('slow-r');
      await _until(job, (s) => s is Running);
      job.remove();
      await job.settled;
      expect(_log, contains('slow-r cleanup (Stopped)'));
      expect(pool.jobs, isEmpty);
      expect(pool.job('slow-r'), isNull);
    });

    test('changes hears each job as it moves', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      final heard = <Status<String, String>>[];
      pool.changes.listen((job) => heard.add(job.status));
      await pool.add('c');
      await 10.ms.delay();
      expect(heard.first, isA<Waiting<String, String>>());
      expect(heard.last, isA<Done<String, String>>());
    });

    test('a cancelled scope around add stops its jobs', () async {
      final pool = Pool(_Steps.new);
      addTearDown(pool.close);
      final token = CancelToken();
      late Job<String, String> job;
      await Cancel.scope(() {
        job = pool.add('slow-scope');
      }, token: token);
      await _until(job, (s) => s is Running);
      token.cancel('the program is leaving');
      expect(
        await job.settled,
        isA<Stopped<String, String>>().having((s) => s.reason, 'reason', 'the program is leaving'),
      );
    });
  });

  group('Semaphore', () {
    test('at most permits hold it at once', () async {
      final gate = Semaphore(2);
      var inside = 0, most = 0;
      await Future.wait([
        for (var i = 0; i < 6; i++)
          gate.run(() async {
            most = ++inside > most ? inside : most;
            await 5.ms.delay();
            inside--;
          }),
      ]);
      expect(most, 2);
    });

    test('acquire gives a release that frees the permit once, however often it is called', () async {
      final gate = Semaphore(1);
      final release = await gate.acquire();
      release();
      release();
      final a = await gate.acquire();
      var second = false;
      unawaited(gate.acquire().then((_) => second = true));
      await 10.ms.delay();
      expect(second, isFalse, reason: 'the doubled release gave no second permit');
      a();
      await 10.ms.delay();
      expect(second, isTrue);
    });

    test('a cancel while waiting throws and takes no permit (ASY-23)', () async {
      final gate = Semaphore(1);
      final held = await gate.acquire();
      final token = CancelToken();
      final waiting = Cancel.scope(gate.acquire, token: token);
      token.cancel();
      await expectLater(waiting, throwsA(isA<CancelledException>()));
      held();
      final again = await gate.acquire().timeout(1.s);
      again();
      expect(() => Semaphore(0), throwsArgumentError);
    });
  });

  group('stream operators', () {
    test('chunk ends a batch at size or at the end of a window, whichever is first', () async {
      expect(await Stream.fromIterable([1, 2, 3, 4, 5]).chunk(size: 2).toList(), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      final clock = Clock.fake();
      final source = StreamController<int>();
      final got = <List<int>>[];
      final done = Clock.scope(() => source.stream.chunk(every: 1.s).forEach(got.add), clock: clock);
      source
        ..add(1)
        ..add(2);
      await clock.advance(1.s);
      expect(got, [
        [1, 2],
      ]);
      await clock.advance(3.s); // empty windows emit nothing
      source.add(3);
      await source.close();
      await done;
      expect(got, [
        [1, 2],
        [3],
      ]);
      expect(() => Stream.value(1).chunk(), throwsArgumentError);
      expect(() => Stream.value(1).chunk(size: 0), throwsArgumentError);
      expect(() => Stream.value(1).chunk(every: Duration.zero), throwsArgumentError);
    });

    test('an error passes through after what was held before it (ASY-24)', () async {
      final source = StreamController<int>();
      final got = <Object>[];
      final done = Completer<void>();
      source.stream.chunk(size: 10).listen(got.add, onError: got.add, onDone: done.complete);
      source
        ..add(1)
        ..addError('boom')
        ..add(2);
      await source.close();
      await done.future;
      expect(got, [
        [1],
        'boom',
        [2],
      ]);
    });

    test('debounce emits once things go quiet, and the last at once when the source ends', () async {
      final clock = Clock.fake();
      final source = StreamController<String>();
      final got = <String>[];
      final done = Clock.scope(() => source.stream.debounce(300.ms).forEach(got.add), clock: clock);
      source.add('a');
      await clock.advance(100.ms);
      source.add('b');
      await clock.advance(299.ms);
      expect(got, isEmpty);
      await clock.advance(1.ms);
      expect(got, ['b']);
      source.add('c');
      await source.close();
      await done;
      expect(got, ['b', 'c']);
    });

    test('throttle keeps the leading event of a window and, with trailing, the last', () async {
      final clock = Clock.fake();
      final source = StreamController<int>();
      final got = <int>[];
      final done = Clock.scope(() => source.stream.throttle(1.s, trailing: true).forEach(got.add), clock: clock);
      source
        ..add(1)
        ..add(2)
        ..add(3);
      await clock.advance(10.ms);
      expect(got, [1]);
      await clock.advance(1.s);
      expect(got, [1, 3]);
      await source.close();
      await clock.advance(2.s);
      await done;
      expect(() => Stream.value(1).throttle(1.s, leading: false), throwsArgumentError);
    });

    test('unique keeps the first of each key; a throwing key is the stream\'s error', () async {
      expect(await Stream.fromIterable(['a', 'bb', 'cc', 'd']).unique((s) => s.length).toList(), ['a', 'bb']);
      final errors = <Object>[];
      final done = Completer<void>();
      Stream.fromIterable(
        [1, 2],
      ).unique((n) => n == 2 ? throw StateError('no key') : n).listen(null, onError: errors.add, onDone: done.complete);
      await done.future;
      expect(errors.single, isStateError);
    });

    test('each listener of a broadcast stream gets its own state (ASY-24)', () async {
      final source = StreamController<int>.broadcast();
      final chunks = source.stream.chunk(size: 2);
      expect(chunks.isBroadcast, isTrue);
      final a = chunks.toList(), b = chunks.toList();
      source
        ..add(1)
        ..add(2);
      await source.close();
      expect(await a, [
        [1, 2],
      ]);
      expect(await b, [
        [1, 2],
      ]);
    });

    test('merge listens to at most concurrency streams at a time, 4 by default', () async {
      var listening = 0, most = 0;
      Stream<int> source(int n) => Stream.fromFuture(5.ms.delay().then((_) => n)).doOnListen(() {
        most = ++listening > most ? listening : most;
      }, () => listening--);
      expect((await [for (var i = 0; i < 10; i++) source(i)].merge().toList())..sort(), List.generate(10, (i) => i));
      expect(most, 4);
      most = 0;
      await [for (var i = 0; i < 5; i++) source(i)].merge(concurrency: 2).drain<void>();
      expect(most, 2);
      expect(() => [source(1)].merge(concurrency: 0), throwsArgumentError);
    });

    test('a stream of streams merges as they come, holding the source while concurrency run (ASY-25)', () async {
      var listening = 0, most = 0;
      Stream<int> inner(int n) => Stream.fromFuture(5.ms.delay().then((_) => n)).doOnListen(() {
        most = ++listening > most ? listening : most;
      }, () => listening--);
      final merged = Stream.fromIterable(List.generate(9, (i) => i)).map(inner).merge(concurrency: 3);
      expect((await merged.toList())..sort(), List.generate(9, (i) => i));
      expect(most, 3);
    });

    test('nonNulls drops the nulls', () async {
      expect(await Stream.fromIterable([1, null, 2]).nonNulls.toList(), [1, 2]);
    });
  });
}

/// Calls [enter] and [leave] around each item, and [peak] with how many are inside.
final class _Probe extends Worker<int, int> {
  final void Function() enter, leave;
  final void Function(int inside) peak;
  static var inside = 0;

  _Probe(this.enter, this.leave, this.peak);

  @override
  Future<int> run(int item, Work work) async {
    enter();
    peak(++inside);
    await 2.ms.delay();
    inside--;
    leave();
    return item;
  }
}

/// Items that are records: JSON cannot carry them.
final class _Records extends Worker<(int, int), int> {
  @override
  int run((int, int) item, Work work) => item.$1 + item.$2;
}

extension<T> on Stream<T> {
  /// This stream, with [listened] called when it is listened to and [ended] when it ends.
  Stream<T> doOnListen(void Function() listened, void Function() ended) {
    late final StreamController<T> out;
    out = StreamController<T>(
      onListen: () {
        listened();
        listen(
          out.add,
          onError: out.addError,
          onDone: () {
            ended();
            out.close();
          },
        );
      },
    );
    return out.stream;
  }
}
