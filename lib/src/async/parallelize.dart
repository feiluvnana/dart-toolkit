part of '../../async.dart';

/// Bounded parallel map over an [Iterable].
///
/// {@category Concurrency}
extension IterableParallelExtensions<T> on Iterable<T> {
  /// Maps [worker] over all elements, at most [concurrency] at a time.
  ///
  /// Settles every task in input order; a failure is that item's [Left], never a throw, and an
  /// item the enclosing [Cancel.scope] skipped is a [Left] of [CancelledException].
  ///
  /// [isolate] runs the work on up to [concurrency] isolates, started once; the worker is copied
  /// once per isolate. For state built once per isolate, use a [Worker] in a [Pool].
  ///
  /// ```dart
  /// final settled = await urls.parallelize(fetch);          // every outcome
  /// final pages   = await urls.parallelize(fetch).unwrap(); // or throw the first
  /// ```
  Future<List<Either<Object, R>>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];
    final pool = Pool<T, R>._(_factory(worker), min(concurrency, list.length), isolate);
    final results = List<Either<Object, R>?>.filled(list.length, null);
    var next = 0;
    // One lane per worker, each taking the next index: no per-item queue.
    final token = Cancel.token;
    int take() => next++;
    try {
      await Future.wait([for (var i = 0; i < pool.size; i++) pool._lane(list, results, take, token)]);
    } finally {
      pool._kill(null);
    }
    return [
      for (final outcome in results)
        outcome ?? Left(token != null ? _cancelledBy(token) : const CancelledException('Operation was aborted.')),
    ];
  }
}

/// Bounded parallel map over a [Stream].
///
/// {@category Concurrency}
extension StreamParallelExtensions<T> on Stream<T> {
  /// Maps [worker] over stream items, emitting outcomes as they settle.
  ///
  /// A failure is a [Left], never an error event (`.unwrap()` forwards it). Pausing the consumer
  /// pauses the source; the enclosing [Cancel.scope] stops it. [isolate] starts up to
  /// [concurrency] isolates as work arrives and ends them with the stream.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) {
    final pool = Pool<T, R>._(_factory(worker), concurrency, isolate);
    return pool._map(this, onEnd: () => pool._kill(null));
  }
}

/// Top level on purpose: a closure built inside `parallelize` would capture (and send to every
/// isolate) its whole context.
Worker<T, R> Function() _factory<T, R>(FutureOr<R> Function(T item) fn) =>
    () => _Fn(fn);

CancelledException _cancelledBy(CancelToken token) =>
    CancelledException(token.reason?.toString() ?? 'Operation was cancelled.');
