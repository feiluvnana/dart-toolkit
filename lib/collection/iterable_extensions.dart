/// # Iterable Extensions (`IterableExtensions`)
///
/// Fluent, zero-allocation transformations and terminals on [Iterable].
library;

import 'dart:async';

import '../concurrent/concurrent.dart' as conc;

/// Fluent transformations on any [Iterable].
extension IterableExtensions<T> on Iterable<T> {
  /// Maps [worker] concurrently over elements with at most [concurrency] in flight.
  Future<List<R>> parallelMap<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? progress,
  }) => conc.parallelMap(
    this,
    worker,
    concurrency: concurrency,
    delay: delay,
    progress: progress,
  );

  /// Maps [worker] concurrently over elements with at most [concurrency] in flight,
  /// collecting both successes ([Done]) and failures ([Broke]) without throwing.
  Future<List<conc.Settled<R>>> settle<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? progress,
  }) => conc.settle(
    this,
    worker,
    concurrency: concurrency,
    delay: delay,
    progress: progress,
  );

  /// Idiomatic, Kotlin-style alias for [where].
  Iterable<T> filter(bool Function(T) test) => where(test);

  /// Transforms elements, silently discarding null results.
  Iterable<R> mapNotNull<R>(R? Function(T) f) sync* {
    for (final element in this) {
      final res = f(element);
      if (res != null) yield res;
    }
  }

  /// Maps each element to an iterable and flattens the result.
  Iterable<R> flatMap<R>(Iterable<R> Function(T) f) => expand(f);

  /// Returns a new list sorted by [compare] or natural order.
  List<T> sorted([Comparator<T>? compare]) {
    final list = toList();
    if (compare != null) {
      list.sort(compare);
    } else {
      list.sort((a, b) => (a as Comparable).compareTo(b));
    }
    return list;
  }

  /// Returns a new list sorted ascending by comparable [key].
  List<T> sortedBy<K extends Comparable<K>>(K Function(T) key) {
    final list = toList();
    list.sort((a, b) => key(a).compareTo(key(b)));
    return list;
  }

  /// Returns a new list sorted descending by comparable [key].
  List<T> sortedByDescending<K extends Comparable<K>>(K Function(T) key) {
    final list = toList();
    list.sort((a, b) => key(b).compareTo(key(a)));
    return list;
  }

  /// Deduplicates elements, optionally by extracted key.
  Iterable<T> distinct([Object? Function(T)? by]) sync* {
    final seen = <Object?>{};
    for (final element in this) {
      final key = by != null ? by(element) : element;
      if (seen.add(key)) {
        yield element;
      }
    }
  }

  /// Alias for [distinct].
  Iterable<T> unique([Object? Function(T)? by]) => distinct(by);

  /// Batches elements into fixed-size lists.
  Iterable<List<T>> chunk(int size) sync* {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'must be positive');
    var batch = <T>[];
    for (final element in this) {
      batch.add(element);
      if (batch.length == size) {
        yield batch;
        batch = <T>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// Sliding window of elements of length [size].
  Iterable<List<T>> window(int size, {int step = 1}) sync* {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'must be positive');
    if (step <= 0) throw ArgumentError.value(step, 'step', 'must be positive');
    final list = toList();
    for (var i = 0; i + size <= list.length; i += step) {
      yield list.sublist(i, i + size);
    }
  }

  /// Combines pairs of elements from two iterables into records.
  Iterable<(T, R)> zip<R>(Iterable<R> other) sync* {
    final iterA = iterator;
    final iterB = other.iterator;
    while (iterA.moveNext() && iterB.moveNext()) {
      yield (iterA.current, iterB.current);
    }
  }

  /// Combines pairs of elements from two iterables with a [combiner].
  Iterable<V> zipWith<R, V>(
    Iterable<R> other,
    V Function(T a, R b) combiner,
  ) sync* {
    final iterA = iterator;
    final iterB = other.iterator;
    while (iterA.moveNext() && iterB.moveNext()) {
      yield combiner(iterA.current, iterB.current);
    }
  }

  /// Appends [other] sequentially.
  Iterable<T> concat(Iterable<T> other) sync* {
    yield* this;
    yield* other;
  }

  /// Retains elements present in both this and [other].
  Set<T> intersect(Iterable<T> other) {
    final otherSet = other.toSet();
    return toSet().intersection(otherSet);
  }

  /// Returns elements in this not present in [other].
  List<T> minus(Iterable<T> other) {
    final otherSet = other.toSet();
    return where((x) => !otherSet.contains(x)).toList();
  }

  /// Reverses the elements.
  Iterable<T> get reversed => toList().reversed;

  /// Executes side-effect for each item lazily without modifying flow.
  Iterable<T> tap(void Function(T) action) sync* {
    for (final element in this) {
      action(element);
      yield element;
    }
  }
}

