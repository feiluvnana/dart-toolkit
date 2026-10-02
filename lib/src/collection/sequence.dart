part of '../../collection.dart';

/// The way in: any `Iterable` becomes a [Sequence].
///
/// {@category Collections}
extension SequenceExtensions<T> on Iterable<T> {
  /// This iterable as a query: `items.sequence.where(…).sortedBy(…).thenBy(…).take(3)`.
  Sequence<T> get sequence => this is Sequence<T> ? this as Sequence<T> : Sequence<T>._(this);
}

/// A map's entries as a query over `(key, value)` records; `toMap()` goes back.
///
/// {@category Collections}
extension MapSequenceExtensions<K, V> on Map<K, V> {
  /// `for (final (k, v) in map.sequence)`, `map.sequence.mapValues(…).toMap()`.
  Sequence<(K, V)> get sequence => Sequence<(K, V)>._(entries.map((e) => (e.key, e.value)));
}

/// A lazy query (LINQ's `IEnumerable`, Kotlin's `Sequence`) that is also an [Iterable]. Every
/// step returns a [Sequence] and runs when the result is read. A `…By` verb takes a key
/// selector; the SDK's names are kept where the SDK has the operation.
///
/// ```dart
/// final top = tracks.sequence
///     .where((t) => t.format == 'flac')
///     .sortedBy((t) => t.disc).thenBy((t) => t.number)
///     .take(10)
///     .toList();
/// final perDisc = tracks.sequence.groupBy((t) => t.disc).mapValues((g) => g.length).toMap();
/// ```
///
/// {@category Collections}
class Sequence<T> extends Iterable<T> {
  final Iterable<T> _source;

  const Sequence._(this._source);

  /// What the operators iterate; [Sorted] answers its sorted list here.
  Iterable<T> get _items => _source;

  /// The sequence `0, 1, …, n-1`, or `start, start+step, …` while below [end].
  static Sequence<int> range(int startOrCount, [int? end, int step = 1]) {
    final start = end == null ? 0 : startOrCount;
    final stop = end ?? startOrCount;
    return Sequence<int>._(_range(start, stop, step));
  }

  static Iterable<int> _range(int start, int stop, int step) sync* {
    if (step == 0) throw ArgumentError.value(step, 'step', 'Must not be zero');
    for (var i = start; step > 0 ? i < stop : i > stop; i += step) {
      yield i;
    }
  }

  @override
  Iterator<T> get iterator => _items.iterator;

  // Delegated so a list source answers without `Iterable`'s default walk.

  @override
  int get length => _items.length;

  @override
  bool get isEmpty => _items.isEmpty;

  @override
  bool get isNotEmpty => _items.isNotEmpty;

  @override
  T get last => _items.last;

  @override
  T elementAt(int index) => _items.elementAt(index);

  @override
  List<T> toList({bool growable = true}) => _items.toList(growable: growable);

  // ---- the SDK's lazy operators, returning a Sequence

  @override
  Sequence<T> where(bool Function(T element) test) => Sequence._(_items.where(test));

  @override
  Sequence<R> map<R>(R Function(T e) toElement) => Sequence._(_items.map(toElement));

  @override
  Sequence<R> expand<R>(Iterable<R> Function(T element) toElements) => Sequence._(_items.expand(toElements));

  @override
  Sequence<T> take(int count) => Sequence._(_items.take(count));

  @override
  Sequence<T> skip(int count) => Sequence._(_items.skip(count));

  @override
  Sequence<T> takeWhile(bool Function(T value) test) => Sequence._(_items.takeWhile(test));

  @override
  Sequence<T> skipWhile(bool Function(T value) test) => Sequence._(_items.skipWhile(test));

  @override
  Sequence<T> followedBy(Iterable<T> other) => Sequence._(_items.followedBy(other));

  @override
  Sequence<R> whereType<R>() => Sequence._(_items.whereType<R>());

  @override
  Sequence<R> cast<R>() => Sequence._(_items.cast<R>());

  // ---- shape

  /// Each element with its position.
  Sequence<(int, T)> get indexed => Sequence._(_items.indexed);

  /// Each element once, by `==`, in first-seen order.
  Sequence<T> get distinct => distinctBy((e) => e);

