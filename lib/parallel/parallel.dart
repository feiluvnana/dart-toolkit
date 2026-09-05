import 'dart:async';

// ============================================================================
// PARALLEL & CONCURRENCY POOL (parallel.* / Pool)
// ============================================================================

/// Top-level parallel task execution accessor singleton.
///
/// Provides convenient helpers for bounded concurrent operations:
/// ```dart
/// // Concurrently process tasks with bounded concurrency
/// final results = await parallel.run(urls, (url) async {
///   return await http.get(Uri.parse(url));
/// }, size: 8);
///
/// // Concurrently map items
/// final images = await parallel.map(items, (item) => download(item));
/// ```
const ParallelAccessor parallel = ParallelAccessor();

/// Parallel task execution namespace accessor.
class ParallelAccessor {
  const ParallelAccessor();

  /// Creates a dedicated worker [Pool] with bounded [concurrency].
  ///
  /// ```dart
  /// final pool = parallel.pool(8);
  /// pool.on.progress((url) => print('Done: $url'));
  /// await pool.run(urls, fetch);
  /// ```
  Pool pool([int concurrency = 4]) => Pool(concurrency);

  /// Executes asynchronous [worker] concurrently over [items] with bounded pool [size].
  ///
  /// Returns the completed results in execution order.
  ///
  /// ```dart
  /// await parallel.run(files, (f) => processFile(f), size: 4);
  /// ```
  Future<List<R>> run<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
  }) =>
      Pool(size).run(items, worker);

  /// Concurrently iterates over [items] with bounded pool [size].
  ///
  /// Alias for [run].
  Future<List<R>> each<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
  }) =>
      Pool(size).run(items, worker);

  /// Concurrently transforms [items] to results with bounded pool [size].
  ///
  /// Alias for [run].
  Future<List<R>> map<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) mapper, {
    int size = 4,
  }) =>
      Pool(size).run(items, mapper);
}

/// Event callbacks for pool execution lifecycle (`pool.on.*`).
class PoolEvents<I> {
  void Function()? _start;
  void Function(I item)? _progress;
  void Function()? _done;
  void Function(Object error, I item)? _error;

  /// Registers a callback triggered when the pool begins processing items.
  void start(void Function() handler) => _start = handler;

  /// Registers a callback triggered each time a single item completes.
  void progress(void Function(I item) handler) => _progress = handler;

  /// Registers a callback triggered when all items have finished.
  void done(void Function() handler) => _done = handler;

  /// Registers a callback triggered when an item processing error occurs.
  void error(void Function(Object error, I item) handler) => _error = handler;
}

/// Concurrency limiter that processes tasks with at most [concurrency] simultaneous futures.
class Pool {
  /// Maximum number of tasks executed concurrently.
  final int concurrency;

  /// Sub-namespace for pool lifecycle event callbacks.
  late final PoolEvents on = PoolEvents();

  /// Creates a [Pool] with the specified [concurrency] limit (defaults to 4).
  Pool([this.concurrency = 4]);

  /// Executes [worker] across all [items] maintaining at most [concurrency] in-flight tasks.
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

  /// Concurrently executes [worker] across [items] with static convenience method.
  static Future<List<R>> each<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int concurrency = 4,
  }) {
    return Pool(concurrency).run(items, worker);
  }
}
