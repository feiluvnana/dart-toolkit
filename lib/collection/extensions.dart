import 'dart:math';

/// Functional extensions on [Iterable].
extension CollectionIterableExtensions<T> on Iterable<T> {
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
      map.putIfAbsent(key(item), () => []).add(item);
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

  /// Sorts elements by [key] in ascending order.
  List<T> sortedBy<K extends Comparable<K>>(K Function(T item) key) {
    final list = toList();
    list.sort((a, b) => key(a).compareTo(key(b)));
    return list;
  }

  /// Sorts elements by [key] in descending order.
  List<T> sortedByDescending<K extends Comparable<K>>(K Function(T item) key) {
    final list = toList();
    list.sort((a, b) => key(b).compareTo(key(a)));
    return list;
  }

  /// Sums numeric elements or mapped values.
  num sum([num Function(T item)? of]) {
    num total = 0;
    for (final item in this) {
      total += of != null ? of(item) : (item as num);
    }
    return total;
  }

  /// Averages numeric elements or mapped values.
  double? average([num Function(T item)? of]) => isEmpty ? null : sum(of) / length;

  /// Returns the item with the largest [key], or `null` if empty.
  T? maxByOrNull<K extends Comparable<K>>(K Function(T item) key) {
    final it = iterator;
    if (!it.moveNext()) return null;
    var maxItem = it.current;
    while (it.moveNext()) {
      if (key(it.current).compareTo(key(maxItem)) > 0) maxItem = it.current;
    }
    return maxItem;
  }

  /// Returns the item with the smallest [key], or `null` if empty.
  T? minByOrNull<K extends Comparable<K>>(K Function(T item) key) {
    final it = iterator;
    if (!it.moveNext()) return null;
    var minItem = it.current;
    while (it.moveNext()) {
      if (key(it.current).compareTo(key(minItem)) < 0) minItem = it.current;
    }
    return minItem;
  }

  /// Pairs elements from this and [other] into records.
  Iterable<(T, R)> zip<R>(Iterable<R> other) sync* {
    final itA = iterator, itB = other.iterator;
    while (itA.moveNext() && itB.moveNext()) {
      yield (itA.current, itB.current);
    }
  }

  /// Maps elements with index access.
  Iterable<R> mapIndexed<R>(R Function(int index, T item) transform) sync* {
    var i = 0;
    for (final item in this) {
      yield transform(i, item);
      i++;
    }
  }
}

/// Functional extensions on [List].
extension CollectionListExtensions<T> on List<T> {
  /// Returns the element at [index], or `null` if out of bounds.
  T? getOrNull(int index) => index >= 0 && index < length ? this[index] : null;

  /// Returns a shuffled copy of this list.
  List<T> shuffled([Random? random]) => toList()..shuffle(random);
}

/// Functional extensions on [Map].
extension CollectionMapExtensions<K, V> on Map<K, V> {
  /// Merges with [other] map, resolving collisions with [resolve].
  Map<K, V> mergeWith(Map<K, V> other, V Function(V v1, V v2) resolve) {
    final result = Map<K, V>.from(this);
    for (final entry in other.entries) {
      if (result.containsKey(entry.key)) {
        result[entry.key] = resolve(result[entry.key] as V, entry.value);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }
}

/// Extensions on paired iterables.
extension PairedIterable<A, B> on Iterable<(A, B)> {
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
