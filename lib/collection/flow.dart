/// # Pipelines on [Stream]
library;

import 'dart:async';

import 'pipe.dart';

// ============================================================================
// STREAM PIPELINES
// ============================================================================

/// Pipeline transformation and collection operations directly on any [Stream].
extension StreamPipeline<T> on Stream<T> {
  /// This stream shaped by [step] — one [Pipe], applied lazily.
  Stream<R> through<R>(Pipe<T, R> step) => step.run(this);

  /// This stream reduced by [step] — one [Pour], applied at the end.
  Future<R> collect<R>(Pour<T, R> step) => step.run(this);

  /// Convenience getter returning this stream directly.
  Stream<T> get flow => this;
}

/// Turns any iterable into a [Stream].
extension FlowedIterable<T> on Iterable<T> {
  /// These elements as a [Stream], walked only once listened to.
  Stream<T> get flow => Stream<T>.fromIterable(this);
}
