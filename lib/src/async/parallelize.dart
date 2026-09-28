part of '../../async.dart';

/// Concurrency extensions on [Iterable] to process work in parallel.
///
/// {@category Concurrency}
extension IterableParallelExtensions<T> on Iterable<T> {
  /// Maps [worker] over all elements, at most [concurrency] at a time.
  ///
  /// Settles every task and preserves input order; an individual failure never
  /// throws. Tasks the enclosing [Cancel.scope] skipped come back as a [Left] holding a
  /// [CancelledException].
  ///
  /// [isolate] runs the work on [concurrency] background isolates, started once and fed
  /// one item at a time: the worker is copied once per isolate and each item once. An item
  /// or a result that cannot cross is that item's [Left], not everyone's. This is a [Pool]
  /// over a function; a [Worker] of your own is for state built once per isolate.
  ///
  /// ```dart
  /// final settled = await urls.parallelize(fetch);            // every outcome
  /// final pages   = (await urls.parallelize(fetch)).unwrap(); // or throw the first
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
    // One lane per worker, each taking the next index: no item waits in a queue, so a
    // hundred thousand of them cost what the work does.
    final token = Cancel.token;
    int take() => next++;
    try {
      await Future.wait([for (var i = 0; i < pool.size; i++) pool._lane(list, results, take, token)]);
    } finally {
      pool._kill(null);
    }
    return [for (final outcome in results) outcome ?? Left(_cancelledBy(token!))];
  }
}

/// Concurrency extensions on [Stream] to process items in parallel.
///
/// {@category Concurrency}
extension StreamParallelExtensions<T> on Stream<T> {
  /// Maps [worker] over stream items, emitting outcomes as they settle.
  ///
  /// An individual failure never reaches the error channel; `.unwrap()` forwards it.
  /// A paused consumer pauses the source: nothing is buffered on its behalf. The enclosing
  /// [Cancel.scope] stops it. [isolate] is what it is on [IterableParallelExtensions.parallelize]:
  /// at most [concurrency] isolates, started as work arrives and ended with the stream.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) {
    final pool = Pool<T, R>._(_factory(worker), concurrency, isolate);
    return pool._map(this, onEnd: () => pool._kill(null));
  }
}

/// The worker factory a `parallelize` pool sends to its isolates. Top level on purpose: a
/// closure written inside `parallelize` shares its context with everything else there —
/// the pool, the list, the controller — and the whole context is what an isolate copies.
Worker<T, R> Function() _factory<T, R>(FutureOr<R> Function(T item) fn) =>
    () => _Fn(fn);

/// What an operation the enclosing scope stopped throws.
CancelledException _cancelledBy(CancelToken token) =>
    CancelledException(token.reason?.toString() ?? 'Operation was cancelled.');
