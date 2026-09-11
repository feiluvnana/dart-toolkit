/// # Concurrent Domain (`concurrent.*`)
///
/// A bounded pool for async work, and the two kinds of limit a script needs:
/// [Semaphore] and [Mutex] bound **how many at once**, [Limiter] bounds **how
/// often**. This is concurrency, not parallelism: tasks interleave on one
/// isolate, so it speeds up IO-bound work (requests, file reads) and does
/// nothing for CPU-bound work.
library;

import 'dart:async';
import 'dart:collection';

import '../util/rand.dart';
import '../collection/sequence.dart';

// ============================================================================
// CONCURRENT & WORKER POOL (concurrent.* / Pool)
// ============================================================================

/// The `concurrent` domain: bounded async task pools.
const ConcurrentAccessor concurrent = ConcurrentAccessor();

/// Entry point for bounded concurrency.
///
/// ```dart
/// final replies = await concurrent.run(urls, net.http.get, size: 8);
/// ```
class ConcurrentAccessor {
  /// Creates the accessor. Prefer the shared [concurrent] instance.
  const ConcurrentAccessor();

  /// Maps [worker] over [items] with at most [size] tasks in flight.
  ///
  /// Results come back in the order of [items], not completion order. The
  /// first task to throw aborts the run and its error propagates — construct
  /// a [Pool] and register [PoolEvents.error] instead if you would rather
  /// collect failures and continue.
  Future<Sequence<R>> run<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
    Duration delay = Duration.zero,
  }) => Pool<I>(size: size, delay: delay).run(items, worker);

  /// Streams results of mapping [worker] over [items] in completion order.
  ///
  /// Yields results as tasks finish rather than waiting for all or preserving
  /// input order.
  Stream<R> stream<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
    Duration delay = Duration.zero,
  }) => Pool<I>(size: size, delay: delay).stream(items, worker);

  /// Retries [fn] if it throws, backing off between attempts.
  ///
  /// [retries] is the number of *extra* attempts after the first, which is
  /// what `Fetcher.retries` already means — so `retries: 2` runs [fn] up to
  /// three times.
  ///
  /// ```dart
  /// await concurrent.retry(
  ///   () => net.http.get(url),
  ///   retries: 3,
  ///   backoff: 500.ms,
  ///   onretry: (error, attempt) => log.warn('attempt $attempt: $error'),
  /// );
  /// ```
  ///
  /// A `times:` stood beside this through 4.0.0, documented as *pass one or
  /// the other* — two parameters for one number, which is the failure Rule 5
  /// records the CLI's `def`/`defaultValue` pair going for. It also resolved
  /// silently: `retries` was read first, so `retry(fn, times: 5, retries: 1)`
  /// ran two attempts and ignored the five.
  Future<T> retry<T>(
    FutureOr<T> Function() fn, {
    int retries = 2,
    Duration backoff = const Duration(milliseconds: 100),
    Duration cap = const Duration(seconds: 30),
    bool Function(Object error)? when,
    void Function(Object error, int attempt)? onretry,
  }) => concurrentRetry(
    fn,
    times: retries + 1,
    backoff: backoff,
    cap: cap,
    when: when,
    onretry: onretry,
  );

  /// Creates a counting semaphore bounding concurrent access to [permits].
  ///
  /// `concurrent.mutex()` stood beside this through 4.0.0 and was
  /// `Semaphore(1)` under a second name — a whole exported type for a value of
  /// one argument. `concurrent.semaphore(1)` is the mutex.
  Semaphore semaphore(int permits) => Semaphore(permits);

  /// Creates a rate limiter allowing [count] operations [per] window.
  ///
  /// [Semaphore] bounds how many run at once and this bounds how often they
  /// start, which are different limits — and the second is the one every
  /// public API enforces. `Semaphore(4)` satisfies none of *5000 requests per
  /// hour*, *10 per second* or *60 per minute*: four instant requests then
  /// four more is eight in a second, so the script works until the day the
  /// network is fast.
  ///
  /// ```dart
  /// final limit = concurrent.rate(10, per: 1.s);
  /// await limit.guard(() => net.http.get(url));
  /// ```
  ///
  /// It composes with the bound that is already here, which is the argument
  /// for it living in this domain:
  ///
  /// ```dart
  /// await concurrent.run(urls, (u) => limit.guard(() => net.http.get(u)),
  ///     size: 8);          // 8 in flight, never more than 10 per second
  /// ```
  Limiter rate(int count, {Duration per = const Duration(seconds: 1)}) =>
      Limiter(count, per: per);
}

