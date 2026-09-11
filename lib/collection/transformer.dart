/// # Transformers (`Transformer<A, B>`)
///
/// An operation that turns a sequence into another sequence, as a value.
///
/// [Sequence.transform] takes one, so every shaping step this library offers
/// is a `static` factory here rather than a method over there — which is what
/// lets each of them take its ordinary name back. `map` cannot be a method on
/// a collection beside `Map` the type; `Transformer.map` can.
library;

import 'collector.dart';
import 'sequence.dart';

// ============================================================================
// TRANSFORMERS (Transformer<A, B>)
// ============================================================================

/// An operation that turns a sequence of [A] into a sequence of [B].
///
/// ```dart
/// rows.transform(.where((r) => r.live))
///     .transform(.sort.by((r) => r.cost))
///     .transform(.take.first(10));
/// ```
///
/// ## The dot is the point
///
/// At a call site the context type resolves the name, so the bare form above
/// is the one to write. [Sequence.transform] is the only receiver a
/// transformer ever has, and inside this namespace nothing collides: [map] is
/// not `Map`, [where] is not `Iterable.where`, and a compound operation splits
/// at the capital instead of inventing a word — `takeWhile` is [take]`.when`,
/// `flatMap` is [flat]`.map`, `distinctBy` is [unique]`.by`.
///
/// The explicit spelling always works and means the same thing:
///
/// ```dart
/// rows.transform(Transformer.take.first(10));
/// ```
///
/// ## A pipeline is a value
///
/// [then] joins two transformers into one and [into] gives one an ending, so
/// a whole chain can be named, stored, passed to something else and tested on
/// its own:
///
/// ```dart
/// // setup: bool live(Row r) => r.live; String sku(Row r) => r.sku;
/// final cleanup = Transformer.where<Row>(live).then(Transformer.unique.by(sku));
///
/// rows.transform(cleanup);
/// cleanup.run(const [Row('a.com', 1, 1)]);   // no Sequence in sight
/// ```
///
/// ## Where the shorthand stops
///
/// A dot shorthand needs a context type to resolve against, and the receiver
/// of [then] has none — `.where(live).then(…)` does not compile. Write the
/// left-hand side out, which is the shape a named pipeline wants anyway.
/// [Collector] has one more limit of its own; see its doc.
///
/// ## Anything not here
///
/// [fn] takes the transformation directly, and a subclass takes it further —
/// see [fn].
class Transformer<A, B> {
  /// Creates a transformer that applies [run] to the whole sequence.
  ///
  /// The generative constructor a subclass calls. Reach for [fn] at a call
  /// site; this is the form for when a subclass needs a `super` call.
  const Transformer(this.run);

  /// This operation, as the plain function it is.
  ///
  /// Public because that is what makes a transformer testable without a
  /// [Sequence] anywhere near it:
  ///
  /// ```dart
  /// Transformer.map<int, String>((n) => '$n').run(const [1, 2]);   // ('1', '2')
  /// ```
  final Iterable<B> Function(Iterable<A> items) run;

  // --------------------------------------------------------------------------
  // Composing
  // --------------------------------------------------------------------------

  /// This transformer followed by [next] — a pipeline as one value.
  ///
  /// ```dart
  /// // setup: bool live(Row r) => r.live;
  /// final top = Transformer.where<Row>(live).then(Transformer.take.first(10));
  /// rows.transform(top);
  /// ```
  ///
  /// A dot shorthand cannot be the receiver of this — `.where(live).then(…)`
  /// has nothing to resolve `.where` against — so the left-hand side is
  /// written out. That is the shape a named pipeline wants anyway.
  Transformer<A, C> then<C>(Transformer<B, C> next) =>
      Transformer((items) => next.run(run(items)));

  /// This transformer with an ending, which makes it a [Collector].
  ///
  /// Java's `Collectors.mapping(f, downstream)` without the blessed pairing:
  /// any transformer, any collector.
  ///
  /// ```dart
  /// final hosts = Transformer.map<Row, String>((r) => r.host)
  ///     .into(Collector.list());
  ///
  /// rows.collect(hosts);          // List<String>
  /// ```
  Collector<A, R> into<R>(Collector<B, R> end) =>
      Collector((items) => end.run(run(items)));

