/// # Sequences (`Sequence<T>`)
///
/// The ordered collection this library returns, in place of Dart's.
///
/// Two members shape it — [Sequence.transform] takes a [Transformer] and
/// [Sequence.collect] takes a [Collector] — and the vocabulary itself lives in
/// those two namespaces rather than on this class. That is what lets every
/// operation take its ordinary name back: `map`, `where`, `take.first`,
/// `group.by`, `max.by`, `count.by`, none of which could be a member here.
///
/// [Sequence] deliberately does **not** implement `Iterable`, so there is
/// exactly one vocabulary in scope at any call site — see the class doc for
/// the reasoning and the cost.
library;

import 'collector.dart';
import 'transformer.dart';

// ============================================================================
// SEQUENCES (Sequence<T>)
// ============================================================================

/// An ordered collection, carrying this library's vocabulary.
///
/// ```dart
/// final rows = await net.crawl<Row>(seed).collect();
///
/// rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)))
///     .pairs
///     .transform(.sort.by((e) => e.$1))
///     .collect(.foreach(print));
/// ```
///
/// ## Two members, and a namespace behind each
///
/// [transform] takes an operation that gives another sequence back;
/// [collect] takes one that gives a single value. Both read the name out of
/// the context type, so the dot form is the one to write:
///
/// ```dart
/// rows.transform(.where((r) => r.live)).collect(.count());
/// ```
///
/// The explicit spelling means the same thing and is what a named pipeline
/// uses: `rows.transform(Transformer.take.first(10))`.
///
/// This was fifty-eight methods through 5.0.0, a third of them words invented
/// for an operation everybody already knew — `to` for `map`, `keep` for
/// `where`, `sift` for `mapNotNull`, `best` for `maxBy`, `tally` for
/// `countBy`. Most of those existed because Rule 4 forbids camelCase and a
/// flat namespace left the second word nowhere to go. A namespace gives it
/// somewhere: `take.when`, `first.where`, `count.by`, `flat.map`.
///
/// ## Why this is not an `Iterable`
///
/// An extension member never overrides an instance member, so extending
/// `Iterable` could only *add* names beside Dart's — two spellings for one
/// operation, which Rule 5 forbids. Replacing the vocabulary therefore means
/// replacing the static type: if the receiver is not an `Iterable`,
/// `Iterable`'s members are not in scope.
///
/// What that costs, and what replaces it:
///
/// | Lost | Replacement |
/// | :--- | :--- |
/// | `for (final x in seq)` | `collect(.foreach(…))` |
/// | `[...seq]`, `seq.toList()` | [list] |
/// | passing to a `List<T>` parameter | [list] |
/// | passing to this library's own APIs | nothing — they take a [Sequence] |
///
/// ## A snapshot, not a view
///
/// Every step is eager: a sequence holds a `List<T>` taken when it was built,
/// and each [transform] builds the next one. So a callback runs exactly once
/// per element per step, whatever you do with the result afterwards, and
/// nothing underneath can change while you hold it.
///
/// It was a lazy view through 4.0.0, wrapping an `Iterable` and re-walking the
/// whole chain on every terminal call:
///
/// ```dart
/// var n = 0;
/// final s = [1, 2, 3].seq.transform(.where((x) { n++; return true; }));
/// s.collect(.count()); s.list; s.collect(.first());
/// // n == 7 through 4.0.0, and 3 now
/// ```
///
/// Three terminal calls, three walks — and a `.map(expensiveParse)` over a
/// crawl's results paid for the parse once per call. Worse, a sequence built
/// over a single-subscription source was a `StateError` waiting for its second
/// reader. Nothing in this vocabulary was lazy on purpose; every source the
/// library hands one is already a materialised list, and the copy per step is
/// the trade every caller assumed they were getting.
///
/// The cost is real and small: `take.first(10)` over a large source shapes the
/// whole source first. Where that matters the answer is a `Stream` —
/// `crawl.stream` rather than `crawl.collect` — which is the same advice as
/// before.
final class Sequence<T> {
  final List<T> _items;

  /// Holds [items], copied now.
  ///
  /// Reach for `items.seq` at a call site; this is the form for when a getter
  /// reads badly.
  Sequence(Iterable<T> items) : _items = List<T>.of(items);

  /// The empty sequence, as a `const`.
  ///
  /// The one case worth a second constructor: an empty result is returned from
  /// enough places that allocating for it is silly, and `const Sequence([])`
  /// stopped compiling when the field became a `List` the constructor copies.
  const Sequence.empty() : _items = const [];

  /// This sequence shaped by [step] — one [Transformer], applied.
  ///
  /// ```dart
  /// rows.transform(.where((r) => r.live));
  /// rows.transform(.sort.by((r) => r.cost)).transform(.take.first(10));
  /// ```
  ///
  /// A chain of three pays for `transform` three times, which is the price of
  /// having every operation spelled the way everybody else spells it. Where a
  /// chain is written more than once, name it instead: `Transformer.then`
  /// joins the steps into one value and this takes that.
  Sequence<R> transform<R>(Transformer<T, R> step) =>
      Sequence(step.run(_items));

  /// This sequence reduced by [step] — one [Collector], applied.
  ///
  /// ```dart
  /// rows.collect(.count());
  /// rows.collect(.max.by((r) => r.score));
  /// rows.collect(.group.by((r) => r.host));
  /// ```
  R collect<R>(Collector<T, R> step) => step.run(_items);

  /// The elements as a list — a real snapshot, and the hand-off to anything
  /// typed `List<T>` or `Iterable<T>`.
  ///
  /// The one word at the boundary. `collect(.list())` says the same thing and
  /// exists for where there is no receiver to say it on — a downstream
  /// collector — but at a call site this is the spelling.
  List<T> get list => _items.toList();

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
  /// This iterable as a [Sequence], copied now.
  Sequence<T> get seq => Sequence<T>(this);
}

/// The member that only makes sense on a sequence of nullables.
extension NullableSequence<T extends Object> on Sequence<T?> {
  /// The non-null elements — Kotlin's `filterNotNull`.
  ///
  /// `Transformer.map.nonnull` is the same word for mapping and dropping in
  /// one step; this is the argument-free half, and lowercase compound as
  /// `perhost` and `httponly` are.
  Sequence<T> get nonnull => Sequence(_items.whereType<T>());
}

/// Splitting a sequence of pairs back into two.
extension PairedSequence<A, B> on Sequence<(A, B)> {
  /// The first and second halves of every pair, as two sequences.
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
