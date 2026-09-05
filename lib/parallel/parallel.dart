import 'dart:async';

// ============================================================================
// PARALLEL & CONCURRENCY POOL (parallel.* / Pool)
// ============================================================================

/// Top-level parallel execution accessor (`parallel.run(...)`, `parallel.pool(...)`).
const ParallelAccessor parallel = ParallelAccessor();

/// Parallel task execution namespace accessor.
class ParallelAccessor {
  const ParallelAccessor();

  /// Create dedicated Pool instance with specific concurrency size (1-word).
  Pool pool([int concurrency = 4]) => Pool(concurrency);

  /// Run tasks concurrently over items with specified concurrency size (1-word).
  Future<List<R>> run<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
  }) =>
      Pool(size).run(items, worker);

  /// Concurrently iterate over items with specified concurrency size (1-word).
  Future<List<R>> each<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
  }) =>
      Pool(size).run(items, worker);

  /// Concurrently map items to results with specified concurrency size (1-word).
  Future<List<R>> map<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) mapper, {
    int size = 4,
  }) =>
      Pool(size).run(items, mapper);
}

class PoolEvents<I> {
  void Function()? _start;
  void Function(I item)? _progress;
  void Function()? _done;
  void Function(Object error, I item)? _error;

  void start(void Function() handler) => _start = handler;
  void progress(void Function(I item) handler) => _progress = handler;
  void done(void Function() handler) => _done = handler;
  void error(void Function(Object error, I item) handler) => _error = handler;
}

class Pool {
  final int concurrency;
  late final PoolEvents on = PoolEvents();

  Pool([this.concurrency = 4]);

  Future<List<R>> run<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker,
  ) async {
    on._start?.call();
    final results = <R>[];
    final active = <Future<void>>[];

    for (final item in items) {
      late final Future<void> f;
      f = Future.sync(() => worker(item)).then((res) {
        results.add(res);
        on._progress?.call(item);
      }).catchError((Object err) {
        on._error?.call(err, item);
      }).whenComplete(() {
        active.remove(f);
      });

      active.add(f);
      if (active.length >= (concurrency > 0 ? concurrency : 1)) {
        await Future.any(active);
      }
    }

    await Future.wait(active);
    on._done?.call();
    return results;
  }

  static Future<List<R>> each<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int concurrency = 4,
  }) {
    return Pool(concurrency).run(items, worker);
  }
}