  /// Each [key] once, keeping the first element that had it.
  Sequence<T> distinctBy(Object? Function(T element) key) => Sequence._(() sync* {
    final seen = <Object?>{};
    for (final e in _items) {
      if (seen.add(key(e))) yield e;
    }
  }());

  /// Fixed-size runs of [size]; the last may be short.
  Sequence<List<T>> chunk(int size) {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'Must be positive');
    return Sequence._(() sync* {
      var batch = <T>[];
      for (final e in _items) {
        batch.add(e);
        if (batch.length == size) {
          yield batch;
          batch = <T>[];
        }
      }
      if (batch.isNotEmpty) yield batch;
    }());
  }

  /// Sliding windows of [size] advancing by [step]; a trailing short window only when [partial].
  Sequence<List<T>> windowed(int size, {int step = 1, bool partial = false}) {
    if (size <= 0 || step <= 0) throw ArgumentError('size and step must be positive');
    // A ring of [size]: the source is read once and never held, so an endless one works.
    return Sequence._(() sync* {
      final window = ListQueue<T>(size);
      var skip = 0;
      for (final e in _items) {
        if (skip > 0) {
          skip--;
          continue;
        }
        window.add(e);
        if (window.length == size) {
          yield window.toList();
          for (var i = 0; i < step && window.isNotEmpty; i++) {
            window.removeFirst();
          }
          if (step > size) skip = step - size;
        }
      }
      if (partial && window.isNotEmpty) yield window.toList();
    }());
  }

  /// Neighbouring pairs: `(e0, e1), (e1, e2), …`.
  Sequence<(T, T)> get pairwise {
    Iterable<(T, T)> pairs() sync* {
      final it = iterator;
      if (!it.moveNext()) return;
      var prev = it.current;
      while (it.moveNext()) {
        yield (prev, it.current);
        prev = it.current;
      }
    }

    return Sequence._(pairs());
  }

  /// Elements paired with [other]'s, stopping at the shorter.
  Sequence<(T, R)> zip<R>(Iterable<R> other) => Sequence._(() sync* {
    final a = iterator, b = other.iterator;
    while (a.moveNext() && b.moveNext()) {
      yield (a.current, b.current);
    }
  }());

  /// The last [count] elements.
  Sequence<T> takeLast(int count) => Sequence._(() sync* {
    final list = toList();
    yield* count >= list.length ? list : list.sublist(list.length - count);
  }());

  /// Everything but the last [count] elements.
  Sequence<T> skipLast(int count) => Sequence._(() sync* {
    final list = toList();
    if (count < list.length) yield* list.sublist(0, list.length - count);
  }());

  /// The elements in reverse.
  Sequence<T> get reversed => Sequence._(() sync* {
    yield* toList().reversed;
  }());

  // ---- order

  /// Sorted by [compare]; `thenBy` adds a tie-break.
  Sorted<T> sortedWith(Comparator<T> compare) => Sorted<T>._(_items, [_byComparator(compare)]);

  /// Sorted by [key], largest first when [descending]; `thenBy` adds the next key.
  Sorted<T> sortedBy<K extends Comparable<K>>(K Function(T element) key, {bool descending = false}) =>
      Sorted<T>._(_items, [_byKey(key, descending)]);

  // ---- sets, in this side's order

  /// These, then what [other] adds, each once.
  Sequence<T> union(Iterable<T> other) => followedBy(other).distinct;

  /// The elements [other] also has, each once.
  Sequence<T> intersect(Iterable<T> other) => Sequence._(() sync* {
    final theirs = other.toSet();
    yield* distinct.where(theirs.contains);
  }());

  /// The elements [other] lacks.
  Sequence<T> except(Iterable<T> other) => Sequence._(() sync* {
    final theirs = other.toSet();
    yield* where((e) => !theirs.contains(e));
  }());

  // ---- joins: the other side is indexed once, this side streams

  /// Every pair whose [on] key here equals [to] on [other], through [select] (`join` is taken
  /// by the SDK's string join).
  ///
  /// ```dart
  /// songs.sequence.innerJoin(pages, on: (s) => s.href, to: (p) => p.href, (s, p) => (s.title, p.size));
  /// ```
  Sequence<R> innerJoin<U, K, R>(
    Iterable<U> other,
    R Function(T mine, U theirs) select, {
    required K Function(T element) on,
    required K Function(U element) to,
  }) => Sequence._(() sync* {
    final index = other.sequence.groupBy(to).toMap();
    for (final e in _items) {
      for (final m in index[on(e)] ?? const []) {
        yield select(e, m as U);
      }
    }
  }());

  /// Left join: every element here with its match on [other], or `null`.
  Sequence<R> leftJoin<U, K, R>(
    Iterable<U> other,
    R Function(T mine, U? theirs) select, {
    required K Function(T element) on,
    required K Function(U element) to,
  }) => Sequence._(() sync* {
    final index = other.sequence.groupBy(to).toMap();
    for (final e in _items) {
      final matches = index[on(e)];
      if (matches == null) {
        yield select(e, null);
      } else {
        for (final m in matches) {
          yield select(e, m);
        }
      }
    }
  }());

  // ---- grouping

  /// One [Group] (a [Sequence] with a [Group.key]) per distinct [key], in first-seen order.
  ///
  /// ```dart
  /// tracks.sequence.groupBy((t) => t.disc).mapValues((g) => g.sumBy((t) => t.seconds)).toMap()
  /// tracks.sequence.groupBy((t) => t.disc).expand((g) => g.sortedBy((t) => t.n).take(2))
  /// ```
  Sequence<Group<K, T>> groupBy<K>(K Function(T element) key) => Sequence._(() sync* {
    final map = <K, List<T>>{};
    for (final e in _items) {
      (map[key(e)] ??= []).add(e);
    }
    yield* map.entries.map((e) => Group<K, T>._(e.key, e.value));
  }());

  /// `(key, count)` per distinct [key].
  Sequence<(K, int)> countBy<K>(K Function(T element) key) => groupBy(key).mapValues((g) => g.length);

  /// A map from [key] to the last element with it.
  Map<K, T> indexBy<K>(K Function(T element) key) => {for (final e in _items) key(e): e};

  /// Elements that pass [test], and those that do not.
  (List<T> matching, List<T> rest) partition(bool Function(T element) test) {
    final yes = <T>[], no = <T>[];
    for (final e in _items) {
      (test(e) ? yes : no).add(e);
    }
    return (yes, no);
  }

  // ---- numbers; a Sequence<num> also has `sum`, `average`, `min`, `max` as getters

  /// The sum of [of] over the elements.
  num sumBy(num Function(T element) of) {
    num total = 0;
    for (final e in _items) {
      total += of(e);
    }
    return total;
  }

  /// The mean of [of] over the elements, or `null` when empty.
  double? averageBy(num Function(T element) of) {
    num total = 0;
    var n = 0;
    for (final e in _items) {
      total += of(e);
      n++;
    }
    return n == 0 ? null : total / n;
  }

  /// The element with the largest [key], or `null`.
  T? maxBy<K extends Comparable<K>>(K Function(T element) key) => _minMax(key)?.$2;

  /// The element with the smallest [key], or `null`.
  T? minBy<K extends Comparable<K>>(K Function(T element) key) => _minMax(key)?.$1;

  /// The smallest and largest [key] holders in one pass, or `null` when empty.
  (T min, T max)? _minMax<K extends Comparable<K>>(K Function(T element) key) {
    final it = iterator;
    if (!it.moveNext()) return null;
    var min = it.current, max = it.current;
    var minKey = key(min), maxKey = minKey;
    while (it.moveNext()) {
      final k = key(it.current);
      if (k.compareTo(minKey) < 0) {
        min = it.current;
        minKey = k;
      }
      if (k.compareTo(maxKey) > 0) {
        max = it.current;
        maxKey = k;
      }
    }
    return (min, max);
  }

  @override
  String toString() {
    final head = _items.take(5).toList(); // one pass: a single-use source is read once
    return 'Sequence(${head.take(4).join(', ')}${head.length > 4 ? ', …' : ''})';
  }
}

