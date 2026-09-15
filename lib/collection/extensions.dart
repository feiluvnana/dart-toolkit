import 'dart:async';
import 'dart:math';

/// Static utility functions for collections.
class Collections {
  /// Pairs elements from two iterables into records.
  static Iterable<(A, B)> zip<A, B>(Iterable<A> a, Iterable<B> b) sync* {
    final itA = a.iterator, itB = b.iterator;
    while (itA.moveNext() && itB.moveNext()) {
      yield (itA.current, itB.current);
    }
  }

  /// Pairs elements from two iterables using a [combiner] function.
  static Iterable<C> zipWith<A, B, C>(Iterable<A> a, Iterable<B> b, C Function(A a, B b) combiner) sync* {
    final itA = a.iterator, itB = b.iterator;
    while (itA.moveNext() && itB.moveNext()) {
      yield combiner(itA.current, itB.current);
    }
  }

  /// Splits elements into fixed-size chunks of length [size].
  static Iterable<List<T>> chunk<T>(Iterable<T> items, int size) sync* {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'Must be positive');
    var batch = <T>[];
    for (final item in items) {
      batch.add(item);
      if (batch.length == size) {
        yield batch;
        batch = <T>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// Creates a sliding window of length [size] advancing by [step].
  static Iterable<List<T>> window<T>(Iterable<T> items, int size, {int step = 1}) sync* {
    if (size <= 0 || step <= 0) throw ArgumentError('Must be positive');
    final list = items.toList();
    for (var i = 0; i + size <= list.length; i += step) {
      yield list.sublist(i, i + size);
    }
  }

  /// Interleaves multiple iterables round-robin.
  static Iterable<T> interleave<T>(Iterable<Iterable<T>> iterables) sync* {
    final iters = iterables.map((e) => e.iterator).toList();
    var hasMore = true;
    while (hasMore) {
      hasMore = false;
      for (final it in iters) {
        if (it.moveNext()) {
          yield it.current;
          hasMore = true;
        }
      }
    }
  }

  /// Flattens a nested iterable into a single list.
  static List<T> flatten<T>(Iterable<Iterable<T>> iterables) => [for (final inner in iterables) ...inner];

  /// Cycles [items] indefinitely or up to [times].
  static Iterable<T> cycle<T>(Iterable<T> items, [int? times]) sync* {
    var count = 0;
    while (times == null || count < times) {
      for (final item in items) {
        yield item;
      }
      count++;
    }
  }
}

/// Functional extensions on [Iterable].
extension CollectionIterableExtensions<T> on Iterable<T> {
  /// Splits elements into fixed-size chunks of length [size].
  Iterable<List<T>> chunk(int size) => Collections.chunk(this, size);

  /// Creates a sliding window of length [size] advancing by [step].
  Iterable<List<T>> window(int size, {int step = 1}) => Collections.window(this, size, step: step);

  /// Yields every [step]-th element.
  Iterable<T> takeEvery(int step) sync* {
    var i = 0;
    for (final item in this) {
      if (i % step == 0) yield item;
      i++;
    }
  }

  /// Samples [count] random elements from this iterable.
  List<T> sample(int count, [Random? random]) {
    final list = toList()..shuffle(random ?? Random());
    return list.take(count).toList();
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

  /// Associates elements into key-value pairs.
  Map<K, V> associate<K, V>((K, V) Function(T item) transform) => {
    for (final item in this) transform(item).$1: transform(item).$2,
  };

  /// Associates elements under a computed [key].
  Map<K, T> associateBy<K>(K Function(T item) key) => {for (final item in this) key(item): item};

  /// Associates elements with a computed [key] and [value].
  Map<K, V> associateWith<K, V>(K Function(T item) key, V Function(T item) value) => {
    for (final item in this) key(item): value(item),
  };

  /// Deduplicates elements by a key extractor.
  Iterable<T> distinctBy(Object? Function(T item) key) sync* {
    final seen = <Object?>{};
    for (final item in this) {
      if (seen.add(key(item))) yield item;
    }
  }

  /// Splits elements into two lists: matching and non-matching.
  (List<T>, List<T>) split(bool Function(T item) predicate) {
    final yes = <T>[], no = <T>[];
    for (final item in this) {
      (predicate(item) ? yes : no).add(item);
    }
    return (yes, no);
  }

  /// Filters elements with index access.
  Iterable<T> whereIndexed(bool Function(int index, T item) predicate) sync* {
    var i = 0;
    for (final item in this) {
      if (predicate(i, item)) yield item;
      i++;
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

  /// Iterates with index access.
  void forEachIndexed(void Function(int index, T item) action) {
    var i = 0;
    for (final item in this) {
      action(i, item);
      i++;
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

  /// Pairs elements from this and [other].
  Iterable<(T, R)> zip<R>(Iterable<R> other) => Collections.zip(this, other);

  /// Pairs elements from this and [other] with a combiner function.
  Iterable<V> zipWith<R, V>(Iterable<R> other, V Function(T a, R b) combiner) =>
      Collections.zipWith(this, other, combiner);

  /// Inserts [separator] between consecutive elements.
  Iterable<T> intersperse(T separator) sync* {
    final it = iterator;
    if (it.moveNext()) {
      yield it.current;
      while (it.moveNext()) {
        yield separator;
        yield it.current;
      }
    }
  }

  /// Executes side-effect for each item lazily without modifying flow.
  Iterable<T> tap(void Function(T item) action) sync* {
    for (final item in this) {
      action(item);
      yield item;
    }
  }
}

/// Functional extensions on [List].
extension CollectionListExtensions<T> on List<T> {
  /// Returns the element at [index], or `null` if out of bounds.
  T? getOrNull(int index) => index >= 0 && index < length ? this[index] : null;

  /// Returns a shuffled copy of this list.
  List<T> shuffled([Random? random]) => toList()..shuffle(random);

  /// Swaps elements at index [i] and [j].
  void swap(int i, int j) {
    final temp = this[i];
    this[i] = this[j];
    this[j] = temp;
  }

  /// Returns a new list with element at [index] updated by [update].
  List<T> updateAt(int index, T Function(T current) update) {
    final list = toList();
    list[index] = update(list[index]);
    return list;
  }
}

/// Functional extensions on [Map].
extension CollectionMapExtensions<K, V> on Map<K, V> {
  /// Maps entries into new key-value pairs.
  Map<K2, V2> mapEntries2<K2, V2>((K2, V2) Function(K key, V value) transform) => {
    for (final entry in entries) transform(entry.key, entry.value).$1: transform(entry.key, entry.value).$2,
  };

  /// Filters map entries by predicate.
  Map<K, V> filter(bool Function(K key, V value) predicate) => {
    for (final entry in entries)
      if (predicate(entry.key, entry.value)) entry.key: entry.value,
  };

  /// Filters map by key predicate.
  Map<K, V> filterKeys(bool Function(K key) predicate) => {
    for (final entry in entries)
      if (predicate(entry.key)) entry.key: entry.value,
  };

  /// Filters map by value predicate.
  Map<K, V> filterValues(bool Function(V value) predicate) => {
    for (final entry in entries)
      if (predicate(entry.value)) entry.key: entry.value,
  };

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

  /// Gets the value at [key] or returns [fallback] value.
  V getOrElse(K key, V Function() fallback) => containsKey(key) ? this[key] as V : fallback();

  /// Puts [key] if absent asynchronously.
  Future<V> putIfAbsentAsync(K key, FutureOr<V> Function() ifAbsent) async {
    if (containsKey(key)) return this[key] as V;
    final val = await ifAbsent();
    this[key] = val;
    return val;
  }
}

/// Functional extensions on [Set].
extension CollectionSetExtensions<T> on Set<T> {
  /// Computes intersection across all sets.
  Set<T> intersectAll(Iterable<Set<T>> others) {
    var result = Set<T>.from(this);
    for (final other in others) {
      result = result.intersection(other);
    }
    return result;
  }

  /// Computes union across all sets.
  Set<T> unionAll(Iterable<Set<T>> others) {
    var result = Set<T>.from(this);
    for (final other in others) {
      result = result.union(other);
    }
    return result;
  }

  /// Computes difference across all sets.
  Set<T> differenceAll(Iterable<Set<T>> others) {
    var result = Set<T>.from(this);
    for (final other in others) {
      result = result.difference(other);
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
