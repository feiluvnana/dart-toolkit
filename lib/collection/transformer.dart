/// # Transformers (`Transformer<A, B>`)
///
/// An operation that turns a sequence into another sequence, as a value.
///
/// [Sequence.transform] takes one, so every shaping step this library offers
/// is a `static` factory here rather than a method over there — which is what
/// lets each of them take its ordinary name back. `map` cannot be a method on
/// a collection beside `Map` the type; `Transformer.map` can.
library;

import 'dart:async';

import 'collector.dart';
import 'flow.dart';
import 'sequence.dart';

// ============================================================================
// TRANSFORMERS (Transformer<A, B>)
// ============================================================================

/// An operation that turns a sequence of [A] into a sequence of [B].
///
/// ```dart
/// rows.transform(.where((r) => r.live))
///     .transform(.take.first(10))
///     .collect(.sort.by((r) => r.cost));
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
/// ## One operation, two containers
///
/// [run] is the operation over an `Iterable` and [pour] the same operation
/// over a `Stream`, so one transformer shapes a [Sequence] or a [Flow] with
/// no second factory and no second type. Every operation named here supplies
/// both and streams on either.
///
/// ## Anything not here
///
/// [fn] takes the transformation directly, and a subclass takes it further —
/// see [fn].
class Transformer<A, B> {
  /// Creates a transformer that applies [run] to the whole sequence, and
  /// [pour] to a stream of one.
  ///
  /// The generative constructor a subclass calls. Reach for [fn] at a call
  /// site; this is the form for when a subclass needs a `super` call.
  ///
  /// Without a [pour] the operation still reaches a [Flow] — see [pour] for
  /// what it costs.
  const Transformer(this.run, {Stream<B> Function(Stream<A> items)? pour})
    : _pour = pour;

  /// This operation, as the plain function it is.
  ///
  /// Public because that is what makes a transformer testable without a
  /// [Sequence] anywhere near it:
  ///
  /// ```dart
  /// Transformer.map<int, String>((n) => '$n').run(const [1, 2]);   // ('1', '2')
  /// ```
  final Iterable<B> Function(Iterable<A> items) run;

  final Stream<B> Function(Stream<A> items)? _pour;

  /// The same operation over a stream — what [Flow.transform] applies.
  ///
  /// ```dart
  /// // setup: final src = Stream.fromIterable(const [1, 2]);
  /// Transformer.map<int, String>((n) => '$n').pour(src);   // Stream<String>
  /// ```
  ///
  /// A function rather than a method, for the reason [run] is a field: the
  /// three `Transformer<Never, B>` factories — [cast], `where.type` and
  /// [flat] — are handed a stream of something wider than `Never`, and a
  /// method parameter would check that at the call and throw.
  ///
  /// **Its default is correct rather than fast**: collect the stream, apply
  /// [run], emit the result. So every transformer works on a [Flow] the day
  /// it is written, including one a caller subclassed three releases ago —
  /// it just holds the whole source while it does. Every operation named in
  /// this class supplies its own and streams; [fn] is the door, and the one
  /// place the default is what runs.
  Stream<B> Function(Stream<A> items) get pour => _pour ?? _buffer<A, B>(run);

  /// The default [pour]: hold the source, apply [run], emit what came back.
  ///
  /// Declared over `Stream<Object?>` so it also works for the `Never`-sourced
  /// factories, where a `Stream<A>` parameter would reify as `Stream<Never>`
  /// and reject every stream handed to it.
  static Stream<B> Function(Stream<A> items) _buffer<A, B>(
    Iterable<B> Function(Iterable<A> items) run,
  ) => (Stream<Object?> items) async* {
    yield* Stream<B>.fromIterable(run(await items.cast<A>().toList()));
  };

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
  Transformer<A, C> then<C>(Transformer<B, C> next) => Transformer(
    (items) => next.run(run(items)),
    pour: (items) => next.pour(pour(items)),
  );

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
  Collector<A, R> into<R>(Collector<B, R> end) => Collector(
    (items) => end.run(run(items)),
    pour: (items) => end.pour(pour(items)),
  );

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

