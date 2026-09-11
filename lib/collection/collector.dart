/// # Collectors (`Collector<A, R>`)
///
/// An operation that turns a sequence into a single value, as a value.
///
/// [Sequence.collect] takes one. This is the half with Java's precedent —
/// `Collectors` is twenty years old and uncontroversial — and the half where
/// the old surface sprawled worst: twenty-three members that shared no shape
/// with each other and were reached for once per pipeline.
library;

import 'dart:async';

import 'dictionary.dart';
import 'flow.dart';
import 'sequence.dart';

// ============================================================================
// COLLECTORS (Collector<A, R>)
// ============================================================================

/// An operation that turns a sequence of [A] into a single [R].
///
/// ```dart
/// rows.collect(.count());
/// rows.collect(.max.by((r) => r.score));
/// rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)));
/// ```
///
/// ## The dot is the point
///
/// The context type resolves the name, so nothing here collides with anything
/// out there: [first] is not `Iterable.first`, [count] is not a field on your
/// row. A compound operation splits at the capital rather than inventing a
/// word — `firstWhere` is [first]`.where`, `countBy` is [count]`.by`, `maxBy`
/// is [max]`.by`, `associateBy` is [associate]`.by`.
///
/// ## Everything is nullable, nothing throws
///
/// [first], [last], [single], [at], [max] and [min] hand back a `A?`. The
/// caller asked for a value and the honest answer is that there is not one, so
/// `?? fallback` replaces Kotlin's whole `OrNull` half-vocabulary — the same
/// contract `Slot.read` and `Json.text` keep.
///
/// ## When the result type comes from anywhere but a lambda's return, name it
///
/// Inference reads [R] out of the callback you pass. [fold] takes its result
/// type from a *value*, and [then] changes it after the fact, so neither can
/// be inferred through a dot shorthand. Both have the same two answers:
///
/// ```dart
/// final int total = rows.collect(.fold(0, (t, r) => t + r.qty.toInt()));
/// rows.collect(.fold<Row, int>(0, (t, r) => t + r.qty.toInt()));
/// ```
///
/// Annotating the lambda is *not* the third answer — `(int t, Row r)` pins the
/// lambda's own type and leaves [R] free just the same.
///
/// [sum], [avg], [count] and [join] exist so the common folds never reach for
/// [fold] at all, which is exactly why Java ships `summingInt` beside
/// `reducing`.
class Collector<A, R> {
  /// Creates a collector that applies [run] to the whole sequence, and [pour]
  /// to a stream of one.
  ///
  /// The generative constructor a subclass calls. Reach for [fn] at a call
  /// site; this is the form for when a subclass needs a `super` call.
  ///
  /// Without a [pour] the operation still reaches a [Flow] — see [pour] for
  /// what it costs.
  const Collector(this.run, {Future<R> Function(Stream<A> items)? pour})
    : _pour = pour;

  /// This operation, as the plain function it is.
  ///
  /// ```dart
  /// Collector.count<int>().run(const [1, 2, 3]);    // 3
  /// ```
  final R Function(Iterable<A> items) run;

  final Future<R> Function(Stream<A> items)? _pour;

  /// The same operation over a stream — what [Flow.collect] applies.
  ///
  /// ```dart
  /// // setup: final src = Stream.fromIterable(const [1, 2, 3]);
  /// await Collector.count<int>().pour(src);    // 3
  /// ```
  ///
  /// A function rather than a method, for the reason [run] is a field, and
  /// with the same default: hold the stream, apply [run], hand back what came
  /// back. So every collector works on a [Flow] the day it is written,
  /// including one a caller subclassed three releases ago.
  ///
  /// Thirty-one of the named collectors supply their own, eleven of those
  /// stopping the source early — `first()` over a crawl cancels the
  /// subscription at the first item, which stops the crawl. The rest hold the
  /// source because that is what the operation *is*: [sort], [flip],
  /// `take.last`, `skip.last` and [seq] cannot answer from less than all of
  /// it. [fn] is the door.
  Future<R> Function(Stream<A> items) get pour => _pour ?? _buffer<A, R>(run);