/// Lifecycle handlers for a [Pool], reachable as `pool.on`.
class PoolEvents<I> {
  final List<void Function()> _startHandlers = [];
  final List<void Function(I item)> _progressHandlers = [];
  final List<void Function()> _doneHandlers = [];
  final List<void Function(Object error, StackTrace stack, I item)>
  _errorHandlers = [];

  /// Called once before the first task starts.
  void start(void Function() handler) => _startHandlers.add(handler);

  /// Called after each task completes successfully.
  void progress(void Function(I item) handler) =>
      _progressHandlers.add(handler);

  /// Called once after every task has settled.
  void done(void Function() handler) => _doneHandlers.add(handler);

  /// Called when a task throws.
  ///
  /// Registering a handler switches the pool from fail-fast to collect-and-
  /// continue: the run finishes, and [Pool.run] throws [PoolFailure] at the
  /// end listing everything that failed.
  void error(void Function(Object error, StackTrace stack, I item) handler) =>
      _errorHandlers.add(handler);
}

/// Raised by [Pool.run] when tasks failed but an error handler was registered.
///
/// Fail-fast is the default; this only appears once [PoolEvents.error] is set,
/// so failures are reported rather than silently dropped.
class PoolFailure<I, R> implements Exception {
  /// Each failed item together with the error and stack it produced.
  final List<({I item, Object error, StackTrace stack})> failures;

  /// What each task returned, matching input positions.
  ///
  /// `null` at the positions that failed, which [failures] names.
  final List<R?> results;

  /// Creates a failure summary.
  const PoolFailure(this.failures, [this.results = const []]);

  @override
  String toString() {
    if (failures.isEmpty) return 'PoolFailure: no failures recorded';
    return 'PoolFailure: ${failures.length} of the pool\'s tasks failed '
        '(first: ${failures.first.error})';
  }
}

/// A bounded pool that runs at most [size] tasks concurrently.
///
/// ```dart
/// final pool = Pool<Uri>(size: 4);
/// pool.on.progress((url) => bar.tick());
/// final pages = await pool.run(urls, fetch);
/// ```
class Pool<I> {
  /// Maximum number of tasks in flight at once. Values below one are treated
  /// as one.
  final int size;

  /// Pause inserted between task launches, for politeness against a server.
  final Duration delay;

  /// Lifecycle handlers for this pool.
  late final PoolEvents<I> on = PoolEvents<I>();

  /// Creates a pool. [size] bounds concurrency; [delay] paces task launches.
  Pool({this.size = 4, this.delay = Duration.zero});

