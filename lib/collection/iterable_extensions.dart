/// # Iterable Extensions (`IterableExtensions`)
///
/// Fluent, zero-allocation transformations and terminals on [Iterable].
library;

import 'dart:async';

import '../concurrent/concurrent.dart' as conc;
import '../system/console/progress.dart';

/// Fluent transformations on any [Iterable].
extension IterableExtensions<T> on Iterable<T> {
  /// Maps [worker] over these elements with at most [concurrency] in flight.
  ///
  /// ```dart
  /// final pages = await urls.parallelMap(Http.get, concurrency: 8);
  /// ```
  ///
  /// Results keep the input order. [progress] names a [Progress] bar to draw
  /// while it runs. An error stops the run and propagates; `Iterable.settle` is the
  /// version that does not.
  Future<List<R>> parallelMap<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? progress,
  }) {
    final pool = conc.Pool<T>(size: concurrency, delay: delay);
    if (progress == null) return pool.run(this, worker);
    final items = this is List<T> ? this as List<T> : toList();
    final bar = Progress(total: items.length, message: progress);
    pool.on.progress((_) => bar.tick());
    pool.on.done(bar.done);
    return pool.run(items, worker);
  }

  /// Maps [worker] over these elements, collecting successes *and* failures.
  ///
  /// ```dart
  /// for (final outcome in await urls.settle(Http.get)) {
  ///   switch (outcome) {
  ///     case Done(:final value): print(value.url);
  ///     case Broke(:final error): logger.warn('$error');
  ///   }
  /// }
  /// ```
  ///
  /// Nothing throws: every element produces a [Done] or a [Broke], in input
  /// order, so one bad item does not end the run.
  Future<List<conc.Settled<R>>> settle<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? progress,
  }) {
    final pool = conc.Pool<T>(size: concurrency, delay: delay);
    if (progress == null) return pool.settle(this, worker);
    final items = this is List<T> ? this as List<T> : toList();
    final bar = Progress(total: items.length, message: progress);
    pool.on.progress((_) => bar.tick());
    pool.on.done(bar.done);
    return pool.settle(items, worker);
  }

  /// A new list with these elements in order.
  ///
  /// **An adjective, because nothing here is mutated** — the same reason
  /// `dart:core` calls the lazy backwards view `reversed` and the in-place
  /// sort `sort`. `sorted` copies; `List.sort` does not.
  ///
  /// [sortedBy] is the keyed form: pass what to compare *by* rather than a
  /// comparator that does the comparing. The pair matches
  /// `package:collection`, so code that already knows one knows this one.
  ///
  /// ```dart
  /// rows.sorted();                              // natural order
  /// rows.sorted((a, b) => a.name.compareTo(b.name));  // a comparator
  /// rows.sortedBy((r) => r.cost);                 // a key
  /// rows.sortedByDescending((r) => r.cost);       // the same key, reversed
  /// ```
  List<T> sorted([Comparator<T>? compare]) {
    final list = toList();
    if (compare != null) {
      list.sort(compare);
    } else {
      list.sort((a, b) => (a as Comparable).compareTo(b));
    }
    return list;
  }

  /// A new list with these elements in ascending order of [key].
  ///
  /// The keyed form of [sorted]. `by` is the suffix this package uses
  /// throughout for *the thing to compare, group or compare-by*:
  /// [sortedBy], [distinctBy], [groupBy], [countBy], [maxByOrNull],
  /// [toMapBy].
  List<T> sortedBy<K extends Comparable<K>>(K Function(T element) key) {
    final list = toList();
    list.sort((a, b) => key(a).compareTo(key(b)));
    return list;
  }

  /// A new list with these elements in descending order of [key].
  List<T> sortedByDescending<K extends Comparable<K>>(
    K Function(T element) key,
  ) {
    final list = toList();
    list.sort((a, b) => key(b).compareTo(key(a)));
    return list;
  }

  /// The elements with duplicates dropped, keeping the first of each.
  ///
  /// Named for `Stream.distinct`, which is the same operation on the async
  /// side. [distinctBy] is the keyed form, the way [sortedBy] is to [sorted].
  Iterable<T> distinct() => distinctBy((element) => element);

  /// The elements with duplicates dropped, compared by [key].
  Iterable<T> distinctBy(Object? Function(T element) key) sync* {
    final seen = <Object?>{};
    for (final element in this) {
      if (seen.add(key(element))) yield element;
    }
  }

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

  /// The elements this and [other] have in common.
  ///
  /// Named for `Set.intersection` and `Set.difference`, which are the same two
  /// operations one layer down. `concat` and `minus` stood here through 8.1.0,
  /// where the first was `followedBy` under a second name and the second was
  /// the set word spelled as arithmetic.
  Set<T> intersection(Iterable<T> other) {
    final otherSet = other.toSet();
    return toSet().intersection(otherSet);
  }

  /// The elements of this that are not in [other].
  List<T> difference(Iterable<T> other) {
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

/// Fluent terminal operations on [Iterable].
extension IterableTerminals<T> on Iterable<T> {
  /// How many elements satisfy [test].
  ///
  /// `test` is required, because `count()` without one is `length` under a
  /// second name.
  int count(bool Function(T element) test) {
    var n = 0;
    for (final element in this) {
      if (test(element)) n++;
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

  /// The largest element by [compare], or natural order, and `null` when
  /// there are none.
  ///
  /// **`OrNull` because it is.** `package:collection` spells the throwing
  /// version `max` and the nullable one `maxOrNull`; this was named `max` and
  /// returned null through 8.1.0, which is the same name for the opposite
  /// contract.
  T? maxOrNull([Comparator<T>? compare]) {
    final iter = iterator;
    if (!iter.moveNext()) return null;
    var maxVal = iter.current;
    while (iter.moveNext()) {
      final curr = iter.current;
      final cmp = compare != null
          ? compare(curr, maxVal)
          : (curr as Comparable).compareTo(maxVal);
      if (cmp > 0) maxVal = curr;
    }
    return maxVal;
  }

  /// The smallest element by [compare], or natural order, and `null` when
  /// there are none.
  T? minOrNull([Comparator<T>? compare]) {
    final iter = iterator;
    if (!iter.moveNext()) return null;
    var minVal = iter.current;
    while (iter.moveNext()) {
      final curr = iter.current;
      final cmp = compare != null
          ? compare(curr, minVal)
          : (curr as Comparable).compareTo(minVal);
      if (cmp < 0) minVal = curr;
    }
    return minVal;
  }

  /// The element with the largest [key], and `null` when there are none.
  T? maxByOrNull<K extends Comparable<K>>(K Function(T element) key) =>
      maxOrNull((a, b) => key(a).compareTo(key(b)));

  /// The element with the smallest [key], and `null` when there are none.
  T? minByOrNull<K extends Comparable<K>>(K Function(T element) key) =>
      minOrNull((a, b) => key(a).compareTo(key(b)));

  /// Converts this iterable into a Map by key and value extractors.
  Map<K, V> toMap<K, V>({
    required K Function(T item) key,
    required V Function(T item) value,
  }) => {for (final item in this) key(item): value(item)};

  /// This iterable as a `Map`, each element under its own [key].
  ///
  /// The one-per-key form of [groupBy], and a `to___()` copy the way `toList`
  /// and `toSet` are. It was `associateBy` through 8.1.0, which is Kotlin's
  /// word rather than Dart's.
  Map<K, T> toMapBy<K>(K Function(T element) key) => {
    for (final element in this) key(element): element,
  };

  /// Groups elements into a Map of Lists by [keyOf].
  Map<K, List<T>> groupBy<K>(K Function(T item) keyOf) {
    final result = <K, List<T>>{};
    for (final item in this) {
      result.putIfAbsent(keyOf(item), () => []).add(item);
    }
    return result;
  }

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
