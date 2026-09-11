/// # Flows (`Flow<T>`)
///
/// The collection whose elements arrive over time, in place of Dart's
/// `Stream`.
///
/// The same two members [Sequence] has — [Flow.transform] takes a
/// [Transformer] and [Flow.collect] takes a [Collector] — so a script that
/// moves from a collected crawl to a streaming one keeps its vocabulary
/// instead of rewriting twenty-six operations into `asyncMap`, `takeWhile`
/// and `toList`.
library;

import 'dart:async';

import 'collector.dart';
import 'sequence.dart';
import 'transformer.dart';

// ============================================================================
// FLOWS (Flow<T>)
// ============================================================================

/// An ordered collection whose elements arrive over time.
///
/// ```dart
/// final spend = await io.csv.records('big.csv')
///     .transform(.where((r) => r['live'] == 'yes'))
///     .transform(.take.first(1000))
///     .collect(.count.by((r) => r['host']));
/// ```
///
/// ## The same two doors, and one word at the boundary
///
/// [transform] takes a [Transformer] and hands back another flow; [collect]
/// takes a [Collector] and hands back a `Future`. That `Future` is the *only*
/// difference in shape between this and a [Sequence] — every factory on both
/// operation types reaches a flow, and none of them needed a second spelling
/// to get here:
///
/// ```dart
/// // setup: final flow = Flow<Row>.empty(); bool live(Row r) => r.live;
/// final cleanup = Transformer.where<Row>(live);
/// flow.transform(cleanup);       // Flow<Row>
/// rows.transform(cleanup);       // Sequence<Row>
/// ```
///
/// [stream] is the way out, for the eight `Stream` members with no spelling
/// here — `handleError`, `timeout`, `asBroadcastStream` and the rest:
///
/// ```dart
/// // setup: final flow = Flow<Row>.empty();
/// final safe = flow.stream.handleError((e) => print('$e')).timeout(30.s).flow;
/// ```
///
/// Deliberately not pretty. It is one documented door, visible in review,
/// rather than a partial re-spelling of somebody else's API.
///
/// ## Lazy, the same way a sequence is
///
/// [transform] builds a pipeline and nothing runs until something collects —
/// and then only as much of the source as that collect asks for. Three
/// elements out of a `take.first(3)` behind a `where` costs five produced,
/// and `collect(.first())` costs one. Over a crawl that means the crawl
/// stops, because the terminal cancels its subscription and `net.crawl`'s
/// flow ends the engine when it is cancelled.
///
/// ## Consumed once, in one voice
///
/// A sequence walked twice walks its source twice. A flow cannot: a
/// subscription is not a walk. Dart has three answers to a second listen —
/// a `StateError` from a controller, a `FileSystemException` from a closed
/// file, and silence from `Stream.fromIterable`, which simply starts over —
/// and which one you get is not in the type.
///
/// So [transform], [collect] and [stream] each claim the source, and a second
/// claim throws one message for all three:
///
/// ```dart no-compile
/// StateError: This flow has already been consumed.
/// ```
///
/// Thrown when the second pipeline is *built*, not when it is listened to.
/// The whole cost of the guard is that [Flow.empty] cannot be `const`, where
/// `const Sequence([])` can.
///
/// Crossing between the two is one call each way, both already spelled:
///
/// ```dart
/// // setup: final flow = Flow<Row>.empty();
/// final Sequence<Row> held = await flow.collect(.seq());   // materialise
/// final Flow<Row> back = held.flow;                        // and back
/// ```
final class Flow<T> {
  Stream<T> _source;
  bool _claimed = false;

  /// Holds [source] as given, and does not listen to it.
  ///
  /// Reach for `stream.flow` at a call site; this is the form for when a
  /// getter reads badly.
  Flow(Stream<T> source) : _source = source;

  /// The flow that ends without emitting anything.
  ///
  /// Not `const`, because the consumed-once flag is mutable state and a class
  /// with one cannot be. That is the entire bill for the guard.
  Flow.empty() : _source = const Stream.empty();

  Stream<T> _claim() {
    if (_claimed) {
      throw StateError('This flow has already been consumed.');
    }
    _claimed = true;
    final source = _source;
    // Dropped so a flow that was shaped and thrown away does not hold its
    // source alive through a chain of dead pipeline objects.
    _source = const Stream.empty();
    return source;
  }

  /// This flow shaped by [step] — one [Transformer], applied lazily.
  ///
  /// ```dart
  /// // setup: final flow = Flow<Row>.empty();
  /// flow.transform(.where((r) => r.live)).transform(.take.first(10));
  /// ```
  ///
  /// Claims this flow: the one it hands back is the only one that can be
  /// consumed from here.
  Flow<R> transform<R>(Transformer<T, R> step) => Flow(step.pour(_claim()));

  /// This flow reduced by [step] — one [Collector], applied at the end.
  ///
  /// ```dart
  /// // setup: final flow = Flow<Row>.empty();
  /// await flow.collect(.count());
  /// await flow.collect(.group.by((r) => r.host));
  /// ```
  ///
  /// A `Future<R>` where [Sequence.collect] gives an `R`, which is the only
  /// difference between the two types. An error in the source comes out of
  /// this future; there is no `handleError` here, and [stream] is where a
  /// pipeline that needs one goes.
  Future<R> collect<R>(Collector<T, R> step) => step.pour(_claim());

  /// The stream underneath — the one word at the boundary.
  ///
  /// The twin of `Sequence.collect(.list())` and `Dictionary.map`: leaving is
  /// a call, and it says so. Claims this flow.
  Stream<T> get stream => _claim();

  @override
  String toString() => _claimed ? 'Flow<$T>(consumed)' : 'Flow<$T>';
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
/// `io.csv.pipe`, or `flow.run` for bounded work over items you do hold.
extension FlowedIterable<T> on Iterable<T> {
  /// These elements as a [Flow], walked only once the flow is collected.
  Flow<T> get flow => Flow<T>(Stream<T>.fromIterable(this));
}
