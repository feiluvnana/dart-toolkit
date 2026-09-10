/// # Sequences (`Sequence<T>`)
///
/// The sequence API this library returns, in place of Dart's. Grouping,
/// chunking, deduplicating, summing and taking the best of each group are what
/// a script does between fetching and writing, and Dart's `Iterable` needs
/// `package:collection` for most of them.
///
/// [Sequence] deliberately does **not** implement `Iterable`, so there is
/// exactly one vocabulary in scope at any call site — see the class doc for
/// the reasoning and the cost.
library;

// ============================================================================
// SEQUENCES (Sequence<T>)
// ============================================================================

/// A lazy view over an iterable, carrying this library's sequence vocabulary.
///
/// ```dart
/// final rows = await net.crawl<Row>(seed).collect();
///
/// rows.group((r) => r.host)                 // Map<String, Sequence<Row>>
///     .seq.to((e) => (host: e.$1, spend: e.$2.sum((r) => r.cost)))
///     .sort((e) => e.host)
///     .each((e) => log.info('${e.host}  ${e.spend}'));
/// ```
///
/// ## Why this is not an `Iterable`
///
/// An extension member never overrides an instance member, so extending
/// `Iterable` could only *add* names beside Dart's — `keep` next to `where`,
/// two spellings for one operation, which Rule 5 forbids. Replacing the
/// vocabulary therefore means replacing the static type: if the receiver is
/// not an `Iterable`, `Iterable`'s members are not in scope.
///
/// What that costs, and what replaces it:
///
/// | Lost | Replacement |
/// | :--- | :--- |
/// | `for (final x in seq)` | [each] |
/// | `[...seq]`, `seq.toList()` | [list] |
/// | passing to a `List<T>` parameter | [list] |
/// | passing to this library's own APIs | nothing — they take a [Sequence] |
///
/// ## Laziness
///
/// Every shaping member ([to], [keep], [head], …) is lazy, so
/// `rows.to(parse).keep(live).head(10)` parses eleven rows rather than all of
/// them. Everything that needs the whole sequence by definition — [sort],
/// [order], [unique], [group], [keyed], [tally], [split], [flip], [tail],
/// [trim] and every reducing member — is eager, and says so.
///
/// A sequence is a **view, not a snapshot**: it does not copy, and it does not
/// promise the iterable underneath will not change. [list] is where you get
/// something that will not move under you. Unlike Kotlin's `Sequence` this one
/// may be walked as many times as you like — walking it twice re-runs whatever
/// the shaping callbacks do.
final class Sequence<T> {
  final Iterable<T> _items;

  /// Wraps [items] without copying.
  ///
  /// Reach for `items.seq` at a call site; this is the form for when a getter
  /// reads badly.
  const Sequence(this._items);

  // --------------------------------------------------------------------------
  // Shaping — lazy, and returns a Sequence
  // --------------------------------------------------------------------------

  /// Each element replaced by [each] of it — Kotlin's `map`.
  ///
  /// `map` is also the noun for the other collection, so this is `to`: the
  /// sequence *becomes* something else.
  ///
  /// ```dart
  /// rows.to((r) => r.name);        // Sequence<String>
  /// ```
  Sequence<R> to<R>(R Function(T item) each) => Sequence(_items.map(each));

  /// Each element replaced by [each] of it, dropping the nulls.
  ///
  /// Kotlin's `mapNotNull`, and the reason [nonnull] exists separately: a
  /// parse-and-keep-what-parsed step is one call rather than two.
  ///
  /// ```dart
  /// cells.sift(util.text.number);  // Sequence<num>
  /// ```
  Sequence<R> sift<R>(R? Function(T item) each) =>
      Sequence(_items.map(each).whereType<R>());

  /// The elements [test] accepts — Kotlin's `filter`.
  ///
  /// `keep` says which side survives; `where` says neither.
  Sequence<T> keep(bool Function(T item) test) => Sequence(_items.where(test));