  /// The default [pour]: hold the source, apply [run], hand the result back.
  ///
  /// Declared over `Stream<Object?>` so a `Collector<Never, R>` is handed a
  /// stream it will accept, the same way [Transformer]'s default is.
  static Future<R> Function(Stream<A> items) _buffer<A, R>(
    R Function(Iterable<A> items) run,
  ) =>
      (Stream<Object?> items) async => run(await items.cast<A>().toList());

  // --------------------------------------------------------------------------
  // Composing
  // --------------------------------------------------------------------------

  /// This collector's result, finished with [end] — Java's
  /// `collectingAndThen`.
  ///
  /// ```dart
  /// final Collector<Row, String> summary =
  ///     Collector.count<Row>().then((n) => '$n rows');
  ///
  /// rows.collect(summary);
  /// ```
  ///
  /// **For a named collector, not for inline chaining.** `then` changes [R],
  /// which leaves inference nothing to pin [A] to, so
  /// `rows.collect(.count().then(…))` does not compile. Give it a context type
  /// as above, or write `Collector.count<Row>()` out. Inline composition is
  /// what a downstream collector is for — `group.into(f, .count())` — and that
  /// one infers cleanly.
  Collector<A, R2> then<R2>(R2 Function(R result) end) => Collector(
    (items) => end(run(items)),
    pour: (items) async => end(await pour(items)),
  );

  // --------------------------------------------------------------------------
  // Counting and asking
  // --------------------------------------------------------------------------

  /// How many elements there are.
  ///
  /// Callable, and a namespace: `count.where(test)` counts what [test] accepts
  /// and `count.by(key)` counts under each key, which is `countBy` split at
  /// the capital.
  ///
  /// ```dart
  /// rows.collect(.count());
  /// rows.collect(.count.where((r) => r.live));
  /// rows.collect(.count.by((r) => r.host));    // Dictionary<String, int>
  /// ```
  static const count = _Count();

  /// Whether the sequence holds nothing.
  ///
  /// There is no complement: `!seq.collect(.empty())` already says the other
  /// thing.
  static Collector<A, bool> empty<A>() =>
      Collector((items) => items.isEmpty, pour: (items) => items.isEmpty);

  /// Whether [value] is one of the elements.
  static Collector<A, bool> has<A>(A value) => Collector(
    (items) => items.contains(value),
    pour: (items) => items.contains(value),
  );

  /// Whether [test] accepts at least one element.
  ///
  /// There is no `none`: `!seq.collect(.any(test))` *is* `none`.
  static Collector<A, bool> any<A>(bool Function(A item) test) =>
      Collector((items) => items.any(test), pour: (items) => items.any(test));

  /// Whether [test] accepts every element — vacuously true when empty.
  static Collector<A, bool> all<A>(bool Function(A item) test) => Collector(
    (items) => items.every(test),
    pour: (items) => items.every(test),
  );

  // --------------------------------------------------------------------------
  // Picking one
  // --------------------------------------------------------------------------

  /// The first element, or `null` when there is none.
  ///
  /// Callable, and a namespace: `first.where(test)` is the first element
  /// [test] accepts — Dart's `firstWhere` without the `orElse:` apology.
  ///
  /// ```dart
  /// rows.collect(.first());
  /// rows.collect(.first.where((r) => r.live));
  /// ```
  static const first = _First();

  /// The last element, or `null` when there is none.
  ///
  /// Callable, and a namespace, on the same terms as [first].
  static const last = _Last();

  /// The only element, or `null` when there is not exactly one.
  ///
  /// Callable, and a namespace, on the same terms as [first]. `single.where`
  /// is `singleWhere`, and it is `null` rather than a throw when the test
  /// accepts none or several.
  static const single = _Single();