/// A [Sequence] of nested iterables.
///
/// {@category Collections}
extension SequenceOfIterableExtensions<T> on Sequence<Iterable<T>> {
  /// One level of nesting removed.
  Sequence<T> get flattened => expand((e) => e);
}

/// A [Sequence] of `(key, value)` records — a map's entries, a [Sequence.groupBy], a [Sequence.zip].
///
/// {@category Collections}
extension SequenceOfPairsExtensions<K, V> on Sequence<(K, V)> {
  /// The keys.
  Sequence<K> get keys => map((p) => p.$1);

  /// The values.
  Sequence<V> get values => map((p) => p.$2);

  /// The same keys, values through [transform].
  Sequence<(K, R)> mapValues<R>(R Function(V value) transform) => map((p) => (p.$1, transform(p.$2)));

  /// The same values, keys through [transform].
  Sequence<(R, V)> mapKeys<R>(R Function(K key) transform) => map((p) => (transform(p.$1), p.$2));

  /// Pairs sorted by key; keys must be [Comparable].
  Sorted<(K, V)> sortedByKey({bool descending = false}) => Sorted<(K, V)>._(this, [_byKey((p) => p.$1, descending)]);

  /// Pairs sorted by value; values must be [Comparable].
  Sorted<(K, V)> sortedByValue({bool descending = false}) => Sorted<(K, V)>._(this, [_byKey((p) => p.$2, descending)]);