  // --------------------------------------------------------------------------
  // Shaping
  // --------------------------------------------------------------------------

  /// Each element replaced by [each] of it — Kotlin's `map`.
  ///
  /// Callable, and a namespace: `map.nonnull` drops what came back `null`.
  ///
  /// ```dart
  /// rows.transform(.map((r) => r.name));                 // Sequence<String>
  /// items.transform(.map.nonnull(util.text.number));     // Sequence<num>
  /// ```
  static const map = _Map();

  /// The elements [test] accepts — Kotlin's `filter`, Dart's word.
  ///
  /// Callable, and a namespace: `where.type<R>()` keeps only the elements that
  /// are an [R], which is Kotlin's `filterIsInstance`.
  ///
  /// ```dart
  /// rows.transform(.where((r) => r.live));
  /// items.transform(.where.type<String>());
  /// ```
  ///
  /// There is no `omit`: `where((r) => !r.live)` is the other side, and Rule
  /// 4's `!` test applies to a filter the moment the filter has an ordinary
  /// name.
  static const where = _Where();

  /// Flattens, or expands each element into many.
  ///
  /// `flat()` concatenates elements that are already iterables — Kotlin's
  /// `flatten` — and `flat.map(each)` turns each element into an iterable
  /// first, which is `flatMap` split at the capital.
  ///
  /// ```dart
  /// // setup: final groups = Sequence(const [<Row>[]]);
  /// groups.transform(.flat<Row>());
  /// rows.transform(.flat.map((r) => [r, r]));
  /// ```
  ///
  /// `flat()` throws [StateError] on an element that is not an iterable, which
  /// the analyzer cannot catch because the element type is only a promise.
  static const flat = _Flat();

  /// The elements with duplicates removed, keeping the first of each.
  ///
  /// `unique()` compares the elements themselves and `unique.by(key)` compares
  /// [key] of them — Kotlin's `distinct` and `distinctBy`.
  ///
  /// ```dart
  /// titles.transform(.unique());
  /// rows.transform(.unique.by((r) => r.sku));
  /// ```
  static const unique = _Unique();

  /// The elements in ascending order.
  ///
  /// `sort()` needs [Comparable] elements, `sort.by(key)` orders by a key, and
  /// `sort.using(compare)` takes a comparator — Kotlin's `sorted`, `sortedBy`
  /// and `sortedWith`. Never mutates the source, which `List.sort` does.
  ///
  /// ```dart
  /// titles.transform(.sort());
  /// rows.transform(.sort.by((r) => r.cost));
  /// rows.transform(.sort.using((a, b) => a.host.compareTo(b.host)));
  /// ```
  static const sort = _Sort();

  /// The leading elements, by count or by test.
  ///
  /// `take.first(n)`, `take.last(n)` and `take.when(test)` — Dart's `take` and
  /// `takeWhile`, plus the one Dart has no name for. `while` is a reserved
  /// word, so the test form is `when`.
  ///
  /// ```dart
  /// rows.transform(.take.first(10));
  /// rows.transform(.take.when((r) => r.live));
  /// ```
  static const take = _Take();

  /// Everything but some elements, by count or by test.
  ///
  /// `skip.first(n)`, `skip.last(n)` and `skip.when(test)` — the exact
  /// opposites of [take], and they read as opposites, which `head`/`skip` and
  /// `tail`/`trim` never did.
  static const skip = _Skip();

  /// The elements back to front.
  static Transformer<A, A> flip<A>() =>
      Transformer((items) => items.toList().reversed);

  /// Each element paired with its position — Python's word.
  ///
  /// The one index-aware primitive: `mapIndexed`, `filterIndexed` and
  /// `forEachIndexed` are all this followed by the plain operation, which is
  /// why none of them is a member.
  ///
  /// ```dart
  /// titles.transform(.enumerate()).transform(.map((p) => '${p.$1}. ${p.$2}'));
  /// ```
  static Transformer<A, (int, A)> enumerate<A>() =>
      Transformer((items) => items.toList().indexed);

  /// The elements in consecutive groups of [size], the last one short.
  ///
  /// ```dart
  /// for (final batch in rows.transform(.chunk(100)).list) {
  ///   await concurrent.run(batch.list, print, size: 4);
  /// }
  /// ```
  static Transformer<A, Sequence<A>> chunk<A>(int size) =>
      Transformer((items) => _chunked(items, size));

