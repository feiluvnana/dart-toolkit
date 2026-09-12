/// # Map Extensions (`MapExtensions`)
///
/// Fluent, zero-allocation transformations and utilities on [Map].
library;

/// Fluent transformations on any [Map].
extension MapExtensions<K, V> on Map<K, V> {
  /// Filters entries by [test], returning a new Map.
  Map<K, V> filter(bool Function(K key, V value) test) {
    final result = <K, V>{};
    for (final entry in entries) {
      if (test(entry.key, entry.value)) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Filters entries by key predicate.
  Map<K, V> filterKeys(bool Function(K key) test) =>
      filter((k, _) => test(k));

  /// Filters entries by value predicate.
  Map<K, V> filterValues(bool Function(V value) test) =>
      filter((_, v) => test(v));

  /// Transforms values while keeping keys intact.
  Map<K, V2> mapValues<V2>(V2 Function(K key, V value) transform) {
    final result = <K, V2>{};
    for (final entry in entries) {
      result[entry.key] = transform(entry.key, entry.value);
    }
    return result;
  }

  /// Transforms keys while keeping values intact.
  Map<K2, V> mapKeys<K2>(K2 Function(K key, V value) transform) {
    final result = <K2, V>{};
    for (final entry in entries) {
      result[transform(entry.key, entry.value)] = entry.value;
    }
    return result;
  }

  /// Returns a new Map retaining only the specified [keys].
  Map<K, V> pick(Iterable<K> keys) {
    final keySet = keys.toSet();
    return filter((k, _) => keySet.contains(k));
  }

  /// Returns a new Map omitting the specified [keys].
  Map<K, V> omit(Iterable<K> keys) {
    final keySet = keys.toSet();
    return filter((k, _) => !keySet.contains(k));
  }

  /// Merges [other] into a new Map with optional [onConflict] resolution.
  Map<K, V> merge(
    Map<K, V> other, {
    V Function(V existing, V incoming)? onConflict,
  }) {
    final result = Map<K, V>.of(this);
    for (final entry in other.entries) {
      if (result.containsKey(entry.key) && onConflict != null) {
        result[entry.key] = onConflict(result[entry.key] as V, entry.value);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Returns a new Map sorted by key.
  Map<K, V> sortedByKey([Comparator<K>? compare]) {
    final sortedKeys = keys.toList()..sort(compare);
    return {for (final k in sortedKeys) k: this[k] as V};
  }

  /// Returns a new Map sorted by value.
  Map<K, V> sortedByValue([Comparator<V>? compare]) {
    final sortedEntries =
        entries.toList()..sort((a, b) {
          if (compare != null) return compare(a.value, b.value);
          return (a.value as Comparable).compareTo(b.value);
        });
    return {for (final e in sortedEntries) e.key: e.value};
  }

  /// Returns (key, value) pairs as an Iterable of records.
  Iterable<(K, V)> get pairs => entries.map((e) => (e.key, e.value));

  /// Inverts the map: values become keys mapping to lists of original keys.
  Map<V, List<K>> invert() {
    final result = <V, List<K>>{};
    for (final entry in entries) {
      result.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    return result;
  }
}
