import 'dart:math';

/// Functional extensions on [Iterable].
///
/// {@category Collections}
extension IterableExtensions<T> on Iterable<T> {
  /// Splits elements into fixed-size chunks of length [size].
  Iterable<List<T>> chunk(int size) sync* {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'Must be positive');
    var batch = <T>[];
    for (final item in this) {
      batch.add(item);
      if (batch.length == size) {
        yield batch;
        batch = <T>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// Groups elements by a computed [key].
  Map<K, List<T>> groupBy<K>(K Function(T item) key) {
    final map = <K, List<T>>{};
    for (final item in this) {
      (map[key(item)] ??= []).add(item);
    }
    return map;
  }

  /// Groups elements and counts occurrences of each [key].
  Map<K, int> countBy<K>(K Function(T item) key) {
    final map = <K, int>{};
    for (final item in this) {
      final k = key(item);
      map[k] = (map[k] ?? 0) + 1;
    }
    return map;
  }

  /// Deduplicates elements by a key extractor.
  Iterable<T> distinctBy(Object? Function(T item) key) sync* {
    final seen = <Object?>{};
    for (final item in this) {
      if (seen.add(key(item))) yield item;
    }
  }

  /// Sorts elements returning a new list.
  List<T> sorted([Comparator<T>? compare]) {
    final list = toList();
    if (compare != null) {
      list.sort(compare);
    } else {
      list.sort((a, b) => (a as Comparable).compareTo(b));
    }
    return list;
  }

  /// Sorts elements by [key], largest first when [descending] is set.
  ///
  /// [key] is evaluated once per element, not once per comparison.
  List<T> sortedBy<K extends Comparable<K>>(K Function(T item) key, {bool descending = false}) {
    final decorated = [for (final item in this) (key(item), item)]
      ..sort((a, b) => descending ? b.$1.compareTo(a.$1) : a.$1.compareTo(b.$1));
    return [for (final pair in decorated) pair.$2];
  }

  /// Sums numeric elements or mapped values.
  num sum([num Function(T item)? of]) {
    num total = 0;
    for (final item in this) {
      total += of != null ? of(item) : (item as num);
    }
    return total;
  }

  /// Averages numeric elements or mapped values in a single pass.
  double? average([num Function(T item)? of]) {
    num total = 0;
    var count = 0;
    for (final item in this) {
      total += of != null ? of(item) : (item as num);
      count++;
    }
    return count == 0 ? null : total / count;
  }

  /// The item with the largest [key], or `null` when empty.
  T? maxBy<K extends Comparable<K>>(K Function(T item) key) => _extremeBy(key, 1);

  /// The item with the smallest [key], or `null` when empty.
  T? minBy<K extends Comparable<K>>(K Function(T item) key) => _extremeBy(key, -1);

  T? _extremeBy<K extends Comparable<K>>(K Function(T item) key, int sign) {
    final it = iterator;
    if (!it.moveNext()) return null;
    var best = it.current;
    var bestKey = key(best);
    while (it.moveNext()) {
      final candidateKey = key(it.current);
      if (candidateKey.compareTo(bestKey) * sign > 0) {
        best = it.current;
        bestKey = candidateKey;
      }
    }
    return best;
  }

  /// Pairs elements from this and [other] into records.
  Iterable<(T, R)> zip<R>(Iterable<R> other) sync* {
    final itA = iterator, itB = other.iterator;
    while (itA.moveNext() && itB.moveNext()) {
      yield (itA.current, itB.current);
    }
  }
}

/// Functional extensions on [List].
extension ListExtensions<T> on List<T> {
  /// Returns a shuffled copy of this list.
  List<T> shuffled([Random? random]) => toList()..shuffle(random);
}

/// Functional extensions on [Map].
extension MapExtensions<K, V> on Map<K, V> {
  /// Merges with [other] map, resolving collisions with [resolve].
  Map<K, V> mergeWith(Map<K, V> other, V Function(V v1, V v2) resolve) {
    final result = Map<K, V>.from(this);
    for (final entry in other.entries) {
      result.update(entry.key, (existing) => resolve(existing, entry.value), ifAbsent: () => entry.value);
    }
    return result;
  }
}

/// Extensions on paired iterables.
extension IterablePairExtensions<A, B> on Iterable<(A, B)> {
  /// Splits a sequence of records into two lists.
  (List<A>, List<B>) get unzip {
    final listA = <A>[], listB = <B>[];
    for (final p in this) {
      listA.add(p.$1);
      listB.add(p.$2);
    }
    return (listA, listB);
  }
}
