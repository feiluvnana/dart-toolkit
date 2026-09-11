/// # Flows (`Flow<T>`)
///
/// The collection whose elements arrive over time, in place of Dart's
/// `Stream`.
///
/// Two members, spelled exactly as [Sequence]'s are: [Flow.transform] shapes
/// and [Flow.collect] finishes. So a script that moves from a collected crawl
/// to a streaming one keeps its vocabulary instead of rewriting twenty-six
/// operations into `asyncMap`, `takeWhile` and `toList` — and keeps its
/// receiver too.
library;

import 'dart:async';

import 'pipe.dart';
import 'sequence.dart';

// ============================================================================
// FLOWS (Flow<T>)
// ============================================================================

/// An ordered collection whose elements arrive over time.
///
/// ```dart
/// final spend = await io.async.csv.records('big.csv')
///     .transform(.where((r) => r['live'] == 'yes'))
///     .transform(.take.first(1000))
///     .collect(.count.by((r) => r['host']));
/// ```
///
/// ## Two doors, spelled the same on all three containers
///
/// [transform] takes a [Pipe] and hands back another flow; [collect] takes a
/// [Pour] and hands back a `Future`. A sequence's two doors are
/// [Sequence.transform] and [Sequence.collect], taking a [Transformer] and a
/// [Collector]. **One rule for a reader: shape with `transform`, finish with
/// `collect`, on a sequence, a dictionary or a flow.**
///
/// **Four operation types, two member names.** The operations keep their own
/// names on both sides — `.where(live)` is `.where(live)` wherever you write
/// it, because a dot shorthand resolves against the context type — and now
/// the receiver does too. What tells you which container you are on is the
/// `await`, which is more reliable than a member name because you cannot
/// leave it out:
///
/// ```dart
/// // setup: final flow = Flow<Row>.empty();
/// rows.transform(.where((r) => r.live));       // Sequence in, Sequence out
/// flow.transform(.where((r) => r.live));       // Flow in, Flow out
/// rows.collect(.count());                      // int
/// await flow.collect(.count());                // Future<int>
/// ```
///
/// They were `pipe` and `pour` in 5.5.0, when splitting the vocabulary into
/// four operation types briefly took the member names with it. The types
/// were the point and they survive — a flow-native operation could not join
/// the old single vocabulary at all, and an operation a flow could not
/// stream dragged the *sequence* side with it, so `sort` changed container
/// for no reason. The rename was the part that was not needed: a rename
/// forced by a spelling is not a rename. See the [Pipe] class doc for the
/// whole ledger, and [Transformer] for what it cost.
///
/// [stream] is still the way out, for what is genuinely foreign — `listen`,
/// `pipe`, `drain`, `asBroadcastStream`:
///
/// ```dart
/// // setup: final flow = Flow<Row>.empty(); void use(Row r) {}
/// final subscription = flow.stream.listen(use);
/// ```
///
/// Deliberately not pretty. It is one documented door, visible in review,
/// rather than a partial re-spelling of somebody else's API — and it carries
/// four members now rather than eight, because `handleError`, `timeout` and
/// the rest have a spelling here.
///
/// ## Lazy, the same way a sequence is
///
/// [transform] builds a pipeline and nothing runs until something collects —
/// and then only as much of the source as that terminal asks for. Three
/// elements out of a `take.first(3)` behind a `where` costs five produced,
/// and `collect(.first())` costs one. Over a crawl that means the crawl
/// stops, because the terminal cancels its subscription and `net.crawl`'s
/// flow ends the engine when it is cancelled.
///
/// ## Consumed once, unless it can be rebuilt
///
/// A sequence walked twice walks its source twice. A flow cannot: a
/// subscription is not a walk. Dart has three answers to a second listen —
/// a `StateError` from a controller, a `FileSystemException` from a closed
/// file, and silence from `Stream.fromIterable`, which simply starts over —
/// and which one you get is not in the type.
///
/// So [transform], [collect] and [stream] each claim the source, and a
/// second claim throws one message for all three:
///
/// ```dart no-compile
/// StateError: This flow has already been consumed.
/// ```
///
/// Thrown when the second pipeline is *built*, not when it is listened to.
///
/// [Flow.of] is the exception, and it is what makes the `io` mirror honest:
/// a source that can be **re-derived** — a directory walk, a file's lines, a
/// CSV — is built fresh on each claim and can be consumed as many times as a
/// [Sequence] can be walked. `io.async.dir.walk(d)` is one of those, so it
/// now matches `io.dir.walk(d)` rather than throwing on the second terminal.
/// A shaping step carries the property forward, because a pipeline over a
/// re-derivable source is re-derivable too.
///
/// ## Crossing to a sequence, and why there is no `Flow.seq`
///
/// One call each way, and only one of them is a getter:
///
/// ```dart
/// // setup: final flow = Flow<Row>.empty();
/// final Sequence<Row> held = await flow.collect(.seq());   // materialise
/// final Flow<Row> back = held.flow;                        // and back
/// ```
///
/// [Sequence.flow] is a getter because holding a collection and describing it
/// as arriving over time costs nothing. The other direction costs waiting for
/// all of it, and the `await` is what says so. A `flow.seq` getter would hide
/// exactly that, which is why the asymmetry is deliberate rather than an
/// omission.
final class Flow<T> {
  /// Holds [source] as given, and does not listen to it.
  ///
  /// Reach for `stream.flow` at a call site; this is the form for when a
  /// getter reads badly. The flow is consumed once — see [Flow.of] for the
  /// source that can be rebuilt.
  Flow(Stream<T> source) : _source = source, _build = null;