  /// The leading elements, by count or by test.
  ///
  /// `take.first(n)` and `take.when(test)` — Dart's `take` and `takeWhile`.
  /// `while` is a reserved word, so the test form is `when`.
  ///
  /// ```dart
  /// rows.transform(.take.first(10));
  /// rows.transform(.take.when((r) => r.live));
  /// ```
  ///
  /// The trailing [n] elements are `Collector.take.last(n)`, on the other
  /// type because they cannot be known before the source ends.
  static const take = _Take();

  /// Everything but some elements, by count or by test.
  ///
  /// `skip.first(n)` and `skip.when(test)` — the exact opposites of [take],
  /// and they read as opposites, which `head`/`skip` and `tail`/`trim` never
  /// did. `skip.last(n)` is `Collector.skip.last(n)`, for the same reason
  /// `take.last` is.
  static const skip = _Skip();

  /// Each element paired with its position — Python's word.
  ///
  /// The one index-aware primitive: `mapIndexed`, `filterIndexed` and
  /// `forEachIndexed` are all this followed by the plain operation, which is
  /// why none of them is a member.
  ///
  /// ```dart
  /// titles.transform(.enumerate()).transform(.map((p) => '${p.$1}. ${p.$2}'));
  /// ```
  static Transformer<A, (int, A)> enumerate<A>() => Transformer(
    _numbered,
    pour: (items) {
      var next = 0;
      return items.map((item) => (next++, item));
    },
  );

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
  ///   await concurrent.run(batch.collect(.list()), print, size: 4);
  /// }
  /// ```
  static Transformer<A, Sequence<A>> chunk<A>(int size) => Transformer(
    (items) => _chunked(items, size),
    pour: (items) => _chunkedpour(items, size),
  );

  static Stream<Sequence<A>> _chunkedpour<A>(Stream<A> items, int size) async* {
    if (size <= 0) return;
    var batch = <A>[];
    await for (final item in items) {
      batch.add(item);
      if (batch.length == size) {
        yield Sequence(batch);
        batch = <A>[];
      }
    }
    if (batch.isNotEmpty) yield Sequence(batch);
  }

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
  static Transformer<A, (A, R)> zip<A, R>(Sequence<R> other) => Transformer(
    (items) => _zipped(items, other.collect(.list())),
    pour: (items) => _zippedpour(items, other.collect(.list())),
  );

  static Stream<(A, R)> _zippedpour<A, R>(
    Stream<A> items,
    Iterable<R> other,
  ) async* {
    final right = other.iterator;
    await for (final left in items) {
      if (!right.moveNext()) return;
      yield (left, right.current);
    }
  }

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
  static Transformer<A, A> plus<A>(Sequence<A> other) => Transformer(
    (items) => items.followedBy(other.collect(.list())),
    pour: (items) async* {
      yield* items;
      yield* Stream<A>.fromIterable(other.collect(.list()));
    },
  );

  /// The elements [other] does not hold.
  static Transformer<A, A> minus<A>(Sequence<A> other) => Transformer(
    (items) => _without(items, other.collect(.set())),
    pour: (items) {
      final drop = other.collect(.set());
      return items.where((item) => !drop.contains(item));
    },
  );

  static Iterable<A> _without<A>(Iterable<A> items, Set<A> drop) sync* {
    for (final item in items) {
      if (!drop.contains(item)) yield item;
    }
  }

  /// The elements [other] also holds, duplicates removed.
  ///
  /// `intersect` is not a word people reach for; `common` is.
  static Transformer<A, A> common<A>(Sequence<A> other) => Transformer(
    (items) => _shared(items, other.collect(.set())),
    pour: (items) {
      final keep = other.collect(.set());
      final seen = <A>{};
      return items.where((item) => keep.contains(item) && seen.add(item));
    },
  );

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
  static Transformer<A, A> or<A>(Sequence<A> fallback) => Transformer(
    (items) => _orelse(items, fallback),
    pour: (items) => _orelsepour(items, fallback),
  );

  static Iterable<A> _orelse<A>(Iterable<A> items, Sequence<A> fallback) sync* {
    var any = false;
    for (final item in items) {
      any = true;
      yield item;
    }
    if (!any) yield* fallback.collect(.list());
  }

