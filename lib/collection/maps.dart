/// # Map factories
///
/// Building a [Map] from something that is not one, and comparing two: the
/// operations that have no receiver to hang off, so they are not extension
/// methods on [Map].
///
/// Anything that *does* have a receiver is an extension instead — see
/// [MapExtensions] for `merge`, `invert`, `pick`, `omit` and the rest, and
/// `groupBy` for grouping an iterable.
library;

import 'map_extensions.dart';

/// Static utility functions for creating and manipulating [Map]s.
abstract final class Maps {
  Maps._();

  /// Builds a Map from (key, value) record pairs.
  static Map<K, V> fromPairs<K, V>(Iterable<(K, V)> pairs) => {
    for (final (k, v) in pairs) k: v,
  };

  /// Builds a Map by extracting keys and values from [items].
  static Map<K, V> fromIterable<T, K, V>(
    Iterable<T> items, {
    required K Function(T item) key,
    required V Function(T item) value,
  }) => {for (final item in items) key(item): value(item)};

  /// Groups [items] by extracted key and maps each value.
  static Map<K, List<V>> groupBy<T, K, V>(
    Iterable<T> items, {
    required K Function(T item) keyOf,
    required V Function(T item) valueOf,
  }) {
    final map = <K, List<V>>{};
    for (final item in items) {
      map.putIfAbsent(keyOf(item), () => []).add(valueOf(item));
    }
    return map;
  }

  /// Merges [maps] left to right into one, applying [onConflict] on collisions.
  ///
  /// The binary form is the `merge` extension on [Map]; this is the n-ary one.
  static Map<K, V> merge<K, V>(
    Iterable<Map<K, V>> maps, {
    V Function(V existing, V incoming)? onConflict,
  }) => maps.fold(
    <K, V>{},
    (result, map) => result.merged(map, onConflict: onConflict),
  );

  /// Zips keys and values into a Map.
  static Map<K, V> zip<K, V>(Iterable<K> keys, Iterable<V> values) {
    final iterK = keys.iterator;
    final iterV = values.iterator;
    final result = <K, V>{};
    while (iterK.moveNext() && iterV.moveNext()) {
      result[iterK.current] = iterV.current;
    }
    return result;
  }

  /// Computes the difference between map [a] and map [b].
  static MapDiff<K, V> diff<K, V>(Map<K, V> a, Map<K, V> b) {
    final added = <K, V>{};
    final removed = <K, V>{};
    final changed = <K, (V, V)>{};
    final unchanged = <K, V>{};

    for (final entry in b.entries) {
      if (!a.containsKey(entry.key)) {
        added[entry.key] = entry.value;
      } else if (a[entry.key] != entry.value) {
        changed[entry.key] = (a[entry.key] as V, entry.value);
      } else {
        unchanged[entry.key] = entry.value;
      }
    }
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) {
        removed[entry.key] = entry.value;
      }
    }
    return MapDiff(
      added: added,
      removed: removed,
      changed: changed,
      unchanged: unchanged,
    );
  }
}

/// Diff result representation between two maps.
final class MapDiff<K, V> {
  /// Entries present in the new map but absent in the original map.
  final Map<K, V> added;

  /// Entries present in the original map but absent in the new map.
  final Map<K, V> removed;

  /// Entries whose value changed from original to new `(oldValue, newValue)`.
  final Map<K, (V, V)> changed;

  /// Entries whose key and value are identical in both maps.
  final Map<K, V> unchanged;

  /// Creates a [MapDiff].
  const MapDiff({
    required this.added,
    required this.removed,
    required this.changed,
    required this.unchanged,
  });

  /// Whether any added, removed, or changed differences exist.
  bool get hasChanges =>
      added.isNotEmpty || removed.isNotEmpty || changed.isNotEmpty;
}