  /// A flow that rebuilds its source every time it is consumed.
  ///
  /// For a source that can honestly be read again — a file, a directory
  /// listing, a query. [build] is called once per [transform], [collect] or
  /// [stream],
  /// so two terminals read the disk twice, which is exactly what walking a
  /// [Sequence] twice already does:
  ///
  /// ```dart
  /// final walk = Flow.of(() => Stream.fromIterable(const [1, 2, 3]));
  /// await walk.collect(.count());   // 3
  /// await walk.collect(.list());    // [1, 2, 3] — and no StateError
  /// ```
  ///
  /// Everything true of a sequence walked twice is true here: every callback
  /// in the pipeline runs again, and a source that changed underneath shows
  /// the change. Where that is not free, `collect(.seq())` once and work from
  /// the sequence.
  Flow.of(Stream<T> Function() build) : _source = null, _build = build;

  /// The flow that ends without emitting anything.
  ///
  /// Not `const`, because the consumed-once flag is mutable state and a class
  /// with one cannot be. That is the entire bill for the guard.
  Flow.empty() : _source = const Stream.empty(), _build = null;

  Stream<T>? _source;
  final Stream<T> Function()? _build;
  bool _claimed = false;

  Stream<T> _claim() {
    final build = _build;
    if (build != null) return build();
    if (_claimed) {
      throw StateError('This flow has already been consumed.');
    }
    _claimed = true;
    final source = _source!;
    // Dropped so a flow that was shaped and thrown away does not hold its
    // source alive through a chain of dead pipeline objects.
    _source = const Stream.empty();
    return source;
  }

  /// This flow shaped by [step] — one [Pipe], applied lazily.
  ///
  /// ```dart
  /// // setup: final flow = Flow<Row>.empty();
  /// flow.transform(.where((r) => r.live)).transform(.take.first(10));
  /// ```
  ///
  /// [Sequence.transform] is the same door on the other container. The names
  /// differ because the operation types do: this one takes a [Pipe] and that
  /// one a [Transformer], and a member that said `transform` on both read as
  /// though one value would fit either — which, through 5.4.0, is exactly
  /// what the library claimed and could not deliver.
  ///
  /// Claims this flow: the one it hands back is the only one that can be
  /// consumed from here — unless this flow came from [Flow.of], in which case
  /// the one it hands back is re-derivable too.
  Flow<R> transform<R>(Pipe<T, R> step) {
    final build = _build;
    if (build != null) return Flow<R>.of(() => step.run(build()));
    return Flow<R>(step.run(_claim()));
  }

  /// This flow reduced by [step] — one [Pour], applied at the end.
  ///
  /// ```dart
  /// // setup: final flow = Flow<Row>.empty();
  /// await flow.collect(.count());
  /// await flow.collect(.group.by((r) => r.host));
  /// ```
  ///
  /// A `Future<R>` where [Sequence.collect] gives an `R`. An error in the
  /// source comes out of this future; `Pipe.handle` is where a pipeline that
  /// would rather carry on puts its answer.
  Future<R> collect<R>(Pour<T, R> step) => step.run(_claim());

  /// The stream underneath — the one word at the boundary.
  ///
  /// The twin of `Sequence.collect(.list())` and `Dictionary.map`: leaving is
  /// a call, and it says so. Claims this flow.
  Stream<T> get stream => _claim();

  @override
  String toString() => switch ((_build != null, _claimed)) {
    (true, _) => 'Flow<$T>(rebuildable)',
    (false, true) => 'Flow<$T>(consumed)',
    (false, false) => 'Flow<$T>',
  };
}

// ============================================================================
// THE WAY IN
// ============================================================================

/// Turns any stream into a [Flow].
///
/// The seam: a `dart:io` stream, an HTTP body or another package's stream
/// becomes shapeable with one word, and it is the way back from [Flow.stream]
/// after a member this library does not spell.
extension Flowed<T> on Stream<T> {
  /// This stream as a [Flow], wrapped rather than listened to.
  Flow<T> get flow => Flow<T>(this);
}

/// Turns any iterable into a [Flow].
///
/// For feeding something already in memory to an API that takes a flow —
/// `io.async.csv.write`, or `map.async` for bounded work over items you do
/// hold.
extension FlowedIterable<T> on Iterable<T> {
  /// These elements as a [Flow], walked only once the flow is collected.
  ///
  /// Re-derivable, because an iterable can be walked again: two terminals
  /// walk it twice rather than the second throwing.
  Flow<T> get flow => Flow<T>.of(() => Stream<T>.fromIterable(this));
}

/// The member that only makes sense on a flow of nullables.
extension NullableFlow<T extends Object> on Flow<T?> {
  /// The non-null elements — Kotlin's `filterNotNull`.
  ///
  /// The twin of `Sequence.nonnull`, which a flow simply did not have
  /// through 5.4.0: asking for it was an `undefined_getter`.
  Flow<T> get nonnull => transform(Pipe.where.type<T>());
}