  /// The elements [test] rejects — Kotlin's `filterNot`.
  ///
  /// The one complement pair in this vocabulary, because negating a filter
  /// means rewriting the lambda rather than the call.
  Sequence<T> omit(bool Function(T item) test) =>
      Sequence(_items.where((item) => !test(item)));

  /// Only the elements that are an [R] — Kotlin's `filterIsInstance`.
  ///
  /// ```dart
  /// items.only<Row>();
  /// ```
  Sequence<R> only<R>() => Sequence(_items.whereType<R>());

  /// Flattens, or expands each element into many.
  ///
  /// With [each], every element becomes an iterable and they are concatenated
  /// — Kotlin's `flatMap`. Without it the elements must already be iterables
  /// and are concatenated as they are — Kotlin's `flatten` — so [R] is the
  /// element type inside them:
  ///
  /// ```dart
  /// pages.flat((p) => p.links);      // Sequence<Uri>
  /// groups.flat<Row>();              // Sequence<Row>, from Sequence<List<Row>>
  /// ```
  ///
  /// The no-argument form throws [StateError] on an element that is not an
  /// iterable, which the analyzer cannot catch because one signature covers
  /// both shapes.
  Sequence<R> flat<R>([Iterable<R> Function(T item)? each]) =>
      Sequence(_items.expand(each ?? _asIterable<T, R>));

  static Iterable<R> _asIterable<T, R>(T item) {
    if (item is Iterable<R>) return item;
    if (item is Iterable) return item.cast<R>();
    throw StateError(
      'flat() needs iterable elements; found ${item.runtimeType}',
    );
  }

  /// The elements with duplicates removed, keeping the first of each.
  ///
  /// Compares elements themselves, or the key [by] gives — Kotlin's `distinct`
  /// and `distinctBy`. Eager.
  Sequence<T> unique([Object? Function(T item)? by]) {
    final seen = <Object?>{};
    final out = <T>[];
    for (final item in _items) {
      if (seen.add(by == null ? item : by(item))) out.add(item);
    }
    return Sequence(out);
  }

  /// The elements in ascending order, by [by] when given.
  ///
  /// Without [by] the elements must be [Comparable]. Returns a new sequence
  /// and never mutates the source — `List.sort` sorting in place is a bug
  /// source this does not inherit. Eager.
  ///
  /// ```dart
  /// rows.sort((r) => r.score).flip.head(10);
  /// ```
  Sequence<T> sort([Comparable<Object?> Function(T item)? by]) {
    final out = _items.toList();
    if (by == null) {
      out.sort((a, b) => (a as Comparable<Object?>).compareTo(b));
    } else {
      out.sort((a, b) => by(a).compareTo(by(b)));
    }
    return Sequence(out);
  }

  /// The elements ordered by [compare] — Kotlin's `sortedWith`.
  ///
  /// Separate from [sort] because it takes a comparator rather than a key.
  /// Eager.
  Sequence<T> order(int Function(T a, T b) compare) =>
      Sequence(_items.toList()..sort(compare));

  /// The elements back to front. Eager.
  Sequence<T> get flip => Sequence(_items.toList().reversed);

  /// The first [n] elements, or all of them when there are fewer.
  Sequence<T> head(int n) => Sequence(_items.take(n < 0 ? 0 : n));

  /// The last [n] elements, or all of them when there are fewer. Eager.
  Sequence<T> tail(int n) {
    if (n <= 0) return const Sequence([]);
    final all = _items.toList();
    return Sequence(all.length <= n ? all : all.sublist(all.length - n));
  }

  /// Everything but the first [n] elements — Kotlin's `drop`, Dart's word.
  Sequence<T> skip(int n) => Sequence(_items.skip(n < 0 ? 0 : n));