  /// Maps [worker] over [items], preserving input order in the result.
  ///
  /// At most [size] tasks run at once. By default the first error stops new
  /// tasks from launching and propagates once the in-flight ones settle; if
  /// [PoolEvents.error] is registered every item is attempted and a
  /// [PoolFailure] is thrown at the end instead.
  Future<Sequence<R>> run<R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker,
  ) async {
    for (final h in on._startHandlers) {
      h();
    }

    final list = items.toList();
    final results = List<R?>.filled(list.length, null);
    final failures = <({I item, Object error, StackTrace stack})>[];
    final active = <Future<void>>{};
    final limit = size > 0 ? size : 1;
    final collecting = on._errorHandlers.isNotEmpty;
    ({Object error, StackTrace stack})? abort;

    for (var i = 0; i < list.length; i++) {
      // Fail-fast: stop launching once something has gone wrong.
      if (abort != null) break;

      final index = i;
      final item = list[index];
      late final Future<void> task;
      // Tasks never complete with an error, so a failure in one cannot become
      // an unhandled async error while its siblings are still in flight.
      task = Future<void>(() async {
        try {
          results[index] = await worker(item);
          for (final h in on._progressHandlers) {
            h(item);
          }
        } catch (error, stack) {
          if (collecting) {
            for (final h in on._errorHandlers) {
              h(error, stack, item);
            }
            failures.add((item: item, error: error, stack: stack));
          } else {
            abort ??= (error: error, stack: stack);
          }
        } finally {
          active.remove(task);
        }
      });
      active.add(task);

      if (active.length >= limit) await Future.any(active);
      if (delay > Duration.zero && index < list.length - 1) {
        await Future<void>.delayed(delay);
      }
    }

    await Future.wait(active);
    for (final h in on._doneHandlers) {
      h();
    }

    if (abort case final failed?) {
      // Preserve the worker's original error and stack rather than reporting
      // a null-cast from the unfilled result slot.
      Error.throwWithStackTrace(failed.error, failed.stack);
    }
    if (failures.isNotEmpty) {
      throw PoolFailure<I, R>(failures, List<R?>.unmodifiable(results));
    }
    return Sequence(List<R>.generate(list.length, (i) => results[i] as R));
  }

  /// Maps [worker] over all [items] to completion, never throwing on worker
  /// error.
  ///
  /// Returns one [Settled] per item, in input order:
  ///
  /// ```dart
  /// (await pool.settle(urls, fetch)).collect(.foreach((result) {
  ///   switch (result) {
  ///     case Done(:final value): save(value);
  ///     case Broke(:final error): log.warn('$error');
  ///   }
  /// }));
  /// ```
  Future<Sequence<Settled<R>>> settle<R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker,
  ) async {
    for (final h in on._startHandlers) {
      h();
    }

    final list = items.toList();
    final outcomes = List<Settled<R>?>.filled(list.length, null);
    final active = <Future<void>>{};
    final limit = size > 0 ? size : 1;

    for (var i = 0; i < list.length; i++) {
      final index = i;
      final item = list[index];
      late final Future<void> task;

      task = Future<void>(() async {
        try {
          outcomes[index] = Done<R>(await worker(item));
          for (final h in on._progressHandlers) {
            h(item);
          }
        } catch (error, stack) {
          outcomes[index] = Broke<R>(error, stack);
          for (final h in on._errorHandlers) {
            h(error, stack, item);
          }
        } finally {
          active.remove(task);
        }
      });
      active.add(task);

      if (active.length >= limit) await Future.any(active);
      if (delay > Duration.zero && index < list.length - 1) {
        await Future<void>.delayed(delay);
      }
    }

    await Future.wait(active);
    for (final h in on._doneHandlers) {
      h();
    }

    return Sequence(List.generate(list.length, (i) => outcomes[i]!));
  }

  /// Streams results of mapping [worker] over [items] in completion order.
  ///
  /// The stream honours its subscription: pausing stops new tasks from being
  /// launched once the in-flight ones settle, and cancelling stops the run
  /// rather than leaving the remaining items to work through an audience that
  /// has left.
  Stream<R> stream<R>(Iterable<I> items, FutureOr<R> Function(I item) worker) {
    final list = items.toList();
    final active = <Future<void>>{};
    final limit = size > 0 ? size : 1;
    final collecting = on._errorHandlers.isNotEmpty;
    var cancelled = false;
    var listening = false;
    Completer<void>? resumed;

    void wake() {
      final waiter = resumed;
      resumed = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }

    late final StreamController<R> controller;
    controller = StreamController<R>(
      // A single-subscription controller reports itself paused until someone
      // listens, so work waits for a subscriber rather than racing ahead of one.
      onListen: () {
        listening = true;
        wake();
      },
      onCancel: () {
        cancelled = true;
        wake();
      },
      onResume: wake,
    );

    () async {
      for (final h in on._startHandlers) {
        h();
      }

      for (var i = 0; i < list.length; i++) {
        while (!cancelled &&
            !controller.isClosed &&
            (!listening || controller.isPaused)) {
          await (resumed ??= Completer<void>()).future;
        }
        if (cancelled || controller.isClosed) break;

        final item = list[i];
        late final Future<void> task;

        task = Future<void>(() async {
          // Checked again here, not only before scheduling: this body starts a
          // turn later, so a cancel that lands in between would otherwise
          // still launch one more item's work.
          if (cancelled || controller.isClosed) return;
          try {
            final res = await worker(item);
            if (!cancelled && !controller.isClosed) {
              controller.add(res);
            }
            for (final h in on._progressHandlers) {
              h(item);
            }
          } catch (error, stack) {
            if (collecting) {
              for (final h in on._errorHandlers) {
                h(error, stack, item);
              }
            } else if (!cancelled && !controller.isClosed) {
              controller.addError(error, stack);
              await controller.close();
            }
          } finally {
            active.remove(task);
          }
        });
        active.add(task);

        if (active.length >= limit) await Future.any(active);
        if (delay > Duration.zero && i < list.length - 1) {
          await Future<void>.delayed(delay);
        }
      }

      await Future.wait(active);
      for (final h in on._doneHandlers) {
        h();
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }();

    return controller.stream;
  }
}