  /// The element at [index], or `null` when the sequence is shorter.
  static Collector<A, A?> at<A>(int index) => Collector(
    (items) {
      if (index < 0) return null;
      var i = 0;
      for (final item in items) {
        if (i++ == index) return item;
      }
      return null;
    },
    pour: (items) async {
      if (index < 0) return null;
      var i = 0;
      await for (final item in items) {
        if (i++ == index) return item;
      }
      return null;
    },
  );

  /// Where an element is — Dart's `indexOf` and `indexWhere`.
  ///
  /// `index.of(value)` and `index.where(test)`, both `null` when nothing
  /// matches. The lookup *table* is [associate]`.by`, which is a different
  /// idea and now has a different name.
  static const index = _Index();

  /// The element with the largest [max]`.by(key)`, or `null` when empty.
  ///
  /// Kotlin's `maxBy`, split at the capital. Was `best`.
  static const max = _Max();

  /// The element with the smallest [min]`.by(key)`, or `null` when empty.
  ///
  /// Not a complement of [max] that `!` could cover — negating a maximum does
  /// not give a minimum.
  static const min = _Min();

  // --------------------------------------------------------------------------
  // Reducing
  // --------------------------------------------------------------------------

  /// [each] applied across the sequence, starting from [initial].
  ///
  /// Dart's word, kept. There is no `reduce`: this covers it, and the indexed
  /// form is `transform(.enumerate())` first.
  ///
  /// [R] comes from [initial] rather than from a lambda's return, so a dot
  /// shorthand needs a context type — see the class doc.
  static Collector<A, R> fold<A, R>(
    R initial,
    R Function(R total, A item) each,
  ) => Collector(
    (items) {
      var total = initial;
      for (final item in items) {
        total = each(total, item);
      }
      return total;
    },
    pour: (items) async {
      var total = initial;
      await for (final item in items) {
        total = each(total, item);
      }
      return total;
    },
  );

  /// The total of [of] across the sequence; `0` when empty.
  ///
  /// The selector is always required, including on a sequence that is already
  /// numbers (`.sum((n) => n)`), because one spelling of an operation is worth
  /// five characters in the rarer case.
  static Collector<A, num> sum<A>(num Function(A item) of) => Collector(
    (items) {
      num total = 0;
      for (final item in items) {
        total += of(item);
      }
      return total;
    },
    pour: (items) async {
      num total = 0;
      await for (final item in items) {
        total += of(item);
      }
      return total;
    },
  );

  /// The mean of [of] across the sequence, or `null` when empty.
  static Collector<A, double?> avg<A>(num Function(A item) of) => Collector(
    (items) {
      num total = 0;
      var seen = 0;
      for (final item in items) {
        total += of(item);
        seen++;
      }
      return seen == 0 ? null : total / seen;
    },
    pour: (items) async {
      num total = 0;
      var seen = 0;
      await for (final item in items) {
        total += of(item);
        seen++;
      }
      return seen == 0 ? null : total / seen;
    },
  );

