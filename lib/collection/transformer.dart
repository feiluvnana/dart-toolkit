/// # Transformers (`Transformer<A, B>`)
///
/// An operation that turns a sequence into another sequence, as a value.
///
/// [Sequence.transform] takes one, so every shaping step this library offers
/// is a `static` factory here rather than a method over there — which is what
/// lets each of them take its ordinary name back. `map` cannot be a method on
/// a collection beside `Map` the type; `Transformer.map` can.
///
/// The streaming half is [Pipe], and the two are separate types on purpose;
/// see the [Transformer] class doc for what that bought and what it cost.
library;

import 'collector.dart';

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
/// ## This shapes a sequence. [Pipe] shapes a flow
///
/// One operation type served both containers through 5.4.0: [run] was the
/// required half and a `pour` over a `Stream` the optional one. That is gone.
/// A sequence has [Transformer] and [Collector], reached by
/// [Sequence.transform] and [Sequence.collect]; a flow has [Pipe] and [Pour],
/// reached by [Flow.transform] and [Flow.collect].
///
/// **Nothing about the split reaches a call site.** A dot shorthand resolves
/// its name against the context type, so `.where(live)` reads the same on
/// either container and picks the factory that fits; and both containers
/// spell the members `transform` and `collect`. The four operation types are
/// what the split bought, and they are invisible where the work is written.
/// 5.5.0 briefly renamed the flow's members to `pipe` and `pour` to advertise
/// the split, which charged every call site for a change in the types.
///
/// What the split bought, on each side:
///
/// | | before | after |
/// | :--- | :--- | :--- |
/// | `sort`, `flip`, `take.last`, `skip.last` on a sequence | a [Collector], so the chain changed container twice | a transformer, here |
/// | an async element step on a flow | `flow.run(f, size: n)`, off in `concurrent` | `Pipe.map.async(f, size: n)` |
/// | `debounce`, `throttle`, `merge`, `timeout`, `handle` | no spelling at all | [Pipe] |
/// | `zip`, `plus`, `minus`, `common`, `or` between two flows | did not compile | [Pipe], taking a `Flow` |
///
/// And what it cost. The vocabulary is declared twice — roughly forty-five
/// factories here and fifty over there, against fifty-nine when it was one —
/// and **a named pipeline is no longer portable**. `Transformer.where<Row>(live)`
/// works on sequences only; `Pipe.of` adapts one across, as a conversion
/// rather than a second spelling:
///
/// ```dart
/// // setup: bool live(Row r) => r.live; final flow = Stream<Row>.empty();
/// final cleanup = Transformer.where<Row>(live);
/// rows.transform(cleanup);              // Iterable<Row>
/// flow.through(Pipe.of(cleanup));       // Stream<Row>
/// ```
///
/// [Pipe.of] buffers nothing for a filter or a map, and holds the whole
/// source for one that cannot answer before the end. The old design made
/// that same trade *silently*, for every transformer without a `pour`; now
/// it is a call somebody wrote.
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
  ///
  /// An `Iterable` in and an `Iterable` out, where every other signature in
  /// the library speaks [Sequence]. That is deliberate and it is the honest
  /// boundary of an operation *value*: this is the function, not a collection
  /// API, and the two `Transformer<Never, B>` factories — [cast] and
  /// `where.type` — need a field rather than a method so an iterable of
  /// something wider than `Never` is not rejected at the call. [flat] was a
  /// third until 5.5.0 gave it the static type it always had.
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
  ///
  /// There is no `map.async` here: awaiting is a thing that happens over
  /// time, so it is `Pipe.map.async` on the container whose elements arrive
  /// over time. A sequence of futures is `concurrent.run`.
  static const map = _Map();

  /// Each element replaced by [each] of it, dropping nulls.
  static Transformer<A, B> mapNotNull<A, B extends Object>(
          B? Function(A item) each) =>
      map.nonnull(each);

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

  /// Only the elements that are an [R] — Kotlin's `filterIsInstance`.
  static Transformer<Never, R> whereType<R>() => where.type<R>();

  /// Flattens, or expands each element into many.
  ///
  /// `flat()` concatenates elements that are themselves sequences — Kotlin's
  /// `flatten` — and `flat.map(each)` turns each element into a sequence
  /// first, which is `flatMap` split at the capital.
  ///
  /// ```dart
  /// // setup: final Iterable<Iterable<Row>> groups = const [<Row>[]];
  /// groups.transform(.flat());
  /// rows.transform(.flat.map((r) => [r, r]));
  /// ```
  ///
  /// `flat()` is a `Transformer<Sequence<B>, B>`, so the analyzer checks the
  /// receiver and infers `B` from it. It was a `Transformer<Never, B>`
  /// through 5.4.0 — which type-checked against *any* sequence and threw
  /// [StateError] at runtime on one whose elements were not iterable, and
  /// which could infer nothing, so every call site wrote `.flat<Row>()` even
  /// where the answer was unambiguous.
  ///
  /// A sequence of something else nested — a `Sequence<List<Row>>` — is one
  /// `map` away: `transform(.map((l) => l.seq)).transform(.flat())`.
  static const flat = _Flat();

  /// Each element expanded into many by [each], and concatenated.
  static Transformer<A, B> flatMap<A, B>(
          Iterable<B> Function(A item) each) =>
      flat.map(each);

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

  /// The elements, keeping the first of each distinct [key].
  static Transformer<A, A> uniqueBy<A, K>(K Function(A item) key) =>
      unique.by(key);

  /// The leading or trailing elements, by count or by test.
  ///
  /// `take.first(n)` and `take.when(test)` — Dart's `take` and `takeWhile` —
  /// and `take.last(n)` for the other end. `while` is a reserved word, so the
  /// test form is `when`.
  ///
  /// ```dart
  /// rows.transform(.take.first(10));
  /// rows.transform(.take.when((r) => r.live));
  /// rows.transform(.take.last(10));
  /// ```
  ///
  /// `take.last` was a [Collector] through 5.4.0, and on a [Flow] it still
  /// is — see [take] over there. On a sequence it never needed to be: the
  /// source has an end, and holding it to find the end is what the operation
  /// *is* rather than a change of container.
  static const take = _Take();

  /// The leading elements [test] accepts, stopping at the first it does not.
  static Transformer<A, A> takeWhile<A>(bool Function(A item) test) =>
      take.when(test);

  /// The trailing [n] elements, or all of them when there are fewer.
  static Transformer<A, A> takeLast<A>(int n) => take.last(n);

  /// Everything but some elements, by count or by test.
  ///
  /// `skip.first(n)`, `skip.when(test)` and `skip.last(n)` — the exact
  /// opposites of [take], and they read as opposites, which `head`/`skip` and
  /// `tail`/`trim` never did.
  static const skip = _Skip();

  /// Everything from the first element [test] rejects onwards.
  static Transformer<A, A> skipWhile<A>(bool Function(A item) test) =>
      skip.when(test);

  /// Everything but the trailing [n] elements.
  static Transformer<A, A> skipLast<A>(int n) => skip.last(n);

  /// The elements in ascending order.
  ///
  /// `sort()` needs [Comparable] elements, `sort.by(key)` orders by a key, and
  /// `sort.using(compare)` takes a comparator — Kotlin's `sorted`, `sortedBy`
  /// and `sortedWith`. Never mutates the source, which `List.sort` does.
  ///
  /// ```dart
  /// titles.transform(.sort());
  /// rows.transform(.sort.by((r) => r.cost)).transform(.take.first(10));
  /// ```
  ///
  /// A transformer, and it took two moves to get here. It was one through
  /// 5.2.0, became a [Collector] in 5.3.0 under the law that no element of a
  /// sorted result is known before the last element of the source, and is one
  /// again now that the law has the container it was really about. **`sort`
  /// is not a [Pipe]** — that is the sharp statement — but on a sequence it
  /// only ever meant *this reads the whole source*, which `collect(.list())`
  /// says already and a change of container said far too loudly:
  ///
  /// ```dart no-compile
  /// // 5.4.0 — three calls and two container types
  /// rows.collect(.sort.by((r) => r.cost)).transform(.take.first(10)).collect(.list());
  /// // now
  /// rows.transform(.sort.by((r) => r.cost)).transform(.take.first(10)).collect(.list());
  /// ```
  ///
  /// Sorting inside a bucket keeps the spelling it gained in 5.3.0, because
  /// [Collector.group]`.into` takes a collector and [into] makes one out of
  /// this: `group.into(f, .sort.by(g).into(.seq()))`.
  static const sort = _Sort();

  /// The elements back to front.
  ///
  /// Here rather than on [Collector] for [sort]'s reason, and `Pour.flip` is
  /// the flow's form: the first element of a reversed sequence is the last of
  /// the source.
  static Transformer<A, A> flip<A>() =>
      Transformer((items) => items.toList().reversed);

  /// Every element passed to [each] and then let through unchanged.
  ///
  /// The one for a `print` in the middle of a chain, or a counter. A [map]
  /// that returns its input says the same thing and reads like it meant to
  /// change something.
  ///
  /// ```dart
  /// rows.transform(.where((r) => r.live))
  ///     .transform(.tap((r) => bar.tick(1, r.sku)))
  ///     .collect(.list());
  /// ```
  ///
  /// `Pipe.tap` has existed since flows split from sequences in 5.5.0, and
  /// nothing about watching an element go past is particular to time — it was
  /// simply the half that got written. Lazily, like every step here: [each]
  /// runs when the terminal walks, once per walk.
  static Transformer<A, A> tap<A>(void Function(A item) each) => Transformer(
    (items) => items.map((item) {
      each(item);
      return item;
    }),
  );

  /// Each element paired with its position — Python's word.
  ///
  /// The one index-aware primitive: `mapIndexed`, `filterIndexed` and
  /// `forEachIndexed` are all this followed by the plain operation, which is
  /// why none of them is a member.
  ///
  /// ```dart
  /// titles.transform(.enumerate()).transform(.map((p) => '${p.$1}. ${p.$2}'));
  /// ```
  static Transformer<A, (int, A)> enumerate<A>() => Transformer(_numbered);

  static Iterable<(int, A)> _numbered<A>(Iterable<A> items) sync* {
    var next = 0;
    for (final item in items) {
      yield (next++, item);
    }
  }

  /// The elements in consecutive groups of [size], the last one short.
  ///
  /// ```dart
  /// for (final batch in rows.transform(.chunk(100)).collect(.list())) {
  ///   await concurrent.run(batch, print, size: 4);
  /// }
  /// ```
  ///
  /// Throws [ArgumentError] on a [size] below one. It yielded nothing
  /// through 5.4.0, which is a chunking of no rows into no batches and is
  /// nobody's intention — `chunk(n)` with an `n` that came out zero is an
  /// arithmetic bug upstream, and silence let it reach the output.
  static Transformer<A, List<A>> chunk<A>(int size) {
    _positive(size);
    return Transformer((items) => _chunked(items, size));
  }

  static Iterable<List<A>> _chunked<A>(Iterable<A> items, int size) sync* {
    var batch = <A>[];
    for (final item in items) {
      batch.add(item);
      if (batch.length == size) {
        yield batch;
        batch = <A>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// The elements paired elementwise with [other], stopping at the shorter.
  ///
  /// A record, not a `Pair` type.
  static Transformer<A, (A, R)> zip<A, R>(Iterable<R> other) =>
      Transformer((items) => _zipped(items, other));

  static Iterable<(A, R)> _zipped<A, R>(
    Iterable<A> items,
    Iterable<R> other,
  ) sync* {
    final left = items.iterator;
    final right = other.iterator;
    while (left.moveNext() && right.moveNext()) {
      yield (left.current, right.current);
    }
  }

  /// The elements followed by [other]'s.
  static Transformer<A, A> plus<A>(Iterable<A> other) =>
      Transformer((items) => items.followedBy(other));

  /// The elements [other] does not hold.
  static Transformer<A, A> minus<A>(Iterable<A> other) =>
      Transformer((items) => _without(items, other.toSet()));

  static Iterable<A> _without<A>(Iterable<A> items, Set<A> drop) sync* {
    for (final item in items) {
      if (!drop.contains(item)) yield item;
    }
  }

  /// The elements [other] also holds, duplicates removed.
  ///
  /// `intersect` is not a word people reach for; `common` is.
  static Transformer<A, A> common<A>(Iterable<A> other) =>
      Transformer((items) => _shared(items, other.toSet()));

  static Iterable<A> _shared<A>(Iterable<A> items, Set<A> keep) sync* {
    final seen = <A>{};
    for (final item in items) {
      if (keep.contains(item) && seen.add(item)) yield item;
    }
  }

  /// The elements, or [fallback]'s when there are none — Kotlin's `ifEmpty`.
  static Transformer<A, A> or<A>(Iterable<A> fallback) =>
      Transformer((items) => _orelse(items, fallback));

  static Iterable<A> _orelse<A>(Iterable<A> items, Iterable<A> fallback) sync* {
    var any = false;
    for (final item in items) {
      any = true;
      yield item;
    }
    if (!any) yield* fallback;
  }

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
  ///
  /// There is no streaming caveat on this any more. It took a closure over an
  /// `Iterable` and an optional `pour` through 5.4.0, and without the second
  /// one it quietly held the whole source on a [Flow]. A transformer shapes a
  /// sequence and nothing else now; [Pipe.fn] is the streaming door, and it
  /// takes a stream because that is the only thing it can take.
  static Transformer<A, B> fn<A, B>(
    Iterable<B> Function(Iterable<A> items) run,
  ) => Transformer(run);

  @override
  String toString() => 'Transformer<$A, $B>';
}

/// Rejects a batch size that cannot produce a batch.
void _positive(int size) {
  if (size < 1) {
    throw ArgumentError.value(size, 'size', 'must be at least 1');
  }
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

  /// The elements concatenated, each of them an [Iterable].
  ///
  /// [B] infers from the receiver, so `.flat()` is the whole call.
  Transformer<Iterable<B>, B> call<B>() =>
      Transformer((items) => items.expand((item) => item));

  /// Each element expanded into many by [each], and the lot concatenated.
  Transformer<A, B> map<A, B>(Iterable<B> Function(A item) each) => Transformer(
    (items) => items.expand(each),
  );
}

/// The namespace behind [Transformer.unique].
class _Unique {
  const _Unique();

  /// The elements, duplicates removed.
  Transformer<A, A> call<A>() => by<A, A>((item) => item);

  /// The elements, keeping the first of each distinct [key].
  Transformer<A, A> by<A, K>(K Function(A item) key) =>
      Transformer((items) => _distinct(items, key));

  static Iterable<A> _distinct<A, K>(
    Iterable<A> items,
    K Function(A item) key,
  ) sync* {
    final seen = <K>{};
    for (final item in items) {
      if (seen.add(key(item))) yield item;
    }
  }
}

/// The namespace behind [Transformer.take].
class _Take {
  const _Take();

  /// The leading [n] elements, or all of them when there are fewer.
  Transformer<A, A> first<A>(int n) =>
      Transformer((items) => items.take(n < 0 ? 0 : n));

  /// The leading elements [test] accepts, stopping at the first it does not.
  Transformer<A, A> when<A>(bool Function(A item) test) =>
      Transformer((items) => items.takeWhile(test));

  /// The trailing [n] elements, or all of them when there are fewer.
  ///
  /// The half that needs the end: `take.first(n)` can yield before the source
  /// is exhausted, `take.last(n)` cannot. `Collector.last` beside it is the
  /// last *element*, which is the relationship `Collector.first` and
  /// [Transformer.take]`.first` already have.
  Transformer<A, A> last<A>(int n) => Transformer((items) {
    if (n <= 0) return const [];
    final all = items.toList();
    return all.length <= n ? all : all.sublist(all.length - n);
  });
}

/// The namespace behind [Transformer.skip].
class _Skip {
  const _Skip();

  /// Everything but the leading [n] elements — Kotlin's `drop`.
  Transformer<A, A> first<A>(int n) =>
      Transformer((items) => items.skip(n < 0 ? 0 : n));

  /// Everything from the first element [test] rejects onwards.
  Transformer<A, A> when<A>(bool Function(A item) test) =>
      Transformer((items) => items.skipWhile(test));

  /// Everything but the trailing [n] elements — Kotlin's `dropLast`.
  Transformer<A, A> last<A>(int n) => Transformer((items) {
    if (n <= 0) return items;
    final all = items.toList();
    return all.length <= n ? const [] : all.sublist(0, all.length - n);
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