  /// Everything but the last [n] elements — Kotlin's `dropLast`. Eager.
  Sequence<T> trim(int n) {
    if (n <= 0) return this;
    final all = _items.toList();
    return Sequence(
      all.length <= n ? const [] : all.sublist(0, all.length - n),
    );
  }

  /// The leading elements [test] accepts, stopping at the first it does not.
  Sequence<T> until(bool Function(T item) test) =>
      Sequence(_items.takeWhile(test));

  /// Everything from the first element [test] rejects onwards.
  Sequence<T> after(bool Function(T item) test) =>
      Sequence(_items.skipWhile(test));

  /// The elements in consecutive groups of [size], the last one short.
  ///
  /// Pairs directly with `concurrent.run`:
  ///
  /// ```dart
  /// for (final batch in rows.chunks(100).list) {
  ///   await concurrent.run(batch.list, send, size: 4);
  /// }
  /// ```
  Sequence<Sequence<T>> chunks(int size) => Sequence(_chunked(size));

  Iterable<Sequence<T>> _chunked(int size) sync* {
    if (size <= 0) return;
    var batch = <T>[];
    for (final item in _items) {
      batch.add(item);
      if (batch.length == size) {
        yield Sequence(batch);
        batch = <T>[];
      }
    }
    if (batch.isNotEmpty) yield Sequence(batch);
  }

  /// Sliding windows of [size] elements, advancing by [step].
  ///
  /// `windows(2)` is Kotlin's `zipWithNext` — consecutive pairs, for deltas
  /// and moving averages. Set [partial] to also yield the short windows at the
  /// end rather than stopping when a full one no longer fits.
  Sequence<Sequence<T>> windows(
    int size, {
    int step = 1,
    bool partial = false,
  }) => Sequence(_windowed(size, step, partial));

  Iterable<Sequence<T>> _windowed(int size, int step, bool partial) sync* {
    if (size <= 0 || step <= 0) return;
    final buffer = <T>[];
    var skipping = 0;
    for (final item in _items) {
      if (skipping > 0) {
        skipping--;
        continue;
      }
      buffer.add(item);
      if (buffer.length == size) {
        yield Sequence(List<T>.of(buffer));
        if (step >= size) {
          skipping = step - size;
          buffer.clear();
        } else {
          buffer.removeRange(0, step);
        }
      }
    }
    if (partial && buffer.isNotEmpty) yield Sequence(buffer);
  }

  /// This sequence paired elementwise with [other], stopping at the shorter.
  ///
  /// A record, not a `Pair` type.
  Sequence<(T, R)> zip<R>(Sequence<R> other) => Sequence(_zipped(other));

  Iterable<(T, R)> _zipped<R>(Sequence<R> other) sync* {
    final left = _items.iterator;
    final right = other._items.iterator;
    while (left.moveNext() && right.moveNext()) {
      yield (left.current, right.current);
    }
  }

  /// Each element with its position — Kotlin's `withIndex`.
  ///
  /// One name instead of `withIndex`, `mapIndexed` and `forEachIndexed`:
  /// `pairs.to(...)`, `pairs.each(...)` and `pairs.fold(...)` do the rest.
  Sequence<(int, T)> get pairs => Sequence(_items.indexed);

  /// The running results of folding [each] over the sequence from [initial].
  ///
  /// Kotlin's `runningFold`. The first element yielded is [initial], so a
  /// sequence of *n* elements gives *n + 1* results.
  Sequence<R> scan<R>(R initial, R Function(R total, T item) each) =>
      Sequence(_scanned(initial, each));

  Iterable<R> _scanned<R>(R initial, R Function(R total, T item) each) sync* {
    var total = initial;
    yield total;
    for (final item in _items) {
      total = each(total, item);
      yield total;
    }
  }

  /// The same elements, with [each] called on them as they pass.
  ///
  /// A peek that stays in the chain — Kotlin's `onEach`:
  ///
  /// ```dart
  /// rows.also(print).keep((r) => r.live);
  /// ```
  Sequence<T> also(void Function(T item) each) => Sequence(
    _items.map((item) {
      each(item);
      return item;
    }),
  );

