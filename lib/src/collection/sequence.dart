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

/// A lazy query over elements — LINQ's `IEnumerable`, Kotlin's `Sequence` — that is also an
/// [Iterable], so it goes anywhere one does. Every step returns a [Sequence] and runs when the
/// result is read; the terminal operations ([toList], [sum], [groupBy], [first], …) run it.
///
/// A verb with `By` takes a key selector; an adjective (`sorted`, `distinct`, `reversed`)
/// returns a new sequence; the SDK's names are kept where the SDK has the operation.
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

  /// A sequence of nothing.
  const Sequence.empty() : _source = const Iterable.empty();

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

  // ---- the SDK's lazy operators, returning a Sequence so the chain continues

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

  /// Elements that fail [test].
  Sequence<T> whereNot(bool Function(T element) test) => where((e) => !test(e));

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
    return Sequence._(() sync* {
      final list = toList();
      for (var i = 0; i < list.length; i += step) {
        if (i + size <= list.length) {
          yield list.sublist(i, i + size);
        } else {
          if (partial) yield list.sublist(i);
          break;
        }
      }
    }());
  }

  /// Neighbouring pairs: `(e0, e1), (e1, e2), …`.
  Sequence<(T, T)> get pairwise => Sequence._(() sync* {
    final it = iterator;
    if (!it.moveNext()) return;
    var prev = it.current;
    while (it.moveNext()) {
      yield (prev, it.current);
      prev = it.current;
    }
  }());

  /// Elements paired with [other]'s, stopping at the shorter.
  Sequence<(T, R)> zip<R>(Iterable<R> other) => Sequence._(() sync* {
    final a = iterator, b = other.iterator;
    while (a.moveNext() && b.moveNext()) {
      yield (a.current, b.current);
    }
  }());

  /// Every `(a, b)` with `a` from here and `b` from [other].
  Sequence<(T, R)> cartesian<R>(Iterable<R> other) => Sequence._(() sync* {
    for (final a in _items) {
      for (final b in other) {
        yield (a, b);
      }
    }
  }());

  /// Alternating elements from here and [other]; the longer finishes alone.
  Sequence<T> interleave(Iterable<T> other) => Sequence._(() sync* {
    final a = iterator, b = other.iterator;
    var moreA = a.moveNext(), moreB = b.moveNext();
    while (moreA || moreB) {
      if (moreA) {
        yield a.current;
        moreA = a.moveNext();
      }
      if (moreB) {
        yield b.current;
        moreB = b.moveNext();
      }
    }
  }());

  /// The running [combine] from [seed]: `[1, 2, 3].sequence.scan(0, (a, b) => a + b)` is `1, 3, 6`.
  Sequence<R> scan<R>(R seed, R Function(R acc, T element) combine) => Sequence._(() sync* {
    var acc = seed;
    for (final e in _items) {
      acc = combine(acc, e);
      yield acc;
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

  /// A random permutation.
  Sequence<T> shuffled([Random? random]) => Sequence._(() sync* {
    yield* toList()..shuffle(random);
  }());

  // ---- order

  /// Sorted by [compare]; `thenBy` adds a tie-break. Elements that are [Comparable] have
  /// [ComparableSequenceExtensions.sorted] instead.
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

  /// Inner join: every pair whose [on] key here equals [to] on [other], through [select].
  /// (`join` is the SDK's string join, so this is `innerJoin`.)
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

  /// Group join: every element here with the list of its matches on [other], possibly empty.
  Sequence<R> groupJoin<U, K, R>(
    Iterable<U> other,
    R Function(T mine, List<U> theirs) select, {
    required K Function(T element) on,
    required K Function(U element) to,
  }) => Sequence._(() sync* {
    final index = other.sequence.groupBy(to).toMap();
    for (final e in _items) {
      yield select(e, index[on(e)] ?? const []);
    }
  }());

  // ---- grouping: each group is a Sequence with a key, so the sentence continues on it

  /// One [Group] per distinct [key], in first-seen order; each group is a [Sequence] of its
  /// elements with a [Group.key].
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
  T? maxBy<K extends Comparable<K>>(K Function(T element) key) => minMax(key)?.$2;

  /// The element with the smallest [key], or `null`.
  T? minBy<K extends Comparable<K>>(K Function(T element) key) => minMax(key)?.$1;

  /// The smallest and largest [key] holders in one pass, or `null` when empty.
  (T min, T max)? minMax<K extends Comparable<K>>(K Function(T element) key) {
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

  /// Whether no element passes [test].
  bool none(bool Function(T element) test) => !any(test);

  @override
  String toString() {
    final head = _items.take(5).toList(); // one pass, so a single-use source is not consumed twice
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

  /// Values as keys and keys as values.
  Sequence<(V, K)> get inverted => map((p) => (p.$2, p.$1));

  /// Pairs sorted by key; keys must be [Comparable].
  Sorted<(K, V)> sortedByKey({bool descending = false}) => Sorted<(K, V)>._(this, [_byKey((p) => p.$1, descending)]);

  /// Pairs sorted by value; values must be [Comparable].
  Sorted<(K, V)> sortedByValue({bool descending = false}) => Sorted<(K, V)>._(this, [_byKey((p) => p.$2, descending)]);

  /// A map from the pairs; a repeated key keeps the later value, or what [merge] returns.
  Map<K, V> toMap([V Function(V existing, V incoming)? merge]) {
    final out = <K, V>{};
    for (final (k, v) in this) {
      if (merge != null && out.containsKey(k)) {
        out[k] = merge(out[k] as V, v);
      } else {
        out[k] = v;
      }
    }
    return out;
  }

  /// Two lists, keys and values.
  (List<K>, List<V>) get unzip => (keys.toList(), values.toList());
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
  /// The sum; 0 when empty.
  T get sum => fold(T == int ? 0 as T : 0.0 as T, (a, b) => (a + b) as T);

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

/// A [Sequence] sorted by one or more keys; [thenBy] adds the next one.
///
/// Each [thenBy] sorts the source again with one more key, stably, so equal primary keys keep
/// the secondary order.
///
/// {@category Collections}
final class Sorted<T> extends Sequence<T> {
  final List<_SortKey<T>> _keys;
  List<T>? _cache;

  Sorted._(super.source, this._keys) : super._();

  @override
  Iterable<T> get _items => _cache ??= _sort();

  List<T> _sort() {
    final elements = _source.toList();
    // Each key is extracted once per element rather than once per comparison: a sort of n
    // elements makes about n·log n comparisons, so a selector that lowercases a string or
    // parses a date was being paid for that many times over.
    final extracts = [
      for (final k in _keys) [for (final e in elements) k.extract(e)],
    ];
    // The position is the last tie-break, so the sort is stable whatever `List.sort` does.
    final order = [for (var i = 0; i < elements.length; i++) i]
      ..sort((x, y) {
        for (var k = 0; k < _keys.length; k++) {
          final c = _keys[k].compare(extracts[k][x], extracts[k][y]);
          if (c != 0) return c;
        }
        return x.compareTo(y);
      });
    return [for (final i in order) elements[i]];
  }

  /// The next key, applied where the earlier ones tie; largest first when [descending].
  Sorted<T> thenBy<K extends Comparable<K>>(K Function(T element) key, {bool descending = false}) =>
      Sorted<T>._(_source, [..._keys, _byKey(key, descending)]);

  /// The next tie-break, as a comparator.
  Sorted<T> thenWith(Comparator<T> compare) => Sorted<T>._(_source, [..._keys, _byComparator(compare)]);
}

/// One sort key: what to pull out of an element, and how two of those compare.
///
/// Splitting the two is what lets [Sorted] extract once per element; a bare [Comparator]
/// has the selector sealed inside it and has to be handed whole elements every time.
final class _SortKey<T> {
  final Object? Function(T element) extract;
  final int Function(Object? a, Object? b) compare;

  const _SortKey(this.extract, this.compare);
}

/// A key from a selector; its values compare as [Comparable], which is what `sortedBy`'s
/// `K extends Comparable<K>` and a record half alike guarantee.
_SortKey<T> _byKey<T>(Object? Function(T element) key, bool descending) => _SortKey<T>(
  key,
  descending ? (a, b) => (b as Comparable<Object?>).compareTo(a) : (a, b) => (a as Comparable<Object?>).compareTo(b),
);

/// A caller's own comparator: nothing can be extracted from it, so the element is the key.
_SortKey<T> _byComparator<T>(Comparator<T> compare) => _SortKey<T>((e) => e, (a, b) => compare(a as T, b as T));
