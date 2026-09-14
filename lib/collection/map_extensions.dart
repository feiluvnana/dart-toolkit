/// # Map Extensions (`MapExtensions`)
///
/// Fluent, zero-allocation transformations and utilities on [Map].
library;

/// Fluent transformations on any [Map].
extension MapExtensions<K, V> on Map<K, V> {
  /// A new map holding only the entries [test] accepts.
  ///
  /// Named for `Iterable.where`, and matching `Map.removeWhere`, which is the
  /// mutating half `dart:core` already has. It was `filter` through 8.1.0.
  Map<K, V> where(bool Function(K key, V value) test) {
    final result = <K, V>{};
    for (final entry in entries) {
      if (test(entry.key, entry.value)) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Filters entries by key predicate.
  Map<K, V> whereKey(bool Function(K key) test) => where((k, _) => test(k));

  /// Filters entries by value predicate.
  Map<K, V> whereValue(bool Function(V value) test) => where((_, v) => test(v));

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

  /// A new map holding only [keys].
  ///
  /// `pick` and `omit` were lodash's words through 8.1.0, and `pick` already
  /// meant two other things in this package — choosing at a prompt, and
  /// reading a typed field off a page.
  Map<K, V> only(Iterable<K> keys) {
    final wanted = keys.toSet();
    return where((k, _) => wanted.contains(k));
  }

  /// A new map holding everything but [keys].
  Map<K, V> except(Iterable<K> keys) {
    final unwanted = keys.toSet();
    return where((k, _) => !unwanted.contains(k));
  }

  /// A new map with [other] laid over this one.
  ///
  /// **`merged`, not `merge`** — `Map.addAll` is the merge that mutates, and
  /// the two must not be confusable at a glance. [onConflict] decides what a
  /// key held by both becomes; without it, [other] wins.
  Map<K, V> merged(
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
    final sortedEntries = entries.toList()
      ..sort((a, b) {
        if (compare != null) return compare(a.value, b.value);
        return (a.value as Comparable).compareTo(b.value);
      });
    return {for (final e in sortedEntries) e.key: e.value};
  }

  /// Returns (key, value) pairs as an Iterable of records.
  Iterable<(K, V)> get pairs => entries.map((e) => (e.key, e.value));

  /// A new map with values as keys, each mapping to the keys that held it.
  ///
  /// An adjective, not an imperative: nothing here is mutated.
  Map<V, List<K>> inverted() {
    final result = <V, List<K>>{};
    for (final entry in entries) {
      result.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    return result;
  }
}