  static Iterable<Sequence<A>> _chunked<A>(Iterable<A> items, int size) sync* {
    if (size <= 0) return;
    var batch = <A>[];
    for (final item in items) {
      batch.add(item);
      if (batch.length == size) {
        yield Sequence(batch);
        batch = <A>[];
      }
    }
    if (batch.isNotEmpty) yield Sequence(batch);
  }

  /// The elements paired elementwise with [other], stopping at the shorter.
  ///
  /// A record, not a `Pair` type.
  static Transformer<A, (A, R)> zip<A, R>(Sequence<R> other) =>
      Transformer((items) => _zipped(items, other.list));

  static Iterable<(A, R)> _zipped<A, R>(
    Iterable<A> items,
    List<R> other,
  ) sync* {
    final left = items.iterator;
    final right = other.iterator;
    while (left.moveNext() && right.moveNext()) {
      yield (left.current, right.current);
    }
  }

  /// The elements followed by [other]'s.
  static Transformer<A, A> plus<A>(Sequence<A> other) =>
      Transformer((items) => items.followedBy(other.list));

  /// The elements [other] does not hold.
  static Transformer<A, A> minus<A>(Sequence<A> other) =>
      Transformer((items) => _without(items, other.list.toSet()));

  static Iterable<A> _without<A>(Iterable<A> items, Set<A> drop) sync* {
    for (final item in items) {
      if (!drop.contains(item)) yield item;
    }
  }

  /// The elements [other] also holds, duplicates removed.
  ///
  /// `intersect` is not a word people reach for; `common` is.
  static Transformer<A, A> common<A>(Sequence<A> other) =>
      Transformer((items) => _shared(items, other.list.toSet()));

  static Iterable<A> _shared<A>(Iterable<A> items, Set<A> keep) sync* {
    final seen = <A>{};
    for (final item in items) {
      if (keep.contains(item) && seen.add(item)) yield item;
    }
  }

  /// The elements, or [fallback]'s when there are none — Kotlin's `ifEmpty`.
  ///
  /// ```dart
  /// titles.transform(.or(Sequence(const ['none'])));
  /// ```
  static Transformer<A, A> or<A>(Sequence<A> fallback) =>
      Transformer((items) => items.isEmpty ? fallback.list : items);

  /// The elements as [R]s, throwing on one that is not.
  ///
  /// The pair with `where.type`, and the difference is what happens to an
  /// element of the wrong type: that drops it, this throws. Reach for
  /// `where.type` when the sequence is mixed on purpose and for this when a
  /// wrong element is a bug you want to hear about.
  static Transformer<Never, R> cast<R>() =>
      Transformer<Never, R>((Iterable<Object?> items) => items.cast<R>());

  /// An arbitrary transformation, for anything the named ones do not cover.
  ///
  /// ```dart
  /// rows.transform(.fn((xs) => xs.toList()..shuffle()));
  /// ```
  ///
  /// The door in a closed set, the same one `Field.fn` is. [fn] takes a
  /// closure, so it fits an operation used once and needing no name; for one
  /// with options, one used in six pipelines, or one worth a test of its own,
  /// subclass instead:
  ///
  /// ```dart
  /// final class Dearer extends Transformer<Row, Row> {
  ///   Dearer(num floor) : super((rows) => rows.where((r) => r.cost > floor));
  /// }
  ///
  /// rows.transform(Dearer(0.05)).transform(.take.first(10));
  /// ```
  ///
  /// A subclass composes with the built-ins on equal footing, registers
  /// nothing, and is why this class is not `final`.
  static Transformer<A, B> fn<A, B>(
    Iterable<B> Function(Iterable<A> items) run,
  ) => Transformer(run);

  @override
  String toString() => 'Transformer<$A, $B>';
}

// ============================================================================
// THE NAMESPACES
// ============================================================================

/// The namespace behind [Transformer.map].
class _Map {
  const _Map();

  /// Each element replaced by [each] of it.
  Transformer<A, B> call<A, B>(B Function(A item) each) =>
      Transformer((items) => items.map(each));