  /// This sequence followed by [other].
  Sequence<T> plus(Sequence<T> other) =>
      Sequence(_items.followedBy(other._items));

  /// This sequence without any element [other] holds.
  Sequence<T> minus(Sequence<T> other) => Sequence(_without(other));

  Iterable<T> _without(Sequence<T> other) sync* {
    final drop = other._items.toSet();
    for (final item in _items) {
      if (!drop.contains(item)) yield item;
    }
  }

  /// Every element of this sequence then of [other], duplicates removed.
  Sequence<T> union(Sequence<T> other) => Sequence(_unioned(other));

  Iterable<T> _unioned(Sequence<T> other) sync* {
    final seen = <T>{};
    for (final item in _items.followedBy(other._items)) {
      if (seen.add(item)) yield item;
    }
  }

  /// The elements this sequence and [other] share, duplicates removed.
  ///
  /// `intersect` is not a word people reach for; `common` is.
  Sequence<T> common(Sequence<T> other) => Sequence(_shared(other));

  Iterable<T> _shared(Sequence<T> other) sync* {
    final keep = other._items.toSet();
    final seen = <T>{};
    for (final item in _items) {
      if (keep.contains(item) && seen.add(item)) yield item;
    }
  }

  /// This sequence, or [fallback] when it holds nothing — Kotlin's `ifEmpty`.
  Sequence<T> or(Sequence<T> fallback) => Sequence(_orElse(fallback));

  Iterable<T> _orElse(Sequence<T> fallback) sync* {
    var any = false;
    for (final item in _items) {
      any = true;
      yield item;
    }
    if (!any) yield* fallback._items;
  }

  /// This sequence viewed as a `Sequence<R>`, throwing on an element that is
  /// not one.
  Sequence<R> cast<R>() => Sequence(_items.cast<R>());

  // --------------------------------------------------------------------------
  // Reducing — eager, and leaves the Sequence
  // --------------------------------------------------------------------------

  /// How many elements there are, or how many [test] accepts.
  int count([bool Function(T item)? test]) =>
      test == null ? _items.length : _items.where(test).length;

  /// Whether the sequence holds nothing.
  ///
  /// There is no complement: `!seq.empty` already says the other thing.
  bool get empty => _items.isEmpty;

  /// Whether [value] is one of the elements.
  bool has(T value) => _items.contains(value);

  /// The first element, or `null` when there is none.
  ///
  /// Nullable rather than throwing, like every other reader in this library:
  /// the caller asked for a value and the honest answer is that there is not
  /// one. `?? fallback` replaces Kotlin's `getOrElse`, and is shorter.
  T? get first {
    for (final item in _items) {
      return item;
    }
    return null;
  }

  /// The last element, or `null` when there is none.
  T? get last {
    T? found;
    for (final item in _items) {
      found = item;
    }
    return found;
  }

  /// The only element, or `null` when there is not exactly one.
  T? get sole {
    T? found;
    var seen = 0;
    for (final item in _items) {
      if (++seen > 1) return null;
      found = item;
    }
    return seen == 1 ? found : null;
  }

  /// The element at [index], or `null` when the sequence is shorter.
  ///
  /// ```dart
  /// cells.at(3) ?? '';
  /// ```
  T? at(int index) {
    if (index < 0) return null;
    var i = 0;
    for (final item in _items) {
      if (i++ == index) return item;
    }
    return null;
  }

  /// The first element [test] accepts, or `null`.
  ///
  /// Non-throwing, so there is no `orElse:` to write — `firstWhere(orElse:)`
  /// is the most-typed apology in Dart.
  T? find(bool Function(T item) test) {
    for (final item in _items) {
      if (test(item)) return item;
    }
    return null;
  }