// ============================================================================
// SYNCHRONIZATION PRIMITIVES & HELPERS
// ============================================================================

/// A counting semaphore for bounding concurrent access to a resource.
class Semaphore {
  /// The maximum number of permits that can be acquired simultaneously.
  final int permits;
  int _availablePermits;
  // A queue, not a list: release() pops the head on every permit handed back,
  // which is O(n) on a List once a pool is deep enough to queue up.
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// Creates a semaphore with [permits].
  Semaphore(this.permits) : _availablePermits = permits {
    if (permits <= 0) {
      throw ArgumentError.value(permits, 'permits', 'Must be greater than 0');
    }
  }

  /// Number of currently available permits.
  int get available => _availablePermits;

  /// Takes a permit, suspending if none are available.
  ///
  /// Spelled like [Limiter.take], because the two are the same shape: one
  /// bounds how many run at once and the other how often they start. They used
  /// to say `acquire`/`withPermit` and `take`/`guard`, which is two dialects
  /// for one idea — and `withPermit` was the library's one camelCase member,
  /// which Rule 4 forbids outright.
  Future<void> take() {
    if (_availablePermits > 0) {
      _availablePermits--;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Releases a permit, unblocking the next waiting caller.
  ///
  /// Never hands back more than the semaphore was created with: a release that
  /// pairs with no acquire is ignored rather than raising the ceiling and
  /// quietly removing the bound this exists to enforce.
  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    if (_availablePermits < permits) _availablePermits++;
  }

  /// Takes a permit, runs [action], and releases it however [action] ends.
  ///
  /// Spelled like [Limiter.guard].
  Future<R> guard<R>(FutureOr<R> Function() action) async {
    await take();
    try {
      return await action();
    } finally {
      release();
    }
  }
}

/// A token bucket that bounds how often something may happen.
///
/// [Semaphore] answers *how many at once*; this answers *how often*, which is
/// the limit a public API publishes. Every limiter in this domain has a bare
/// pair and a wrapping form, and the wrapping form is the one to use:
///
/// ```dart
/// final limit = concurrent.rate(10, per: 1.s);
///
/// await limit.take();                            // waits for a token
/// await limit.guard(() => net.http.get(url));    // the wrapped form
/// ```
///
/// **The bucket refills smoothly**, one token every `per / count`, rather than
/// in a lump at the end of each window. Smooth is what servers actually
/// measure, and it also means a burst of ten at second zero does not lock out
/// second one entirely. Waiters are served in the order they arrived.
class Limiter {
  /// How many operations are allowed per [per].
  ///
  /// Also the burst ceiling: an idle limiter accumulates at most this many
  /// tokens, so a script that waited a minute does not get a minute's worth of
  /// requests to fire at once.
  final int count;

  /// The window [count] is measured over.
  final Duration per;

  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  // A monotonic clock, so a limiter is not confused by the system clock being
  // set backwards while a script is waiting on it.
  final Stopwatch _clock = Stopwatch()..start();
  double _tokens;
  int _last = 0;
  Timer? _pump;

