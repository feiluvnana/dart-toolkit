/// # Pipelines on [Map]
library;

import 'collector.dart';
import 'map_extensions.dart';
import 'transformer.dart';

export 'map_extensions.dart';

// ============================================================================
// MAP PIPELINES
// ============================================================================

/// Pipeline transformation and collection operations directly on any [Map].
extension MapPipeline<K, V> on Map<K, V> {
  /// This map shaped by [step], over its `(key, value)` records.
  Map<K2, V2> transform<K2, V2>(Transformer<(K, V), (K2, V2)> step) => {
    for (final (k, v) in step.run(pairs)) k: v,
  };

  /// This map reduced by [step], over its `(key, value)` records.
  R collect<R>(Collector<(K, V), R> step) => step.run(pairs);

  /// Convenience getter returning this map directly.
  Map<K, V> get dict => this;
}
