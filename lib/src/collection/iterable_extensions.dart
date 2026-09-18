part of '../../collection.dart';

/// Querying and reshaping an [Iterable], in the vocabulary Kotlin settled on: a verb with `By`
/// takes a key selector, an adjective (`sorted`, `distinct`, `shuffled`) returns a new
/// collection, and what the SDK already has — `where`, `map`, `expand`, `fold`, `indexed`,
/// `firstOrNull`, `nonNulls` — is not repeated here.
///
/// ```dart
/// final byDisc = tracks.groupBy((t) => t.disc).mapValues((ts) => ts.sortedBy((t) => t.number));
/// final (long, short) = tracks.partition((t) => t.length > 5.m);
/// for (final (disc, list) in byDisc.records) print('$disc: ${list.length}');
/// ```
///
/// {@category Collections}
extension IterableExtensions<T> on Iterable<T> {
  /// Fixed-size runs of [size]; the last one may be short.
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

  /// Sliding windows of [size], advancing by [step]; a trailing short window only when [partial].
  Iterable<List<T>> windowed(int size, {int step = 1, bool partial = false}) sync* {
    if (size <= 0 || step <= 0) throw ArgumentError('size and step must be positive');
    final list = toList();
    for (var i = 0; i < list.length; i += step) {
      final end = i + size;
      if (end <= list.length) {
        yield list.sublist(i, end);
      } else {
        if (partial) yield list.sublist(i);
        break;
      }
    }
  }

  /// Elements grouped by [key], in first-seen order.
  Map<K, List<T>> groupBy<K>(K Function(T item) key) {
    final map = <K, List<T>>{};
    for (final item in this) {
      (map[key(item)] ??= []).add(item);
    }
    return map;
  }

  /// How many elements share each [key].
  Map<K, int> countBy<K>(K Function(T item) key) {
    final map = <K, int>{};
    for (final item in this) {
      map.update(key(item), (n) => n + 1, ifAbsent: () => 1);
    }
    return map;
  }

  /// A map from [key] to the last element with that key.
  Map<K, T> indexBy<K>(K Function(T item) key) => {for (final item in this) key(item): item};

  /// Elements that pass [test], and those that do not, in order.
  (List<T> matching, List<T> rest) partition(bool Function(T item) test) {
    final yes = <T>[], no = <T>[];
    for (final item in this) {
      (test(item) ? yes : no).add(item);
    }
    return (yes, no);
  }

  /// Each element once, by `==`, in first-seen order.
  List<T> get distinct => {...this}.toList();

  /// Each [key] once, keeping the first element that had it.
  Iterable<T> distinctBy(Object? Function(T item) key) sync* {
    final seen = <Object?>{};
    for (final item in this) {
      if (seen.add(key(item))) yield item;
    }
  }

  /// A sorted copy, by [compare] or natural order.
  List<T> sorted([Comparator<T>? compare]) =>
      toList()..sort(compare ?? (a, b) => (a as Comparable<Object?>).compareTo(b));

  /// A copy sorted by [key], largest first when [descending]. [key] runs once per element.
  List<T> sortedBy<K extends Comparable<K>>(K Function(T item) key, {bool descending = false}) {
    final decorated = [for (final item in this) (key(item), item)]
      ..sort((a, b) => descending ? b.$1.compareTo(a.$1) : a.$1.compareTo(b.$1));
    return [for (final pair in decorated) pair.$2];
  }

  /// The sum of the elements, or of [of] applied to each.
  num sum([num Function(T item)? of]) {
    num total = 0;
    for (final item in this) {
      total += of != null ? of(item) : (item as num);
    }
    return total;
  }

  /// The mean of the elements, or of [of] applied to each; `null` when empty.
  double? average([num Function(T item)? of]) {
    num total = 0;
    var count = 0;
    for (final item in this) {
      total += of != null ? of(item) : (item as num);
      count++;
    }
    return count == 0 ? null : total / count;
  }

  /// The element with the largest [key], or `null` when empty.
  T? maxBy<K extends Comparable<K>>(K Function(T item) key) => _extremeBy(key, 1);

  /// The element with the smallest [key], or `null` when empty.
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

  /// The last [n] elements.
  List<T> takeLast(int n) {
    final list = toList();
    return n >= list.length ? list : list.sublist(list.length - n);
  }

  /// Everything but the last [n] elements.
  List<T> skipLast(int n) {
    final list = toList();
    return n >= list.length ? <T>[] : list.sublist(0, list.length - n);
  }

  /// Whether no element passes [test].
  bool none(bool Function(T item) test) => !any(test);

  /// Elements paired with [other]'s, stopping at the shorter.
  Iterable<(T, R)> zip<R>(Iterable<R> other) sync* {
    final itA = iterator, itB = other.iterator;
    while (itA.moveNext() && itB.moveNext()) {
      yield (itA.current, itB.current);
    }
  }
}

/// {@category Collections}
extension IterableIterableExtensions<T> on Iterable<Iterable<T>> {
  /// One level of nesting removed.
  Iterable<T> get flattened => expand((e) => e);
}

/// Records as key-value pairs.
///
/// {@category Collections}
extension IterablePairExtensions<A, B> on Iterable<(A, B)> {
  /// Two lists from a sequence of pairs.
  (List<A>, List<B>) get unzip {
    final listA = <A>[], listB = <B>[];
    for (final p in this) {
      listA.add(p.$1);
      listB.add(p.$2);
    }
    return (listA, listB);
  }

  /// A map from the pairs; a later key wins.
  Map<A, B> toMap() => {for (final (k, v) in this) k: v};
}

/// {@category Collections}
extension ListExtensions<T> on List<T> {
  /// A shuffled copy.
  List<T> shuffled([Random? random]) => toList()..shuffle(random);
}

/// Querying and reshaping a [Map]; every result is a new map, the receiver is untouched.
///
/// {@category Collections}
extension MapExtensions<K, V> on Map<K, V> {
  /// The entries as records, for `for (final (k, v) in map.records)`.
  Iterable<(K, V)> get records => entries.map((e) => (e.key, e.value));

  /// Only the entries that pass [test].
  Map<K, V> where(bool Function(K key, V value) test) => {
    for (final MapEntry(:key, :value) in entries)
      if (test(key, value)) key: value,
  };

  /// The same keys, values through [transform].
  Map<K, R> mapValues<R>(R Function(V value) transform) => {
    for (final MapEntry(:key, :value) in entries) key: transform(value),
  };

  /// The same values, keys through [transform]; a later key wins a collision.
  Map<R, V> mapKeys<R>(R Function(K key) transform) => {
    for (final MapEntry(:key, :value) in entries) transform(key): value,
  };

  /// Values as keys and keys as values; a later value wins a collision.
  Map<V, K> get inverted => {for (final MapEntry(:key, :value) in entries) value: key};

  /// This map with [other]'s entries added; [resolve] settles a key both have.
  Map<K, V> mergeWith(Map<K, V> other, V Function(V mine, V theirs) resolve) {
    final result = Map<K, V>.of(this);
    for (final MapEntry(:key, :value) in other.entries) {
      result.update(key, (existing) => resolve(existing, value), ifAbsent: () => value);
    }
    return result;
  }
}
