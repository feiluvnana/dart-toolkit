import 'dart:async';

/// The work for one kind of item, with setup: [init] once per worker isolate,
/// [run] once per item.
///
/// A [Worker] must be cheap to build on another isolate: its factory (e.g.
/// `Thumbnail.new`) is copied to the isolate, so it must be a top-level
/// function or static tear-off holding nothing else (r58). Items and values
/// cross isolates, so they must be sendable (`String`, numbers, lists, maps).
///
/// ```dart
/// final class Upper extends Worker<String, String> {
///   @override
///   String run(String item) => item.toUpperCase();
/// }
///
/// final pool = Pool(Upper.new, concurrency: 4);
/// final out = await pool.run('hello');
/// await pool.close();
/// ```
abstract class Worker<I, T> {
  const Worker();

  /// Sets this worker up, once, before its first item on each isolate.
  FutureOr<void> init() {}

  /// The work for one [item].
  FutureOr<T> run(I item);
}
