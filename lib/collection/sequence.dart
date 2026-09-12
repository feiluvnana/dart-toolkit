/// # Pipelines on [Iterable]
library;

import 'collector.dart';
import 'transformer.dart';

// ============================================================================
// ITERABLE PIPELINES
// ============================================================================

/// Pipeline transformation and collection operations directly on any [Iterable].
extension IterablePipeline<T> on Iterable<T> {
  /// This iterable shaped by [step] — one [Transformer], applied lazily.
  ///
  /// Note: Prefer [IterableExtensions] (such as `sortedBy`, `unique`, `chunk`, `mapNotNull`)
  /// or native Dart 3 collection methods directly.
  Iterable<R> transform<R>(Transformer<T, R> step) =>
      _Deferred(() => step.run(this));

  /// This iterable reduced by [step] — one [Collector], applied.
  ///
  /// Note: Prefer [IterableExtensions] / [IterableTerminals] (such as `sum`, `average`, `maxBy`,
  /// `groupBy`, `split`, `countBy`) or native Dart 3 collection methods directly.
  R collect<R>(Collector<T, R> step) => step.run(this);

  /// Convenience getter returning this iterable directly.
  Iterable<T> get seq => this;
}

/// The iterable a [transform] hands forward: it calls [_build] once
/// per walk, and never before the first one.
class _Deferred<T> extends Iterable<T> {
  const _Deferred(this._build);

  final Iterable<T> Function() _build;

  @override
  Iterator<T> get iterator => _build().iterator;
}


/// Splitting an iterable of pairs back into two.
extension PairedIterable<A, B> on Iterable<(A, B)> {
  /// The first and second halves of every pair, as two iterables.
  (Iterable<A>, Iterable<B>) get unzip => (map((p) => p.$1), map((p) => p.$2));
}
