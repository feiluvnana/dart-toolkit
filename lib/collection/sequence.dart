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
/// | `for (final x in seq)` | `collect(.foreach(…))`, or a `for` over `collect(.list())` |
/// | `[...seq]`, `seq.toList()` | `collect(.list())` |
/// | passing to a `List<T>` or `Iterable<T>` parameter | `collect(.list())` |
/// | passing to this library's own APIs | nothing — they take a [Sequence] |
///
/// There is deliberately no `iterable` getter beside `collect(.list())`.
/// A getter that hands the `Iterable` back would put Dart's vocabulary one
/// dot away from every sequence in the library, which is the thing not
/// implementing `Iterable` was for; and it would hand out the recipe, so
/// an `iterable` getter would hand out the recipe, so `seq.iterable.length`
/// and `seq.iterable.first` would be two walks that read like two field
/// reads. Leaving is a call — `collect(.list())` — and it says so.
///
/// ## A view, not a snapshot
///
/// A sequence holds the [Iterable] it was given and nothing else. [transform]
/// does not call its [Transformer]; it hands back a sequence that will, so a
/// chain costs one small object per step and the work happens at the terminal
/// call — and only as much of it as that call asks for:
///
/// ```dart
/// final firstten = titles
///     .transform(.map(parse))
///     .transform(.where((t) => t.live))
///     .transform(.take.first(10));   // nothing walked yet
///
/// firstten.collect(.foreach(print)); // parses until ten have matched
/// ```
///
/// That is what laziness is for: `take.first(10)` over a large source no
/// longer shapes the whole source first.
///
/// What it costs is that a sequence is a recipe, not a result:
///
/// | | |
/// | :--- | :--- |
/// | two terminal calls | two walks, and every callback runs twice |
/// | a source that changes underneath | the change shows through |
/// | a single-subscription source | the second walk throws |
///
/// ```dart
/// var n = 0;
/// final s = [1, 2, 3].seq.transform(.where((x) { n++; return true; }));
/// s.collect(.count()); s.collect(.list()); s.collect(.first());
/// // n == 7 — three walks, and the last one stops at the first element
/// ```
///
/// Where a sequence is walked more than once and the walk is not free, spend
/// one `collect(.list())` and work from the list — `.seq` again if the
/// vocabulary is wanted on it.
///
/// It was a snapshot through 5.1.0: the constructor copied into a `List` and
/// every step copied again. That made the three calls above cost three walks
/// instead of seven, and it made every source pay for it — a `walk` of a tree
/// was materialised in full before a `where` could look at the first entry.
/// The double walk is the cheaper problem, and it is the one the caller can
/// see and fix.
final class Sequence<T> {
  final Iterable<T> _items;

  /// Holds [items] as given — not copied, and not walked.
  ///
  /// Reach for `items.seq` at a call site; this is the form for when a getter
  /// reads badly, and `const Sequence([])` is the empty one. There was a
  /// `Sequence.empty()` beside it through 5.2.0, for the single reason that
  /// this constructor could not be `const` while it copied into a `List`.
  /// Now that it can be, the two spellings are one value and Rule 5 keeps
  /// the shorter.
  const Sequence(this._items);

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
      Sequence(_Deferred(() => step.run(_items)));

  /// This sequence reduced by [step] — one [Collector], applied.
  ///
  /// ```dart
  /// rows.collect(.count());
  /// rows.collect(.max.by((r) => r.score));
  /// rows.collect(.group.by((r) => r.host));
  /// ```
  R collect<R>(Collector<T, R> step) => step.run(_items);

  /// The first four elements, which walks that far and no further.
  ///
  /// Its own vocabulary, down to the printing: [Collector.join]'s `limit`
  /// stops the walk at the fifth element and writes the `…` itself.
  @override
  String toString() => 'Sequence(${collect(.join(', ', limit: 4))})';
}

/// The iterable a [Sequence.transform] hands forward: it calls [_build] once
/// per walk, and never before the first one.
///
/// Without it a [Transformer] that does its work up front — `sort`, `unique`,
/// `take.last` — would do that work when the chain was written rather than
/// when it was walked, which is the one thing this class exists to prevent.
class _Deferred<T> extends Iterable<T> {
  const _Deferred(this._build);

  final Iterable<T> Function() _build;

  @override
  Iterator<T> get iterator => _build().iterator;
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
  /// This iterable as a [Sequence], wrapped rather than copied — so whatever
  /// is true of walking this iterable twice is true of the sequence.
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
  ///
  /// Two views over the one source, so walking both walks it twice. Where
  /// that is not free, `collect(.list())` first.
  (Sequence<A>, Sequence<B>) get unzip =>
      (Sequence(_items.map((p) => p.$1)), Sequence(_items.map((p) => p.$2)));
}