  /// A map from the pairs; a repeated key keeps the later value, or what [merge] returns.
  Map<K, V> toMap([V Function(V existing, V incoming)? merge]) {
    final out = <K, V>{};
    for (final (k, v) in this) {
      out[k] = merge != null && out.containsKey(k) ? merge(out[k] as V, v) : v;
    }
    return out;
  }
}

/// One group of a [Sequence.groupBy]: the elements that share [key], as a [Sequence].
///
/// {@category Collections}
final class Group<K, T> extends Sequence<T> {
  final K key;

  Group._(this.key, List<T> elements) : super._(elements);

  @override
  String toString() => 'Group($key: $length elements)';
}

/// A [Sequence] of groups.
///
/// {@category Collections}
extension SequenceOfGroupsExtensions<K, T> on Sequence<Group<K, T>> {
  /// The keys.
  Sequence<K> get keys => map((g) => g.key);

  /// `(key, result)` with each group folded by [fold]: `groupBy(…).mapValues((g) => g.length)`.
  Sequence<(K, R)> mapValues<R>(R Function(Group<K, T> group) fold) => map((g) => (g.key, fold(g)));

  /// The groups as a map of lists.
  Map<K, List<T>> toMap() => {for (final g in this) g.key: g.toList()};
}

/// A [Sequence] of numbers.
///
/// {@category Collections}
extension NumSequenceExtensions<T extends num> on Sequence<T> {
  /// The sum; 0 when empty. A `Sequence<num>` of ints sums to an `int`.
  T get sum {
    num total = T == double ? 0.0 : 0;
    for (final e in this) {
      total += e;
    }
    return total as T;
  }

  /// The mean, or `null` when empty.
  double? get average {
    num total = 0;
    var n = 0;
    for (final e in this) {
      total += e;
      n++;
    }
    return n == 0 ? null : total / n;
  }
}

/// A [Sequence] of [Comparable] elements: numbers, strings, dates, durations.
///
/// {@category Collections}
extension ComparableSequenceExtensions<T extends Comparable<Object>> on Sequence<T> {
  /// Sorted in natural order; `thenBy` adds a tie-break, `descending` flips it.
  Sorted<T> get sorted => sortedWith((a, b) => a.compareTo(b));

  /// Sorted largest first.
  Sorted<T> get sortedDescending => sortedWith((a, b) => b.compareTo(a));

  /// The largest element, or `null` when empty.
  T? get max => fold<T?>(null, (m, e) => m == null || e.compareTo(m) > 0 ? e : m);

  /// The smallest element, or `null` when empty.
  T? get min => fold<T?>(null, (m, e) => m == null || e.compareTo(m) < 0 ? e : m);
}

/// A [Sequence] sorted, stably, by one or more keys; [thenBy] adds the next one.
///
/// {@category Collections}
final class Sorted<T> extends Sequence<T> {
  final List<_SortKey<T>> _keys;

  Sorted._(super.source, this._keys) : super._();

  /// Sorted afresh on every read, like every other step.
  @override
  Iterable<T> get _items => _Deferred(() => _sorted(null));

