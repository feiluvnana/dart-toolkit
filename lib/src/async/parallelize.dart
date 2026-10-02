part of '../../async.dart';

/// Bounded parallel map over an [Iterable].
///
/// {@category Concurrency}
extension IterableParallelExtensions<T> on Iterable<T> {
  /// Maps [worker] over all elements, at most [concurrency] at a time, emitting outcomes
  /// on a [Stream] as they settle.
  ///
  /// Pass `ordered: true` to emit in input order instead of completion order.
  ///
  /// [isolate] runs the work on up to [concurrency] isolates, started once; the worker is copied
  /// once per isolate. For state built once per isolate, use a [Worker] in a [Pool].
  ///
  /// ```dart
  /// await for (final page in urls.parallelize(fetch).rights) { ... }
  /// final list = await urls.parallelize(fetch).toList();
  /// ```
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    bool ordered = false,
  }) => Stream.fromIterable(this).parallelize(worker, concurrency: concurrency, isolate: isolate, ordered: ordered);
}

/// Bounded parallel map over a [Stream].
///
/// {@category Concurrency}
extension StreamParallelExtensions<T> on Stream<T> {
  /// Maps [worker] over stream items, emitting outcomes as they settle.
  ///
  /// Pass `ordered: true` to emit in input order instead of completion order.
  ///
  /// A failure is a [Left], never an error event (`.unwrap()` forwards it). Pausing the consumer
  /// pauses the source; the enclosing [Cancel.scope] stops it. [isolate] starts up to
  /// [concurrency] isolates as work arrives and ends them with the stream.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    bool ordered = false,
  }) {
    final pool = Pool<T, R>._(_factory(worker), concurrency, isolate);
    return pool._map(this, ordered: ordered, onEnd: () => pool._kill(null));
  }
}

/// Top level on purpose: a closure built inside `parallelize` would capture (and send to every
/// isolate) its whole context.
Worker<T, R> Function() _factory<T, R>(FutureOr<R> Function(T item) fn) =>
    () => _Fn(fn);

CancelledException _cancelledBy(CancelToken token) =>
    CancelledException(token.reason?.toString() ?? 'Operation was cancelled.');
