import 'dart:async';

// ============================================================================
// CONCURRENT & WORKER POOL (concurrent.* / Pool)
// ============================================================================

/// Top-level concurrency accessor singleton (`concurrent.*`).
///
/// Provides convenient helpers for bounded concurrent operations:
/// ```dart
/// // Concurrently process tasks with bounded concurrency
/// final results = await concurrent.run(urls, (url) async {
///   return await net.get(url);
/// }, size: 8);
/// ```
const ConcurrentAccessor concurrent = ConcurrentAccessor();

/// Concurrency task execution namespace accessor.
class ConcurrentAccessor {
  const ConcurrentAccessor();

  /// Creates a dedicated worker [Pool] with bounded [concurrency] and optional [delay].
  ///
  /// ```dart
  /// final pool = concurrent.pool(8);
  /// pool.on.progress((url) => print('Done: $url'));
  /// await pool.run(urls, fetch);
  /// ```
  Pool pool([int concurrency = 4, Duration delay = Duration.zero]) =>
      Pool(concurrency, delay);

  /// Executes asynchronous [worker] concurrently over [items] with bounded pool [size].
  ///
  /// Returns the completed results in original input order.
  ///
  /// ```dart
  /// await concurrent.run(files, (f) => processFile(f), size: 4);
  /// ```
  Future<List<R>> run<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker, {
    int size = 4,
    Duration delay = Duration.zero,
  }) => Pool(size, delay).run(items, worker);
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

  /// Delay between task dispatches for rate limiting.
  final Duration delay;

  /// Sub-namespace for pool lifecycle event callbacks.
  late final PoolEvents<Object?> on = PoolEvents<Object?>();

  /// Creates a [Pool] with the specified [concurrency] limit (defaults to 4) and optional [delay].
  Pool([this.concurrency = 4, this.delay = Duration.zero]);

  /// Executes [worker] across all [items] maintaining at most [concurrency] in-flight tasks,
  /// strictly preserving the original item ordering in the returned results.
  Future<List<R>> run<I, R>(
    Iterable<I> items,
    FutureOr<R> Function(I item) worker,
  ) async {
    on._start?.call();
    final list = items.toList();
    final results = List<R?>.filled(list.length, null);
    final active = <Future<void>>[];

    for (var i = 0; i < list.length; i++) {
      final index = i;
      final item = list[index];
      late final Future<void> f;
      f = Future.sync(() => worker(item))
          .then((res) {
            results[index] = res;
            on._progress?.call(item);
          })
          .catchError((Object err) {
            on._error?.call(err, item);
          })
          .whenComplete(() {
            active.remove(f);
          });

      active.add(f);
      if (active.length >= (concurrency > 0 ? concurrency : 1)) {
        await Future.any(active);
      }
      if (delay > Duration.zero && i < list.length - 1) {
        await Future.delayed(delay);
      }
    }

    await Future.wait(active);
    on._done?.call();
    return List<R>.generate(list.length, (i) => results[i] as R);
  }
}
