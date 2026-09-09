/// # Concurrent Domain (`concurrent.*`)
///
/// A bounded pool for async work. This is concurrency, not parallelism: tasks
/// interleave on one isolate, so it speeds up IO-bound work (requests, file
/// reads) and does nothing for CPU-bound work.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math';

// ============================================================================
// CONCURRENT & WORKER POOL (concurrent.* / Pool)
// ============================================================================

/// The `concurrent` domain: bounded async task pools.
const ConcurrentAccessor concurrent = ConcurrentAccessor();

/// Entry point for bounded concurrency.
///
/// ```dart
/// final bodies = await concurrent.run(urls, (url) => net.get(url), size: 8);
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
  Future<List<R>> run<I, R>(
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

  /// Runs [fn] with [message] on a separate isolate using [Isolate.run].
  Future<R> compute<M, R>(FutureOr<R> Function(M message) fn, M message) =>
      Isolate.run(() => fn(message));

  /// Retries [fn] if it throws.
  ///
  /// [times] is the total number of attempts; [retries] is the number of extra
  /// attempts after the first, matching [HttpClient.retries]. Pass one or the
  /// other — `times: 3` and `retries: 2` both mean three attempts.
  Future<T> retry<T>(
    FutureOr<T> Function() fn, {
    int times = 3,
    int? retries,
    Duration backoff = const Duration(milliseconds: 100),
    Duration cap = const Duration(seconds: 30),
    bool Function(Object error)? when,
    void Function(Object error, int attempt)? onretry,
  }) => concurrentRetry(
    fn,
    times: retries != null ? retries + 1 : times,
    backoff: backoff,
    cap: cap,
    when: when,
    onretry: onretry,
  );

  /// Creates a counting semaphore bounding concurrent access to [permits].
  Semaphore semaphore(int permits) => Semaphore(permits);

  /// Creates a mutual exclusion lock.
  Mutex mutex() => Mutex();
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
class PoolFailure<I> implements Exception {
  /// Each failed item together with the error and stack it produced.
  final List<({I item, Object error, StackTrace stack})> failures;

  /// Results for tasks that completed successfully, matching input positions.
  final List<dynamic> results;

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
/// final pool = Pool<String>(size: 4);
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
  Future<List<R>> run<R>(
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
      throw PoolFailure<I>(failures, List.unmodifiable(results));
    }
    return List<R>.generate(list.length, (i) => results[i] as R);
  }

  /// Maps [worker] over all [items] to completion, never throwing on worker error.
  ///
  /// Returns per-item outcomes in input order.
  Future<List<({R? value, Object? error, StackTrace? stack, bool isSuccess})>>
  settle<R>(Iterable<I> items, FutureOr<R> Function(I item) worker) async {
    for (final h in on._startHandlers) {
      h();
    }

    final list = items.toList();
    final outcomes = List<
      ({R? value, Object? error, StackTrace? stack, bool isSuccess})?
    >.filled(list.length, null);
    final active = <Future<void>>{};
    final limit = size > 0 ? size : 1;

    for (var i = 0; i < list.length; i++) {
      final index = i;
      final item = list[index];
      late final Future<void> task;

      task = Future<void>(() async {
        try {
          final value = await worker(item);
          outcomes[index] = (
            value: value,
            error: null,
            stack: null,
            isSuccess: true,
          );
          for (final h in on._progressHandlers) {
            h(item);
          }
        } catch (error, stack) {
          outcomes[index] = (
            value: null,
            error: error,
            stack: stack,
            isSuccess: false,
          );
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

    return List.generate(list.length, (i) => outcomes[i]!);
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

  /// Acquires a permit, suspending if none are available.
  Future<void> acquire() {
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

  /// Acquires a permit, runs [action], and releases the permit upon completion.
  Future<R> withPermit<R>(FutureOr<R> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}

/// A mutual exclusion lock.
class Mutex {
  final Semaphore _semaphore = Semaphore(1);

  /// Acquires the lock, suspending until available.
  Future<void> acquire() => _semaphore.acquire();

  /// Releases the lock.
  void release() => _semaphore.release();

  /// Runs [action] exclusively with the lock held.
  Future<R> protect<R>(FutureOr<R> Function() action) =>
      _semaphore.withPermit(action);
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

final Random _jitter = Random();

Duration _backoffFor(int attempt, Duration base, Duration cap) {
  final scaled = base * attempt;
  final bounded = scaled > cap ? cap : scaled;
  return bounded +
      Duration(
        milliseconds:
            (bounded.inMilliseconds * 0.25 * _jitter.nextDouble()).toInt(),
      );
}

/// The result of a settled task in [Pool.settle].
typedef SettledResult<R> =
    ({R? value, Object? error, StackTrace? stack, bool isSuccess});

/// Convenience getters on [SettledResult].
extension SettledResultExtension<R> on SettledResult<R> {
  /// Whether the task succeeded without throwing.
  bool get ok => isSuccess;
}