/// Null-filtering on nullable iterables.
extension NullableIterableExtensions<T extends Object> on Iterable<T?> {
  /// Returns only the non-null elements as an `Iterable<T>`.
  Iterable<T> whereNotNull() sync* {
    for (final element in this) {
      if (element != null) yield element;
    }
  }

  /// Ergonomic getter alias for [whereNotNull].
  Iterable<T> get nonNull => whereNotNull();
}

/// Fluent terminal operations on [Iterable].
extension IterableTerminals<T> on Iterable<T> {
  /// Counts elements, optionally matching [predicate].
  int count([bool Function(T item)? predicate]) {
    if (predicate == null) return length;
    var n = 0;
    for (final item in this) {
      if (predicate(item)) n++;
    }
    return n;
  }

  /// Sum of numeric elements or selector values.
  num sum([num Function(T item)? of]) {
    num total = 0;
    for (final item in this) {
      total += of != null ? of(item) : (item as num);
    }
    return total;
  }

  /// Arithmetic mean of elements or null if empty.
  double? average([num Function(T item)? of]) {
    if (isEmpty) return null;
    return sum(of) / length;
  }

  /// Maximum element according to [compare] or natural order.
  T? max([Comparator<T>? compare]) {
    final iter = iterator;
    if (!iter.moveNext()) return null;
    var maxVal = iter.current;
    while (iter.moveNext()) {
      final curr = iter.current;
      final cmp =
          compare != null
              ? compare(curr, maxVal)
              : (curr as Comparable).compareTo(maxVal);
      if (cmp > 0) maxVal = curr;
    }
    return maxVal;
  }

  /// Minimum element according to [compare] or natural order.
  T? min([Comparator<T>? compare]) {
    final iter = iterator;
    if (!iter.moveNext()) return null;
    var minVal = iter.current;
    while (iter.moveNext()) {
      final curr = iter.current;
      final cmp =
          compare != null
              ? compare(curr, minVal)
              : (curr as Comparable).compareTo(minVal);
      if (cmp < 0) minVal = curr;
    }
    return minVal;
  }

  /// Maximum element selected by comparable key [key].
  T? maxBy<K extends Comparable<K>>(K Function(T item) key) {
    return max((a, b) => key(a).compareTo(key(b)));
  }

  /// Minimum element selected by comparable key [key].
  T? minBy<K extends Comparable<K>>(K Function(T item) key) {
    return min((a, b) => key(a).compareTo(key(b)));
  }

  /// Converts this iterable into a Map by key and value extractors.
  Map<K, V> toMap<K, V>({
    required K Function(T item) key,
    required V Function(T item) value,
  }) => {for (final item in this) key(item): value(item)};

  /// Creates a Map associating each item by extracted [key].
  Map<K, T> associateBy<K>(K Function(T item) key) =>
      {for (final item in this) key(item): item};

  /// Groups elements into a Map of Lists by [keyOf].
  Map<K, List<T>> groupBy<K>(K Function(T item) keyOf) {
    final result = <K, List<T>>{};
    for (final item in this) {
      result.putIfAbsent(keyOf(item), () => []).add(item);
    }
    return result;
  }

  /// Arithmetic mean of elements or null if empty. Alias for [average].
  double? avg([num Function(T item)? of]) => average(of);

  /// Splits elements into two lists by [predicate]: those that match and those that do not.
  (List<T>, List<T>) split(bool Function(T item) predicate) {
    final matches = <T>[];
    final nonMatches = <T>[];
    for (final item in this) {
      if (predicate(item)) {
        matches.add(item);
      } else {
        nonMatches.add(item);
      }
    }
    return (matches, nonMatches);
  }

  /// Groups elements by [keyOf] and counts the occurrences of each key.
  Map<K, int> countBy<K>(K Function(T item) keyOf) {
    final counts = <K, int>{};
    for (final item in this) {
      final key = keyOf(item);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }
}

/// Splitting an iterable of pairs back into two.
extension PairedIterable<A, B> on Iterable<(A, B)> {
  /// The first and second halves of every pair, as two iterables.
  (Iterable<A>, Iterable<B>) get unzip => (map((p) => p.$1), map((p) => p.$2));
}