  /// The first [count] elements in order, or all of them when [count] is `null`.
  List<T> _sorted(int? count) {
    final elements = _source.toList();
    // Each key is extracted once per element, not once per comparison.
    final extracts = [
      for (final k in _keys) [for (final e in elements) k.extract(e)],
    ];
    // The position is the last tie-break, so the sort is stable whatever `List.sort` does.
    int compare(int x, int y) {
      for (var k = 0; k < _keys.length; k++) {
        final c = _keys[k].compare(extracts[k][x], extracts[k][y]);
        if (c != 0) return c;
      }
      return x.compareTo(y);
    }

    if (count != null && count < elements.length ~/ 8) {
      return [for (final i in _smallest(elements.length, count, compare)) elements[i]];
    }
    final order = [for (var i = 0; i < elements.length; i++) i]..sort(compare);
    return [for (final i in count == null || count >= order.length ? order : order.take(count)) elements[i]];
  }

  // What does not need the order does not sort; `take(n)` and `first` select only the front.

  @override
  int get length => _source.length;

  @override
  bool get isEmpty => _source.isEmpty;

  @override
  bool get isNotEmpty => _source.isNotEmpty;

  @override
  T get first => switch (_sorted(1)) {
    [final top, ...] => top,
    _ => throw StateError('No element'),
  };

  @override
  Sequence<T> take(int count) => Sequence._(_Deferred(() => _sorted(RangeError.checkNotNegative(count, 'count'))));

  /// The next key, applied where the earlier ones tie; largest first when [descending].
  Sorted<T> thenBy<K extends Comparable<K>>(K Function(T element) key, {bool descending = false}) =>
      Sorted<T>._(_source, [..._keys, _byKey(key, descending)]);

  /// The next comparator, applied where the earlier keys tie.
  Sorted<T> thenByWith(Comparator<T> compare) => Sorted<T>._(_source, [..._keys, _byComparator(compare)]);
}

/// The positions of the [count] smallest of `0 … n-1` by [compare], in order, via a max-heap of
/// the best so far: O(n log count).
List<int> _smallest(int n, int count, int Function(int x, int y) compare) {
  if (count <= 0) return const [];
  final heap = <int>[];
  void swap(int a, int b) {
    final t = heap[a];
    heap[a] = heap[b];
    heap[b] = t;
  }

  for (var i = 0; i < n; i++) {
    if (heap.length < count) {
      heap.add(i);
      for (var c = heap.length - 1; c > 0 && compare(heap[c], heap[(c - 1) ~/ 2]) > 0; c = (c - 1) ~/ 2) {
        swap(c, (c - 1) ~/ 2);
      }
    } else if (compare(i, heap[0]) < 0) {
      heap[0] = i;
      for (var at = 0; ;) {
        final l = 2 * at + 1, r = l + 1;
        var m = at;
        if (l < heap.length && compare(heap[l], heap[m]) > 0) m = l;
        if (r < heap.length && compare(heap[r], heap[m]) > 0) m = r;
        if (m == at) break;
        swap(at, m);
        at = m;
      }
    }
  }
  return heap..sort(compare);
}

/// An iterable that is [_make]'s result, made afresh on every iteration.
final class _Deferred<T> extends Iterable<T> {
  final Iterable<T> Function() _make;

  _Deferred(this._make);

  @override
  Iterator<T> get iterator => _make().iterator;

  @override
  List<T> toList({bool growable = true}) => _make().toList(growable: growable);
}

/// One sort key, split into extraction and comparison so [Sorted] extracts once per element.
final class _SortKey<T> {
  final Object? Function(T element) extract;
  final int Function(Object? a, Object? b) compare;

  const _SortKey(this.extract, this.compare);
}

/// A key from a selector whose values are [Comparable].
_SortKey<T> _byKey<T>(Object? Function(T element) key, bool descending) => _SortKey<T>(
  key,
  descending ? (a, b) => (b as Comparable<Object?>).compareTo(a) : (a, b) => (a as Comparable<Object?>).compareTo(b),
);

/// A caller's comparator: the element is the key.
_SortKey<T> _byComparator<T>(Comparator<T> compare) => _SortKey<T>((e) => e, (a, b) => compare(a as T, b as T));