  /// The last element [test] accepts, or `null`.
  T? findlast(bool Function(T item) test) {
    T? found;
    for (final item in _items) {
      if (test(item)) found = item;
    }
    return found;
  }

  /// The position of the first element [test] accepts, or `null`.
  int? index(bool Function(T item) test) {
    var i = 0;
    for (final item in _items) {
      if (test(item)) return i;
      i++;
    }
    return null;
  }

  /// Whether [test] accepts at least one element.
  ///
  /// There is no `none`: `!seq.any(test)` already says it.
  bool any(bool Function(T item) test) => _items.any(test);

  /// Whether [test] accepts every element — vacuously true when empty.
  bool all(bool Function(T item) test) => _items.every(test);

  /// [each] applied across the sequence, starting from [initial].
  ///
  /// Dart's word, kept. There is no `reduce`: this covers it, and the indexed
  /// form is `pairs.fold`.
  R fold<R>(R initial, R Function(R total, T item) each) {
    var total = initial;
    for (final item in _items) {
      total = each(total, item);
    }
    return total;
  }

  /// The total of [of] across the sequence; `0` when empty.
  ///
  /// The selector is always required, including on a sequence that is already
  /// numbers (`prices.sum((n) => n)`), because one spelling of an operation is
  /// worth five characters in the rarer case.
  num sum(num Function(T item) of) {
    num total = 0;
    for (final item in _items) {
      total += of(item);
    }
    return total;
  }

  /// The mean of [of] across the sequence, or `null` when empty.
  double? avg(num Function(T item) of) {
    num total = 0;
    var seen = 0;
    for (final item in _items) {
      total += of(item);
      seen++;
    }
    return seen == 0 ? null : total / seen;
  }

  /// The element with the largest [by], or `null` when empty.
  T? best(Comparable<Object?> Function(T item) by) => _extreme(by, 1);

  /// The element with the smallest [by], or `null` when empty.
  ///
  /// Not a complement of [best] that `!` could cover — negating a maximum does
  /// not give a minimum.
  T? worst(Comparable<Object?> Function(T item) by) => _extreme(by, -1);

  T? _extreme(Comparable<Object?> Function(T item) by, int sign) {
    T? found;
    Comparable<Object?>? mark;
    for (final item in _items) {
      final key = by(item);
      if (mark == null || key.compareTo(mark) * sign > 0) {
        mark = key;
        found = item;
      }
    }
    return found;
  }

  /// The elements grouped by [by], each group in encounter order.
  ///
  /// ```dart
  /// rows.group((r) => util.time.day(r.at));   // Map<DateTime, Sequence<Row>>
  /// ```
  Map<K, Sequence<T>> group<K>(K Function(T item) by) {
    final buckets = <K, List<T>>{};
    for (final item in _items) {
      (buckets[by(item)] ??= <T>[]).add(item);
    }
    return {
      for (final entry in buckets.entries) entry.key: Sequence(entry.value),
    };
  }

  /// A lookup table keyed by [by], holding [value] of each element.
  ///
  /// Kotlin's `associateBy` and `associateWith` in one member. Omit [value] to
  /// store the elements themselves; the last element to claim a key wins.
  ///
  /// ```dart
  /// final Map<String, Row> byId = rows.keyed((r) => r.id);
  /// final Map<String, num> prices = rows.keyed((r) => r.id, (r) => r.price);
  /// ```
  Map<K, V> keyed<K, V>(K Function(T item) by, [V Function(T item)? value]) {
    final out = <K, V>{};
    for (final item in _items) {
      out[by(item)] = value == null ? item as V : value(item);
    }
    return out;
  }

  /// How many elements fall under each [by] — a counted report in one call.
  Map<K, int> tally<K>(K Function(T item) by) {
    final out = <K, int>{};
    for (final item in _items) {
      out.update(by(item), (n) => n + 1, ifAbsent: () => 1);
    }
    return out;
  }