  /// Creates a limiter allowing [count] operations per [per].
  ///
  /// Starts full, so the first [count] operations do not wait.
  Limiter(this.count, {this.per = const Duration(seconds: 1)})
    : _tokens = count.toDouble() {
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'Must be greater than 0');
    }
    if (per <= Duration.zero) {
      throw ArgumentError.value(per, 'per', 'Must be a positive duration');
    }
  }

  double get _perMicrosecond => count / per.inMicroseconds;

  /// How many tokens are available right now.
  ///
  /// Fractional, because the bucket refills continuously. For a check rather
  /// than a wait — taking a token is [take].
  double get available {
    _refill();
    return _tokens;
  }

  /// How many callers are waiting for a token.
  int get waiting => _waiters.length;

  /// Waits until a token is free, then takes it.
  ///
  /// Callers are served in arrival order, so a queue behind a busy limiter
  /// does not starve its oldest waiter.
  Future<void> take() {
    _refill();
    if (_waiters.isEmpty && _tokens >= 1) {
      _tokens -= 1;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    _schedule();
    return waiter.future;
  }

  /// Takes a token, then runs [action].
  ///
  /// Mirrors [Semaphore.withPermit] and [Mutex.protect]. The token is spent on
  /// starting, not on finishing, because a rate is about how often something
  /// begins.
  Future<R> guard<R>(FutureOr<R> Function() action) async {
    await take();
    return action();
  }

  /// Stops the refill timer, so a script holding a limiter can exit.
  ///
  /// Every waiter still queued completes, since refusing them would turn a
  /// rate limit into a failure. Only needed when a limiter is discarded with
  /// callers still on it.
  void close() {
    _pump?.cancel();
    _pump = null;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  void _refill() {
    final now = _clock.elapsedMicroseconds;
    final elapsed = now - _last;
    if (elapsed <= 0) return;
    _last = now;
    final grown = _tokens + elapsed * _perMicrosecond;
    _tokens = grown > count ? count.toDouble() : grown;
  }

  void _schedule() {
    if (_pump != null) return;
    final needed = 1 - _tokens;
    final micros = needed <= 0 ? 1 : (needed / _perMicrosecond).ceil();
    _pump = Timer(Duration(microseconds: micros < 1 ? 1 : micros), _drain);
  }

  void _drain() {
    _pump = null;
    _refill();
    while (_waiters.isNotEmpty && _tokens >= 1) {
      _tokens -= 1;
      _waiters.removeFirst().complete();
    }
    if (_waiters.isNotEmpty) _schedule();
  }

  @override
  String toString() => 'Limiter($count per ${per.inMilliseconds}ms)';
}

/// Retries [fn] if it throws.
///
/// [times] is the total number of attempts; [retries] is the number of extra
/// attempts after the first. The delay grows linearly from [backoff], is
/// capped at [cap], and carries up to 25% jitter so a pool of retrying
/// tasks does not resynchronise onto the same instant.
Future<T> concurrentRetry<T>(
  FutureOr<T> Function() fn, {
  int times = 3,
  int? retries,
  Duration backoff = const Duration(milliseconds: 100),
  Duration cap = const Duration(seconds: 30),
  bool Function(Object error)? when,
  void Function(Object error, int attempt)? onretry,
}) async {
  final count = retries != null ? retries + 1 : times;
  var attempt = 0;
  while (true) {
    attempt++;
    try {
      return await fn();
    } catch (error) {
      if (attempt >= count || (when != null && !when(error))) {
        rethrow;
      }
      onretry?.call(error, attempt);
      await Future<void>.delayed(_backoffFor(attempt, backoff, cap));
    }
  }
}

// The library's one generator, the same one `net.http`'s retries draw from,
// so `util.rand.seed` makes a retrying pool as repeatable as a crawl's order.
// A second Random in here quietly made that promise false for this half.
const RandAccessor _rand = RandAccessor();

Duration _backoffFor(int attempt, Duration base, Duration cap) {
  final scaled = base * attempt;
  final bounded = scaled > cap ? cap : scaled;
  return _rand.jitter(bounded);
}

/// What became of one task in [Pool.settle].
///
/// Sealed, with the value on [Done] and the error on [Broke], so the branch
/// that has a value is the branch where it is non-nullable:
///
/// ```dart
/// for (final result in (await pool.settle(urls, fetch)).collect(.list())) {
///   switch (result) {
///     case Done(:final value): save(value);
///     case Broke(:final error): log.warn('$error');
///   }
///}
/// ```
///
/// This was a record of four fields — `value`, `error`, `stack` and
/// `isSuccess` — where two were always null and a boolean said which two.
sealed class Settled<R> {
  const Settled();

  /// Whether the task finished without throwing.
  ///
  /// For a filter or a count. To *use* the value, match on [Done] instead:
  /// that is the branch where it is not null.
  bool get ok => this is Done<R>;

  /// The value, or `null` when the task threw.
  R? get value => switch (this) {
    Done<R>(:final value) => value,
    Broke<R>() => null,
  };
}

/// A task that finished, carrying what it returned.
final class Done<R> extends Settled<R> {
  @override
  final R value;

  /// Creates a successful outcome.
  const Done(this.value);

  @override
  String toString() => 'Done($value)';
}

/// A task that threw, carrying the error and where it came from.
final class Broke<R> extends Settled<R> {
  /// What was thrown.
  final Object error;

  /// Where it was thrown.
  final StackTrace stack;

  /// Creates a failed outcome.
  const Broke(this.error, this.stack);

  @override
  String toString() => 'Broke($error)';
}