  /// The elements as text, joined by [separator].
  ///
  /// [prefix] and [suffix] wrap the result, [of] renders each element, and
  /// [limit] caps how many are shown — which is what makes this a summary
  /// printer rather than a plain join:
  ///
  /// ```dart
  /// rows.collect(.join(', ', prefix: '[', suffix: ']', limit: 3,
  ///     of: (r) => r.name));
  /// // '[Ada, Alan, Grace, …]'
  /// ```
  static Collector<A, String> join<A>(
    String separator, {
    String prefix = '',
    String suffix = '',
    int? limit,
    String Function(A item)? of,
  }) => Collector(
    (items) {
      final buffer = StringBuffer(prefix);
      var shown = 0;
      var more = false;
      for (final item in items) {
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
    },
    pour: (items) async {
      final buffer = StringBuffer(prefix);
      var shown = 0;
      var more = false;
      await for (final item in items) {
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
    },
  );

  // --------------------------------------------------------------------------
  // Reordering, which needs the end
  // --------------------------------------------------------------------------

  /// The elements in ascending order, as a [Sequence].
  ///
  /// `sort()` needs [Comparable] elements, `sort.by(key)` orders by a key, and
  /// `sort.using(compare)` takes a comparator — Kotlin's `sorted`, `sortedBy`
  /// and `sortedWith`. Never mutates the source, which `List.sort` does.
  ///
  /// ```dart
  /// titles.collect(.sort());
  /// rows.collect(.sort.by((r) => r.cost));
  /// rows.collect(.sort.using((a, b) => a.host.compareTo(b.host)));
  /// ```
  ///
  /// A collector rather than a [Transformer], because no element of a sorted
  /// result is known before the last element of the source has arrived — the
  /// law under Rule 3. It was a transformer through 5.3.0, which read as
  /// though sorting were free and was the one shape that could not be a
  /// downstream collector. Now it can:
  ///
  /// ```dart
  /// rows.collect(.group.into((r) => r.host, .sort.by((r) => r.cost)));
  /// // Dictionary<String, Sequence<Row>> — every bucket sorted, in one pass
  /// ```
  static const sort = _Sort();

  /// The elements back to front, as a [Sequence].
  ///
  /// Here rather than on [Transformer] for [sort]'s reason: the first element
  /// of a reversed sequence is the last of the source.
  static Collector<A, Sequence<A>> flip<A>() =>
      Collector((items) => Sequence(items.toList().reversed));

  /// The trailing elements — `take.last(n)`.
  ///
  /// The other half of `Transformer.take`, and the half that needs the end:
  /// `take.first(n)` can yield before the source does, `take.last(n)` cannot.
  ///
  /// ```dart
  /// rows.collect(.take.last(10));      // Sequence<Row>
  /// ```
  ///
  /// [last] beside it is the last *element*, which is the relationship
  /// [first] and `Transformer.take.first` already have.
  static const take = _Take();

  /// Everything but the trailing elements — `skip.last(n)`.
  ///
  /// The exact opposite of [take]`.last`, and here for the same reason.
  static const skip = _Skip();

  // --------------------------------------------------------------------------
  // Splitting into the other collection
  // --------------------------------------------------------------------------

  /// The elements bucketed into a [Dictionary].
  ///
  /// `group.by(key)` gives every bucket as a [Sequence], in encounter order.
  /// `group.into(key, down)` reduces each bucket with a second collector *in
  /// the same pass* — the one Java idea that changes what you can express
  /// rather than how it reads, and `into` is the word [Transformer.into]
  /// already uses for giving an operation its ending:
  ///
  /// ```dart
  /// rows.collect(.group.by((r) => r.host));
  /// // Dictionary<String, Sequence<Row>>
  ///
  /// rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)));
  /// // Dictionary<String, num> — not a dictionary of sequences and then a map
  ///
  /// rows.collect(.group.into((r) => r.host, .max.by((r) => r.cost)));
  /// ```
  ///
  /// Two members rather than one with an optional argument, because an
  /// omitted downstream collector would leave its result type with nothing to
  /// be inferred from and every bucket would arrive as `dynamic`.
  static const group = _Group();

  /// A lookup table keyed by `associate.by(key)` — Kotlin's `associateBy`.
  ///
  /// The last element to claim a key wins.
  ///
  /// ```dart
  /// rows.collect(.associate.by((r) => r.sku));
  /// // Dictionary<String, Row>
  /// ```
  ///
  /// To key something other than the elements themselves, pair it first and
  /// end with [dict] — which is what this is, in one line:
  ///
  /// ```dart
  /// rows.transform(.map((r) => (r.sku, r.price))).collect(.dict());
  /// // Dictionary<String, num>
  /// ```
  static const associate = _Associate();

  /// A sequence of `(key, value)` records as a [Dictionary].
  ///
  /// The way back into the keyed collection from anything that produced
  /// pairs, and the twin of `Dictionary.pairs`. The last record to claim a key
  /// wins.
  static Collector<(K, V), Dictionary<K, V>> dict<K, V>() => Collector(
    (pairs) => Dictionary.of(pairs),
    pour: (pairs) async => Dictionary.of(await pairs.toList()),
  );

  /// The elements [test] accepts and the elements it rejects.
  ///
  /// A record, so both halves keep their name:
  ///
  /// ```dart
  /// final (live, dead) = rows.collect(.split((r) => r.ok));
  /// ```
  static Collector<A, (Sequence<A>, Sequence<A>)> split<A>(
    bool Function(A item) test,
  ) => Collector(
    (items) {
      final yes = <A>[];
      final no = <A>[];
      for (final item in items) {
        (test(item) ? yes : no).add(item);
      }
      return (Sequence(yes), Sequence(no));
    },
    pour: (items) async {
      final yes = <A>[];
      final no = <A>[];
      await for (final item in items) {
        (test(item) ? yes : no).add(item);
      }
      return (Sequence(yes), Sequence(no));
    },
  );

  // --------------------------------------------------------------------------
  // Leaving
  // --------------------------------------------------------------------------

  /// Calls [each] on every element — Dart's `forEach`, spelled the way Rule 4
  /// spells a compound.
  ///
  /// `each` is what this library calls the *callback* in [fold] and `map`, so
  /// the operation gets the other half of the name.
  static Collector<A, void> foreach<A>(void Function(A item) each) =>
      Collector((items) {
        for (final item in items) {
          each(item);
        }
      }, pour: (items) => items.forEach(each));

  /// The elements as a list — the walk, and the result of it.
  ///
  /// The way out. A [Sequence] holds a recipe and never hands it over, so
  /// this is how a sequence becomes something Dart's own APIs will take —
  /// and the walk happens here, once. It is a downstream collector too,
  /// where there is no receiver to say it on: `group.into(f, .list())`.
  static Collector<A, List<A>> list<A>() =>
      Collector((items) => items.toList(), pour: (items) => items.toList());

  /// The distinct elements as a set.
  static Collector<A, Set<A>> set<A>() =>
      Collector((items) => items.toSet(), pour: (items) => items.toSet());

  /// The elements as a [Sequence] — the identity collector.
  ///
  /// What `group.by` gives each bucket, and the way to end a pipeline built
  /// with [Transformer.into] without leaving this vocabulary.
  static Collector<A, Sequence<A>> seq<A>() =>
      Collector((items) => Sequence(items));

  /// An arbitrary reduction, for anything the named collectors do not cover.
  ///
  /// ```dart
  /// rows.collect(.fn((xs) => xs.fold(StringBuffer(),
  ///     (b, r) => b..write(r.name)).toString()));
  /// ```
  ///
  /// The door in a closed set. For a reduction with options, one used in six
  /// pipelines, or one worth a test of its own, subclass [Collector] instead —
  /// which is why this class is not `final`.
  ///
  /// **This is the one place the streaming rule is a promise rather than a
  /// proof**, the same way [Transformer.fn] is: [run] takes a closure over an
  /// `Iterable`, so without a [pour] this holds the whole source on a [Flow].
  /// Supply both where that matters.
  static Collector<A, R> fn<A, R>(
    R Function(Iterable<A> items) run, {
    Future<R> Function(Stream<A> items)? pour,
  }) => Collector(run, pour: pour);

  @override
  String toString() => 'Collector<$A, $R>';
}

// ============================================================================
// THE NAMESPACES
// ============================================================================

/// The namespace behind [Collector.count].
class _Count {
  const _Count();

  /// How many elements there are.
  Collector<A, int> call<A>() =>
      Collector((items) => items.length, pour: (items) => items.length);

  /// How many elements [test] accepts.
  Collector<A, int> where<A>(bool Function(A item) test) => Collector(
    (items) => items.where(test).length,
    pour: (items) => items.where(test).length,
  );

  /// How many elements fall under each [key] — Kotlin's `countBy`.
  ///
  /// Exactly `group.into(key, .count())`, and defined as it: one implementation,
  /// two spellings of a call, because this is the one a script writes ten
  /// times for every one of the general form.
  Collector<A, Dictionary<K, int>> by<A, K>(K Function(A item) key) =>
      const _Group().into(key, const _Count().call<A>());
}

/// The namespace behind [Collector.first].
class _First {
  const _First();

  /// The first element, or `null` when there is none.
  Collector<A, A?> call<A>() => where((_) => true);

  /// The first element [test] accepts, or `null`.
  Collector<A, A?> where<A>(bool Function(A item) test) => Collector(
    (items) {
      for (final item in items) {
        if (test(item)) return item;
      }
      return null;
    },
    pour: (items) async {
      await for (final item in items) {
        if (test(item)) return item;
      }
      return null;
    },
  );
}

/// The namespace behind [Collector.last].
class _Last {
  const _Last();

  /// The last element, or `null` when there is none.
  Collector<A, A?> call<A>() => where((_) => true);

  /// The last element [test] accepts, or `null`.
  Collector<A, A?> where<A>(bool Function(A item) test) => Collector(
    (items) {
      A? found;
      for (final item in items) {
        if (test(item)) found = item;
      }
      return found;
    },
    pour: (items) async {
      A? found;
      await for (final item in items) {
        if (test(item)) found = item;
      }
      return found;
    },
  );
}

/// The namespace behind [Collector.single].
class _Single {
  const _Single();

  /// The only element, or `null` when there is not exactly one.
  Collector<A, A?> call<A>() => where((_) => true);

  /// The only element [test] accepts, or `null` when it is not exactly one.
  Collector<A, A?> where<A>(bool Function(A item) test) => Collector(
    (items) {
      A? found;
      var seen = 0;
      for (final item in items) {
        if (!test(item)) continue;
        if (++seen > 1) return null;
        found = item;
      }
      return seen == 1 ? found : null;
    },
    pour: (items) async {
      A? found;
      var seen = 0;
      await for (final item in items) {
        if (!test(item)) continue;
        if (++seen > 1) return null;
        found = item;
      }
      return seen == 1 ? found : null;
    },
  );
}

/// The namespace behind [Collector.index].
class _Index {
  const _Index();

  /// The position of the first element equal to [value], or `null`.
  Collector<A, int?> of<A>(A value) => where((item) => item == value);

  /// The position of the first element [test] accepts, or `null`.
  Collector<A, int?> where<A>(bool Function(A item) test) => Collector(
    (items) {
      var i = 0;
      for (final item in items) {
        if (test(item)) return i;
        i++;
      }
      return null;
    },
    pour: (items) async {
      var i = 0;
      await for (final item in items) {
        if (test(item)) return i;
        i++;
      }
      return null;
    },
  );
}

/// The namespace behind [Collector.max].
class _Max {
  const _Max();

  /// The element with the largest [key], or `null` when empty.
  Collector<A, A?> by<A>(Comparable<Object?> Function(A item) key) => Collector(
    (items) => _extreme(items, key, 1),
    pour: (items) => _extremepour(items, key, 1),
  );
}

/// The namespace behind [Collector.min].
class _Min {
  const _Min();

  /// The element with the smallest [key], or `null` when empty.
  Collector<A, A?> by<A>(Comparable<Object?> Function(A item) key) => Collector(
    (items) => _extreme(items, key, -1),
    pour: (items) => _extremepour(items, key, -1),
  );
}

A? _extreme<A>(
  Iterable<A> items,
  Comparable<Object?> Function(A item) key,
  int sign,
) {
  A? found;
  Comparable<Object?>? mark;
  for (final item in items) {
    final value = key(item);
    if (mark == null || value.compareTo(mark) * sign > 0) {
      mark = value;
      found = item;
    }
  }
  return found;
}

Future<A?> _extremepour<A>(
  Stream<A> items,
  Comparable<Object?> Function(A item) key,
  int sign,
) async {
  A? found;
  Comparable<Object?>? mark;
  await for (final item in items) {
    final value = key(item);
    if (mark == null || value.compareTo(mark) * sign > 0) {
      mark = value;
      found = item;
    }
  }
  return found;
}

/// The namespace behind [Collector.sort].
class _Sort {
  const _Sort();

  /// The elements in ascending order, which needs them [Comparable].
  Collector<A, Sequence<A>> call<A>() =>
      using((a, b) => (a as Comparable<Object?>).compareTo(b));

  /// The elements in ascending order of [key].
  Collector<A, Sequence<A>> by<A>(Comparable<Object?> Function(A item) key) =>
      using((a, b) => key(a).compareTo(key(b)));

  /// The elements ordered by [compare] — Kotlin's `sortedWith`.
  Collector<A, Sequence<A>> using<A>(int Function(A a, A b) compare) =>
      Collector((items) => Sequence(items.toList()..sort(compare)));
}

/// The namespace behind [Collector.take].
class _Take {
  const _Take();

  /// The trailing [n] elements, or all of them when there are fewer.
  Collector<A, Sequence<A>> last<A>(int n) => Collector((items) {
    if (n <= 0) return const Sequence([]);
    final all = items.toList();
    return Sequence(all.length <= n ? all : all.sublist(all.length - n));
  });
}

/// The namespace behind [Collector.skip].
class _Skip {
  const _Skip();

  /// Everything but the trailing [n] elements — Kotlin's `dropLast`.
  Collector<A, Sequence<A>> last<A>(int n) => Collector((items) {
    if (n <= 0) return Sequence(items);
    final all = items.toList();
    return Sequence(
      all.length <= n ? const [] : all.sublist(0, all.length - n),
    );
  });
}

/// The namespace behind [Collector.group].
class _Group {
  const _Group();

  /// The elements bucketed by [key], every bucket a [Sequence].
  Collector<A, Dictionary<K, Sequence<A>>> by<A, K>(K Function(A item) key) =>
      into(key, Collector<A, Sequence<A>>(Sequence.new));

  /// The elements bucketed by [key], every bucket reduced by [down].
  ///
  /// One pass: the buckets are never materialised as sequences first.
  Collector<A, Dictionary<K, R>> into<A, K, R>(
    K Function(A item) key,
    Collector<A, R> down,
  ) => Collector(
    (items) {
      final buckets = <K, List<A>>{};
      for (final item in items) {
        (buckets[key(item)] ??= <A>[]).add(item);
      }
      return Dictionary({
        for (final entry in buckets.entries) entry.key: down.run(entry.value),
      });
    },
    pour: (items) async {
      final buckets = <K, List<A>>{};
      await for (final item in items) {
        (buckets[key(item)] ??= <A>[]).add(item);
      }
      return Dictionary({
        for (final entry in buckets.entries) entry.key: down.run(entry.value),
      });
    },
  );
}

/// The namespace behind [Collector.associate].
class _Associate {
  const _Associate();

  /// A lookup table keyed by [key], holding the elements themselves.
  ///
  /// The last element to claim a key wins, which is what `group.into(key,
  /// .last())` says the long way.
  Collector<A, Dictionary<K, A>> by<A, K>(K Function(A item) key) => Collector(
    (items) => Dictionary({for (final item in items) key(item): item}),
    pour: (items) async {
      final table = <K, A>{};
      await for (final item in items) {
        table[key(item)] = item;
      }
      return Dictionary(table);
    },
  );
}