  /// Each element replaced by [each] of it, dropping the nulls.
  ///
  /// Kotlin's `mapNotNull`, spelled with the word this library already uses
  /// for dropping nulls — see `Sequence.nonnull`, its argument-free twin.
  Transformer<A, B> nonnull<A, B extends Object>(B? Function(A item) each) =>
      Transformer((items) => items.map(each).whereType<B>());
}

/// The namespace behind [Transformer.where].
class _Where {
  const _Where();

  /// The elements [test] accepts.
  Transformer<A, A> call<A>(bool Function(A item) test) =>
      Transformer((items) => items.where(test));

  /// Only the elements that are a [R] — Kotlin's `filterIsInstance`.
  Transformer<Never, R> type<R>() =>
      Transformer<Never, R>((Iterable<Object?> items) => items.whereType<R>());
}

/// The namespace behind [Transformer.flat].
class _Flat {
  const _Flat();

  /// The elements concatenated, each of them already an iterable.
  ///
  /// The element type is a promise the analyzer cannot check, which is why
  /// this throws where `flat.map` cannot.
  Transformer<Never, B> call<B>() => Transformer<Never, B>(
    (Iterable<Object?> items) => items.expand(_asIterable<B>),
  );

  /// Each element expanded into many by [each], and the lot concatenated.
  Transformer<A, B> map<A, B>(Iterable<B> Function(A item) each) =>
      Transformer((items) => items.expand(each));

  static Iterable<B> _asIterable<B>(Object? item) {
    if (item is Iterable<B>) return item;
    if (item is Iterable) return item.cast<B>();
    throw StateError(
      'flat() needs iterable elements; found ${item.runtimeType}',
    );
  }
}

/// The namespace behind [Transformer.unique].
class _Unique {
  const _Unique();

  /// The elements, duplicates removed.
  Transformer<A, A> call<A>() => by<A, A>((item) => item);

  /// The elements, keeping the first of each distinct [key].
  Transformer<A, A> by<A, K>(K Function(A item) key) => Transformer((items) {
    final seen = <K>{};
    return [
      for (final item in items)
        if (seen.add(key(item))) item,
    ];
  });
}

/// The namespace behind [Transformer.sort].
class _Sort {
  const _Sort();

  /// The elements in ascending order, which needs them [Comparable].
  Transformer<A, A> call<A>() =>
      using((a, b) => (a as Comparable<Object?>).compareTo(b));

  /// The elements in ascending order of [key].
  Transformer<A, A> by<A>(Comparable<Object?> Function(A item) key) =>
      using((a, b) => key(a).compareTo(key(b)));

  /// The elements ordered by [compare] — Kotlin's `sortedWith`.
  Transformer<A, A> using<A>(int Function(A a, A b) compare) =>
      Transformer((items) => items.toList()..sort(compare));
}

/// The namespace behind [Transformer.take].
class _Take {
  const _Take();

  /// The leading [n] elements, or all of them when there are fewer.
  Transformer<A, A> first<A>(int n) =>
      Transformer((items) => items.take(n < 0 ? 0 : n));

  /// The trailing [n] elements, or all of them when there are fewer.
  Transformer<A, A> last<A>(int n) => Transformer((items) {
    if (n <= 0) return const [];
    final all = items.toList();
    return all.length <= n ? all : all.sublist(all.length - n);
  });

  /// The leading elements [test] accepts, stopping at the first it does not.
  Transformer<A, A> when<A>(bool Function(A item) test) =>
      Transformer((items) => items.takeWhile(test));
}

/// The namespace behind [Transformer.skip].
class _Skip {
  const _Skip();

  /// Everything but the leading [n] elements — Kotlin's `drop`.
  Transformer<A, A> first<A>(int n) =>
      Transformer((items) => items.skip(n < 0 ? 0 : n));

  /// Everything but the trailing [n] elements — Kotlin's `dropLast`.
  Transformer<A, A> last<A>(int n) => Transformer((items) {
    if (n <= 0) return items;
    final all = items.toList();
    return all.length <= n ? const [] : all.sublist(0, all.length - n);
  });

  /// Everything from the first element [test] rejects onwards.
  Transformer<A, A> when<A>(bool Function(A item) test) =>
      Transformer((items) => items.skipWhile(test));
}