  /// The elements [test] accepts and the elements it rejects.
  ///
  /// A record, so both halves keep their name:
  ///
  /// ```dart
  /// final (live, dead) = rows.split((r) => r.ok);
  /// ```
  (Sequence<T>, Sequence<T>) split(bool Function(T item) test) {
    final yes = <T>[];
    final no = <T>[];
    for (final item in _items) {
      (test(item) ? yes : no).add(item);
    }
    return (Sequence(yes), Sequence(no));
  }

  /// The elements as text, joined by [separator].
  ///
  /// [prefix] and [suffix] wrap the result, [of] renders each element, and
  /// [limit] caps how many are shown — which is what makes this a summary
  /// printer rather than a plain join:
  ///
  /// ```dart
  /// rows.join(', ', prefix: '[', suffix: ']', limit: 3, of: (r) => r.name);
  /// // '[Ada, Alan, Grace, …]'
  /// ```
  String join(
    String separator, {
    String prefix = '',
    String suffix = '',
    int? limit,
    String Function(T item)? of,
  }) {
    final buffer = StringBuffer(prefix);
    var shown = 0;
    var more = false;
    for (final item in _items) {
      if (limit != null && shown >= limit) {
        more = true;
        break;
      }
      if (shown > 0) buffer.write(separator);
      buffer.write(of == null ? '$item' : of(item));
      shown++;
    }
    if (more) {
      buffer
        ..write(separator)
        ..write('…');
    }
    return (buffer..write(suffix)).toString();
  }

  /// Calls [each] on every element — the `for`-in replacement.
  void each(void Function(T item) each) {
    for (final item in _items) {
      each(item);
    }
  }

  /// The elements as a list — a real snapshot, and the hand-off to anything
  /// typed `List<T>` or `Iterable<T>`.
  List<T> get list => _items.toList();

  /// The distinct elements as a set.
  Set<T> get set => _items.toSet();

  @override
  String toString() =>
      'Sequence(${_items.take(4).join(', ')}'
      '${_items.length > 4 ? ', …' : ''})';
}

// ============================================================================
// THE WAY IN
// ============================================================================

/// Turns any iterable into a [Sequence].
///
/// The seam: a literal, a `dart:io` call or another package becomes shapeable
/// with one word. This library's own APIs already return a [Sequence], so most
/// scripts write `.seq` only at their edges.
extension Sequenced<T> on Iterable<T> {
  /// This iterable as a [Sequence], without copying.
  Sequence<T> get seq => Sequence<T>(this);
}

/// Turns a map into a [Sequence] of key/value records.
///
/// Records rather than `MapEntry`, because `MapEntry` is a noun nobody wants:
///
/// ```dart
/// rows.group((r) => r.host)
///     .seq.to((e) => (host: e.$1, count: e.$2.count()));
/// ```
extension MapSequenced<K, V> on Map<K, V> {
  /// This map's entries as a sequence of `(key, value)` records.
  Sequence<(K, V)> get seq =>
      Sequence(entries.map((entry) => (entry.key, entry.value)));
}

/// The two members that only make sense on a sequence of a particular shape.
extension NullableSequence<T extends Object> on Sequence<T?> {
  /// The non-null elements — Kotlin's `filterNotNull`.
  ///
  /// Lowercase compound, as `perhost` and `httponly` are.
  Sequence<T> get nonnull => Sequence(_items.whereType<T>());
}

/// Splitting a sequence of pairs back into two.
extension PairedSequence<A, B> on Sequence<(A, B)> {
  /// The first and second halves of every pair, as two sequences. Eager.
  (Sequence<A>, Sequence<B>) get unzip {
    final left = <A>[];
    final right = <B>[];
    for (final (a, b) in _items) {
      left.add(a);
      right.add(b);
    }
    return (Sequence(left), Sequence(right));
  }
}