  static Stream<A> _orelsepour<A>(
    Stream<A> items,
    Sequence<A> fallback,
  ) async* {
    var any = false;
    await for (final item in items) {
      any = true;
      yield item;
    }
    if (!any) yield* Stream<A>.fromIterable(fallback.collect(.list()));
  }

  /// The elements as [R]s, throwing on one that is not.
  ///
  /// The pair with `where.type`, and the difference is what happens to an
  /// element of the wrong type: that drops it, this throws. Reach for
  /// `where.type` when the sequence is mixed on purpose and for this when a
  /// wrong element is a bug you want to hear about.
  static Transformer<Never, R> cast<R>() => Transformer<Never, R>(
    (Iterable<Object?> items) => items.cast<R>(),
    pour: (Stream<Object?> items) => items.cast<R>(),
  );

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
  /// **This is the one place the streaming rule is a promise rather than a
  /// proof.** [run] takes a closure over an `Iterable`, so without a [pour]
  /// this holds the whole source on a [Flow]. Supply both where that matters,
  /// which the caller can, having written the closure:
  ///
  /// ```dart
  /// Transformer.fn<int, int>(
  ///   (xs) => xs.map((n) => n * 2),
  ///   pour: (xs) => xs.map((n) => n * 2),
  /// );
  /// ```
  ///
  /// A subclass calling `super(run)` is the same case, with the same answer.
  static Transformer<A, B> fn<A, B>(
    Iterable<B> Function(Iterable<A> items) run, {
    Stream<B> Function(Stream<A> items)? pour,
  }) => Transformer(run, pour: pour);

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
      Transformer((items) => items.map(each), pour: (items) => items.map(each));

  /// Each element replaced by [each] of it, dropping the nulls.
  ///
  /// Kotlin's `mapNotNull`, spelled with the word this library already uses
  /// for dropping nulls — see `Sequence.nonnull`, its argument-free twin.
  Transformer<A, B> nonnull<A, B extends Object>(B? Function(A item) each) =>
      Transformer(
        (items) => items.map(each).whereType<B>(),
        pour: (items) =>
            items.map(each).where((value) => value != null).cast<B>(),
      );
}

/// The namespace behind [Transformer.where].
class _Where {
  const _Where();

  /// The elements [test] accepts.
  Transformer<A, A> call<A>(bool Function(A item) test) => Transformer(
    (items) => items.where(test),
    pour: (items) => items.where(test),
  );

  /// Only the elements that are a [R] — Kotlin's `filterIsInstance`.
  Transformer<Never, R> type<R>() => Transformer<Never, R>(
    (Iterable<Object?> items) => items.whereType<R>(),
    pour: (Stream<Object?> items) => items.where((item) => item is R).cast<R>(),
  );
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
    pour: (Stream<Object?> items) => items.expand(_asIterable<B>),
  );

  /// Each element expanded into many by [each], and the lot concatenated.
  Transformer<A, B> map<A, B>(Iterable<B> Function(A item) each) => Transformer(
    (items) => items.expand(each),
    pour: (items) => items.expand(each),
  );

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
  Transformer<A, A> by<A, K>(K Function(A item) key) => Transformer(
    (items) => _distinct(items, key),
    pour: (items) {
      final seen = <K>{};
      return items.where((item) => seen.add(key(item)));
    },
  );

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
  Transformer<A, A> first<A>(int n) => Transformer(
    (items) => items.take(n < 0 ? 0 : n),
    pour: (items) => items.take(n < 0 ? 0 : n),
  );

  /// The leading elements [test] accepts, stopping at the first it does not.
  Transformer<A, A> when<A>(bool Function(A item) test) => Transformer(
    (items) => items.takeWhile(test),
    pour: (items) => items.takeWhile(test),
  );
}

/// The namespace behind [Transformer.skip].
class _Skip {
  const _Skip();

  /// Everything but the leading [n] elements — Kotlin's `drop`.
  Transformer<A, A> first<A>(int n) => Transformer(
    (items) => items.skip(n < 0 ? 0 : n),
    pour: (items) => items.skip(n < 0 ? 0 : n),
  );

  /// Everything from the first element [test] rejects onwards.
  Transformer<A, A> when<A>(bool Function(A item) test) => Transformer(
    (items) => items.skipWhile(test),
    pour: (items) => items.skipWhile(test),
  );
}
