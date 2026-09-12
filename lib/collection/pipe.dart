/// # Pipes and Pours (`Pipe<A, B>`, `Pour<A, R>`)
///
/// The two operation types that shape a [Flow], as values.
///
/// [Flow.transform] takes a [Pipe] and [Flow.collect] takes a [Pour], exactly
/// as [Sequence.transform] takes a [Transformer] and [Sequence.collect] takes
/// a [Collector]. Four types where there were two, and **no call site
/// changed**: the dot shorthand resolves a name against the context type, so
/// `.where(live)` reads the same on either container and picks the factory
/// that fits.
///
/// The word `pour` is this library's for *the same operation over a stream*.
/// It was a member on the two sequence-side types through 5.4.0 — the
/// optional streaming half of one operation — and it is a type now, which is
/// the same idea said properly.
library;

import 'dart:async';

import '../src/bounded.dart';
import 'collector.dart';
import 'transformer.dart';

// ============================================================================
// PIPES (Pipe<A, B>)
// ============================================================================

/// An operation that turns a flow of [A] into a flow of [B].
///
/// ```dart
/// // setup: final flow = Stream<Row>.empty(); Future<Row> price(Row r) async => r;
/// flow.through(.where((r) => r.live))
///     .through(.map.async(price, size: 8))
///     .through(.take.first(10));
/// ```
///
/// ## What a flow can do that a sequence cannot
///
/// Everything here streams — there is no synchronous fallback to quietly
/// buffer into, which is what the optional `pour` on [Transformer] used to
/// be. And the vocabulary can now hold the operations that only make sense
/// over time, none of which had a spelling through 5.4.0:
///
/// | | |
/// | :--- | :--- |
/// | [map]`.async(f, size: n)` | was `flow.run(f, size: n)`, an extension off in `concurrent` |
/// | [where]`.async(t, size: n)` | nothing |
/// | [flat]`.async(f)` | `asyncExpand` |
/// | [chunk]`.time(d)` | nothing |
/// | [debounce], [throttle] | nothing |
/// | [timeout], [handle], [merge], [tap] | `flow.stream.…(…).flow` |
///
/// [Flow.stream] stays the door, and it now carries only what is genuinely
/// foreign — `listen`, `pipe`, `drain`, `asBroadcastStream` — rather than
/// five operations the vocabulary simply could not express.
///
/// ## What a flow cannot do
///
/// [sort], [flip], `take.last` and `skip.last` are not here. No element of a
/// sorted result is known before the last element of the source, which on a
/// flow is a real constraint rather than a bookkeeping one, so they are
/// [Pour]s — terminals, handing back a [Sequence], which says honestly that
/// the answer cannot exist until the source ends. On a [Sequence] they are
/// [Transformer]s, because there the same law only ever meant *this reads the
/// whole source*.
///
/// ## The operand of a binary operation is a flow
///
/// [zip], [plus], [minus], [common] and [or] take a [Flow] here and a
/// [Sequence] on [Transformer]. Two flows could not be zipped at all through
/// 5.4.0 — the one operation type had one signature, and it named a
/// `Sequence` — so zipping two files line by line had no spelling and
/// [Flow.stream] did not have one either.
///
/// A flow is consumed once, so an operand is too: a pipe holding one is a
/// single-use value, and applying it twice throws the way a second
/// [Flow.transform] does.
class Pipe<A, B> {
  /// Creates a pipe that applies [run] to the stream underneath.
  ///
  /// The generative constructor a subclass calls. Reach for [fn] at a call
  /// site; this is the form for when a subclass needs a `super` call.
  const Pipe(this.run);

  /// This operation, as the plain function it is.
  ///
  /// ```dart
  /// // setup: final src = Stream.fromIterable(const [1, 2]);
  /// Pipe.map<int, String>((n) => '$n').run(src);   // Stream<String>
  /// ```
  ///
  /// A field rather than a method, for the reason [Transformer.run] is one:
  /// [cast] and `where.type` are `Pipe<Never, B>`, and a method parameter
  /// would reify as `Stream<Never>` and reject every stream handed to it.
  final Stream<B> Function(Stream<A> items) run;

  /// A [Transformer] as a pipe — the one-way adapter across the split.
  ///
  /// For a named pipeline that genuinely serves both containers, and for a
  /// transformer somebody else wrote:
  ///
  /// ```dart
  /// // setup: bool live(Row r) => r.live; final flow = Stream<Row>.empty();
  /// final cleanup = Transformer.where<Row>(live);
  /// rows.transform(cleanup);
  /// flow.through(Pipe.of(cleanup));
  /// ```
  ///
  /// **It holds the whole source**, because a [Transformer] takes an
  /// `Iterable` and there is no way to hand it one without having all of it.
  /// That is the trade 5.4.0 made silently for every transformer that
  /// supplied no `pour`; here it is a call somebody wrote and a reviewer can
  /// see. Where the operation has a streaming form, spell it as a pipe
  /// instead — most of them are the same seven characters.
  static Pipe<A, B> of<A, B>(Transformer<A, B> step) =>
      Pipe((items) => _buffered(items, step));

  static Stream<B> _buffered<A, B>(
    Stream<Object?> items,
    Transformer<A, B> step,
  ) async* {
    yield* Stream<B>.fromIterable(step.run(await items.cast<A>().toList()));
  }

  // --------------------------------------------------------------------------
  // Composing
  // --------------------------------------------------------------------------

  /// This pipe followed by [next] — a pipeline as one value.
  Pipe<A, C> then<C>(Pipe<B, C> next) => Pipe((items) => next.run(run(items)));

  /// This pipe with an ending, which makes it a [Pour].
  ///
  /// ```dart
  /// final hosts = Pipe.map<Row, String>((r) => r.host).into(Pour.list());
  /// ```
  Pour<A, R> into<R>(Pour<B, R> end) => Pour((items) => end.run(run(items)));

  // --------------------------------------------------------------------------
  // Shaping
  // --------------------------------------------------------------------------

  /// Each element replaced by [each] of it — Kotlin's `map`.
  ///
  /// Callable, and a namespace: `map.nonnull` drops what came back `null`,
  /// and `map.async` awaits, at most [size] at a time.
  ///
  /// ```dart
  /// // setup: final flow = Stream<Row>.empty();
  /// // setup: Future<Row> price(Row r) async => r;
  /// flow.through(.map((r) => r.name));
  /// flow.through(.map.async(price, size: 8));
  /// ```
  static const map = _Map();

  /// Each element replaced by [each] of it, dropping nulls.
  static Pipe<A, B> mapNotNull<A, B extends Object>(
          B? Function(A item) each) =>
      map.nonnull(each);

  /// The elements [test] accepts — Kotlin's `filter`, Dart's word.
  ///
  /// Callable, and a namespace: `where.type<R>()` keeps only the elements
  /// that are an [R], and `where.async` takes a test that awaits.
  static const where = _Where();

  /// Only the elements that are an [R] — Kotlin's `filterIsInstance`.
  static Pipe<Never, R> whereType<R>() => where.type<R>();

  /// Flattens, or expands each element into many.
  ///
  /// `flat()` concatenates elements that are themselves sequences,
  /// `flat.map(each)` turns each element into a sequence first, and
  /// `flat.async(each)` takes one that gives a [Flow] back — Dart's
  /// `asyncExpand`, in this vocabulary.
  ///
  /// ```dart
  /// // setup: final pages = Stream<Iterable<Row>>.empty();
  /// pages.through(.flat());
  /// ```
  static const flat = _Flat();

  /// Each element expanded into many by [each], and the lot concatenated.
  static Pipe<A, B> flatMap<A, B>(Iterable<B> Function(A item) each) =>
      flat.map(each);

  /// The elements with duplicates removed, keeping the first of each.
  ///
  /// Holds one key per distinct element for the life of the flow, which is
  /// the memory a `distinct` over an unbounded source costs.
  static const unique = _Unique();

  /// The elements, keeping the first of each distinct [key].
  static Pipe<A, A> uniqueBy<A, K>(K Function(A item) key) =>
      unique.by(key);

  /// The leading elements, by count or by test.
  ///
  /// `take.first(n)` and `take.when(test)`. The trailing elements are
  /// `Pour.take.last(n)`, on the other type because they cannot be known
  /// before the source ends.
  static const take = _Take();

  /// The leading elements [test] accepts, stopping at the first it does not.
  static Pipe<A, A> takeWhile<A>(bool Function(A item) test) =>
      take.when(test);

  /// Everything but the leading elements, by count or by test.
  static const skip = _Skip();

  /// Everything from the first element [test] rejects onwards.
  static Pipe<A, A> skipWhile<A>(bool Function(A item) test) =>
      skip.when(test);

  /// Each element paired with its position — Python's word.
  static Pipe<A, (int, A)> enumerate<A>() => Pipe((items) {
    var next = 0;
    return items.map((item) => (next++, item));
  });

  /// The elements in consecutive groups, by count or by clock.
  ///
  /// `chunk(n)` closes a batch every [n] elements; `chunk.time(d)` closes one
  /// every [d], which is what a flow that trickles needs and a sequence
  /// cannot mean. Both hand back a [Sequence] per batch, and the last one is
  /// whatever was left when the source ended.
  ///
  /// ```dart
  /// // setup: final flow = Stream<Row>.empty(); Future<void> send(List<Row> b) async {}
  /// await flow.through(.chunk(100)).collect(.foreach(send));
  /// await flow.through(.chunk.time(5.s)).collect(.foreach(send));
  /// ```
  static const chunk = _Chunk();

  /// The elements paired elementwise with [other], stopping at the shorter.
  static Pipe<A, (A, R)> zip<A, R>(Stream<R> other) =>
      Pipe((items) => _zipped(items, other));

  static Stream<(A, R)> _zipped<A, R>(Stream<A> items, Stream<R> other) async* {
    final right = StreamIterator<R>(other);
    try {
      await for (final left in items) {
        if (!await right.moveNext()) return;
        yield (left, right.current);
      }
    } finally {
      await right.cancel();
    }
  }

  /// The elements followed by [other]'s.
  static Pipe<A, A> plus<A>(Stream<A> other) => Pipe((items) async* {
    yield* items;
    yield* other;
  });

  /// The elements [other] does not hold.
  ///
  /// [other] is read in full before the first element passes, because that is
  /// what *does not hold* needs to know.
  static Pipe<A, A> minus<A>(Stream<A> other) => Pipe((items) async* {
    final drop = await other.toSet();
    yield* items.where((item) => !drop.contains(item));
  });

  /// The elements [other] also holds, duplicates removed.
  static Pipe<A, A> common<A>(Stream<A> other) => Pipe((items) async* {
    final keep = await other.toSet();
    final seen = <A>{};
    yield* items.where((item) => keep.contains(item) && seen.add(item));
  });

  /// The elements, or [fallback]'s when there are none — Kotlin's `ifEmpty`.
  static Pipe<A, A> or<A>(Stream<A> fallback) => Pipe((items) async* {
    var any = false;
    await for (final item in items) {
      any = true;
      yield item;
    }
    if (!any) yield* fallback;
  });

  /// The elements as [R]s, throwing on one that is not.
  static Pipe<Never, R> cast<R>() =>
      Pipe<Never, R>((Stream<Object?> items) => items.cast<R>());

  /// The elements that are still the newest after [quiet] of silence.
  ///
  /// A burst collapses to its last element: each arrival restarts the clock,
  /// and only when nothing has come for [quiet] is that element let through.
  /// What a search box does, and what a file watcher does — `io.watch`'s
  /// `settle` is this idea hand-rolled, from before there was a word for it.
  ///
  /// The element held when the source ends is emitted rather than dropped.
  static Pipe<A, A> debounce<A>(Duration quiet) =>
      Pipe((items) => _debounced(items, quiet));

  static Stream<A> _debounced<A>(Stream<A> items, Duration quiet) {
    late StreamController<A> out;
    late StreamSubscription<A> input;
    Timer? timer;
    var held = false;
    late A latest;

    void release() {
      timer = null;
      if (!held) return;
      held = false;
      out.add(latest);
    }

    out = StreamController<A>(
      onListen: () {
        input = items.listen(
          (item) {
            latest = item;
            held = true;
            timer?.cancel();
            timer = Timer(quiet, release);
          },
          onError: out.addError,
          onDone: () {
            timer?.cancel();
            release();
            out.close();
          },
        );
      },
      onPause: () => input.pause(),
      onResume: () => input.resume(),
      onCancel: () {
        timer?.cancel();
        return input.cancel();
      },
    );
    return out.stream;
  }

  /// At most one element per [every], the first of each window.
  ///
  /// The leading edge: an element arriving while the window is open is
  /// dropped rather than delayed, which is what rate-limiting a firehose
  /// means. [debounce] is the other shape — it keeps the *last* of a burst.
  static Pipe<A, A> throttle<A>(Duration every) => Pipe((items) async* {
    DateTime? opened;
    await for (final item in items) {
      final now = DateTime.now();
      if (opened != null && now.difference(opened) < every) continue;
      opened = now;
      yield item;
    }
  });

  /// The elements, failing when [gap] passes with none.
  ///
  /// A [TimeoutException] comes out of the terminal, the way any other source
  /// error does. `flow.stream.timeout(d).flow` said this through 5.4.0.
  static Pipe<A, A> timeout<A>(Duration gap) =>
      Pipe((items) => items.timeout(gap));

  /// The elements, with [onError] called on a failure instead of it throwing.
  ///
  /// The flow continues. Without this an error in the source comes out of
  /// [Flow.collect], which is right by default and wrong for a long-running
  /// pipeline where one bad element should not end the run.
  static Pipe<A, A> handle<A>(
    void Function(Object error, StackTrace stack) onError,
  ) => Pipe((items) => items.handleError(onError));

  /// These elements and [other]'s, interleaved as they arrive.
  ///
  /// Ends when both have. Neither waits for the other, which is the whole
  /// point: two crawls, two watched directories, a source and its heartbeat.
  static Pipe<A, A> merge<A>(Stream<A> other) =>
      Pipe((items) => _merged(items, other));

  static Stream<A> _merged<A>(Stream<A> items, Stream<A> other) {
    final out = StreamController<A>();
    var open = 2;
    void ended() {
      if (--open == 0) out.close();
    }

    final left = items.listen(out.add, onError: out.addError, onDone: ended);
    final right = other.listen(
      out.add,
      onError: out.addError,
      onDone: ended,
    );
    out.onCancel = () async {
      await left.cancel();
      await right.cancel();
    };
    return out.stream;
  }

  /// Every element passed to [each] and then let through unchanged.
  ///
  /// The one for a `print` in the middle of a pipeline, or a counter. A
  /// [map] that returns its input says the same thing and reads like it meant
  /// to change something.
  static Pipe<A, A> tap<A>(void Function(A item) each) => Pipe(
    (items) => items.map((item) {
      each(item);
      return item;
    }),
  );

  /// An arbitrary streaming transformation.
  ///
  /// The door in a closed set, and it takes a stream because a pipe has
  /// nothing else to give it:
  ///
  /// ```dart
  /// // setup: final flow = Stream<int>.empty();
  /// flow.through(.fn((xs) => xs.map((n) => n * 2)));
  /// ```
  ///
  /// For an operation with options, one used in six pipelines, or one worth a
  /// test of its own, subclass instead — which is why this class is not
  /// `final`.
  static Pipe<A, B> fn<A, B>(Stream<B> Function(Stream<A> items) run) =>
      Pipe(run);

  @override
  String toString() => 'Pipe<$A, $B>';
}

// ============================================================================
// POURS (Pour<A, R>)
// ============================================================================

/// An operation that turns a flow of [A] into a single [R].
///
/// ```dart
/// // setup: final flow = Stream<Row>.empty();
/// await flow.collect(.count());
/// await flow.collect(.group.into((r) => r.host, .sum((r) => r.cost)));
/// ```
///
/// The [Collector] of the streaming side, with the same names, the same
/// nullable contract — [first], [last], [single], [at], [max] and [min] hand
/// back `null` rather than throwing — and two differences that come from the
/// container:
///
/// - **[foreach] awaits.** It takes a `FutureOr<void>` callback and waits for
///   each one before the next. [Collector.foreach] cannot, and a
///   `Future`-returning closure passed to it was assignable, started and
///   never awaited: the commonest silent mistake in a streaming script, since
///   `foreach` is the natural terminal and the docs send you to `io.async`
///   inside it.
/// - **[sort], [flip], [take] and [skip] live here**, handing back a
///   [Sequence]. On a [Sequence] they are [Transformer]s; see [Pipe].
class Pour<A, R> {
  /// Creates a pour that applies [run] to the stream underneath.
  const Pour(this.run);

  /// This operation, as the plain function it is.
  ///
  /// ```dart
  /// // setup: final src = Stream.fromIterable(const [1, 2, 3]);
  /// await Pour.count<int>().run(src);    // 3
  /// ```
  final Future<R> Function(Stream<A> items) run;

  /// A [Collector] as a pour — the one-way adapter, and it holds the source.
  ///
  /// See [Pipe.of], which makes the same trade for the same reason.
  static Pour<A, R> of<A, R>(Collector<A, R> step) => Pour(
    (Stream<Object?> items) async => step.run(await items.cast<A>().toList()),
  );

  // --------------------------------------------------------------------------
  // Composing
  // --------------------------------------------------------------------------

  /// This pour's result, finished with [end] — Java's `collectingAndThen`.
  ///
  /// For a named pour, not for inline chaining, exactly as
  /// [Collector.then] is.
  Pour<A, R2> then<R2>(R2 Function(R result) end) =>
      Pour((items) async => end(await run(items)));

  // --------------------------------------------------------------------------
  // Counting and asking
  // --------------------------------------------------------------------------

  /// How many elements there are.
  ///
  /// Callable, and a namespace: `count.where(test)` and `count.by(key)`.
  static const count = _Count();

  /// How many elements fall under each [key].
  static Pour<A, Map<K, int>> countBy<A, K>(K Function(A item) key) =>
      count.by(key);

  /// Whether the flow holds nothing.
  static Pour<A, bool> empty<A>() => Pour((items) => items.isEmpty);

  /// Whether [value] is one of the elements.
  static Pour<A, bool> has<A>(A value) =>
      Pour((items) => items.contains(value));

  /// Whether [test] accepts at least one element.
  static Pour<A, bool> any<A>(bool Function(A item) test) =>
      Pour((items) => items.any(test));

  /// Whether [test] accepts every element — vacuously true when empty.
  static Pour<A, bool> all<A>(bool Function(A item) test) =>
      Pour((items) => items.every(test));

  // --------------------------------------------------------------------------
  // Picking one
  // --------------------------------------------------------------------------

  /// The first element, or `null` when there is none.
  ///
  /// Cancels the subscription as soon as it has one, which over a crawl stops
  /// the crawl: one page fetched, not all of them.
  static const first = _First();

  /// The first element [test] accepts, or `null`.
  static Pour<A, A?> firstWhere<A>(bool Function(A item) test) =>
      first.where(test);

  /// The last element, or `null` when there is none.
  static const last = _Last();

  /// The last element [test] accepts, or `null`.
  static Pour<A, A?> lastWhere<A>(bool Function(A item) test) =>
      last.where(test);

  /// The only element, or `null` when there is not exactly one.
  static const single = _Single();

  /// The only element [test] accepts, or `null` when it is not exactly one.
  static Pour<A, A?> singleWhere<A>(bool Function(A item) test) =>
      single.where(test);

  /// The element at [index], or `null` when the flow is shorter.
  static Pour<A, A?> at<A>(int index) => Pour((items) async {
    if (index < 0) return null;
    var i = 0;
    await for (final item in items) {
      if (i++ == index) return item;
    }
    return null;
  });

  /// Where an element is — `index.of(value)` and `index.where(test)`.
  static const index = _Index();

  /// The position of the first element equal to [value], or `null`.
  static Pour<A, int?> indexOf<A>(A value) => index.of(value);

  /// The position of the first element [test] accepts, or `null`.
  static Pour<A, int?> indexWhere<A>(bool Function(A item) test) =>
      index.where(test);

  /// The element with the largest `max.by(key)`, or `null` when empty.
  static const max = _Max();

  /// The element with the largest [key], or `null` when empty.
  static Pour<A, A?> maxBy<A>(Comparable<Object?> Function(A item) key) =>
      max.by(key);

  /// The element with the smallest `min.by(key)`, or `null` when empty.
  static const min = _Min();

  /// The element with the smallest [key], or `null` when empty.
  static Pour<A, A?> minBy<A>(Comparable<Object?> Function(A item) key) =>
      min.by(key);

  // --------------------------------------------------------------------------
  // Reducing
  // --------------------------------------------------------------------------

  /// [each] applied across the flow, starting from [initial].
  ///
  /// [R] comes from [initial] rather than from a lambda's return, so a dot
  /// shorthand needs a context type — the same note [Collector.fold] carries.
  static Pour<A, R> fold<A, R>(R initial, R Function(R total, A item) each) =>
      Pour((items) async {
        var total = initial;
        await for (final item in items) {
          total = each(total, item);
        }
        return total;
      });

  /// The total of [of] across the flow; `0` when empty.
  static Pour<A, num> sum<A>(num Function(A item) of) => Pour((items) async {
    num total = 0;
    await for (final item in items) {
      total += of(item);
    }
    return total;
  });

  /// The mean of [of] across the flow, or `null` when empty.
  static Pour<A, double?> avg<A>(num Function(A item) of) =>
      Pour((items) async {
        num total = 0;
        var seen = 0;
        await for (final item in items) {
          total += of(item);
          seen++;
        }
        return seen == 0 ? null : total / seen;
      });

  /// The elements as text, joined by [separator]. See [Collector.join].
  static Pour<A, String> join<A>(
    String separator, {
    String prefix = '',
    String suffix = '',
    int? limit,
    String Function(A item)? of,
  }) => Pour((items) async {
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
  });

  // --------------------------------------------------------------------------
  // Reordering, which needs the end
  // --------------------------------------------------------------------------

  /// The elements in ascending order, as a [Sequence].
  ///
  /// `sort()`, `sort.by(key)` and `sort.using(compare)`, as on
  /// [Transformer.sort] — and a terminal here rather than a [Pipe], because
  /// no element of a sorted result is known before the last element of the
  /// source has arrived. **`sort` is not a pipe** is the whole of it.
  static const sort = _Sort();

  /// The elements back to front, as a [List].
  static Pour<A, List<A>> flip<A>() =>
      Pour((items) async => (await items.toList()).reversed.toList());

  /// The trailing elements — `take.last(n)`.
  static const take = _Take2();

  /// Everything but the trailing elements — `skip.last(n)`.
  static const skip = _Skip2();

  // --------------------------------------------------------------------------
  // Splitting into the other collection
  // --------------------------------------------------------------------------

  /// The elements bucketed into a [Map]. See [Collector.group].
  ///
  /// `group.into` takes a [Collector] downstream, not another pour: a bucket
  /// is in memory by the time it is reduced, so it is a sequence-side
  /// operation and `group.into(f, .count())` infers exactly as it does there.
  static const group = _Group();

  /// The elements bucketed into a [Map].
  static Pour<A, Map<K, List<A>>> groupBy<A, K>(K Function(A item) key) =>
      group.by(key);

  /// A lookup table keyed by `associate.by(key)` — Kotlin's `associateBy`.
  static const associate = _Associate();

  /// A lookup table keyed by [key].
  static Pour<A, Map<K, A>> associateBy<A, K>(K Function(A item) key) =>
      associate.by(key);

  /// A flow of `(key, value)` records as a [Map].
  static Pour<(K, V), Map<K, V>> dict<K, V>() => Pour(
    (pairs) async => {for (final (k, v) in await pairs.toList()) k: v},
  );

  /// The elements [test] accepts and the elements it rejects.
  static Pour<A, (List<A>, List<A>)> split<A>(
    bool Function(A item) test,
  ) => Pour((items) async {
    final yes = <A>[];
    final no = <A>[];
    await for (final item in items) {
      (test(item) ? yes : no).add(item);
    }
    return (yes, no);
  });

  // --------------------------------------------------------------------------
  // Leaving
  // --------------------------------------------------------------------------

  /// Calls [each] on every element, **awaiting it** before the next.
  ///
  /// The async terminal the vocabulary did not have. [Collector.foreach]
  /// takes a `void Function(A)`, and Dart assigns a `Future`-returning
  /// closure to that type without a word — so this, through 5.4.0, started
  /// every write and awaited none:
  ///
  /// ```dart no-compile
  /// await flow.collect(.foreach((n) async {
  ///   await io.async.write('out/$n.txt', 'x');   // never awaited
  /// }));
  /// ```
  ///
  /// One at a time, in order. For [each] calls that should overlap, the
  /// bound goes on the work rather than on the terminal:
  /// `pipe(.map.async(each, size: 8)).collect(.foreach((_) {}))`.
  static Pour<A, void> foreach<A>(FutureOr<void> Function(A item) each) =>
      Pour((items) async {
        await for (final item in items) {
          await each(item);
        }
      });

  /// Standard Dart alias for [foreach].
  static Pour<A, void> forEach<A>(FutureOr<void> Function(A item) each) =>
      foreach(each);

  /// The elements as a list — the subscription, and the result of it.
  static Pour<A, List<A>> list<A>() =>
      Pour((items) async => List<A>.of(await items.toList()));

  /// The distinct elements as a set.
  static Pour<A, Set<A>> set<A>() =>
      Pour((items) async => Set<A>.of(await items.toSet()));

  /// The elements as a [List] — the way from the flow to the collection.
  ///
  /// The crossing `.flow` makes the other way.
  static Pour<A, List<A>> seq<A>() =>
      Pour((items) async => await items.toList());

  /// An arbitrary streaming reduction, for anything the named ones miss.
  static Pour<A, R> fn<A, R>(Future<R> Function(Stream<A> items) run) =>
      Pour(run);

  @override
  String toString() => 'Pour<$A, $R>';
}

// ============================================================================
// THE PIPE NAMESPACES
// ============================================================================

/// The namespace behind [Pipe.map].
class _Map {
  const _Map();

  /// Each element replaced by [each] of it.
  Pipe<A, B> call<A, B>(B Function(A item) each) =>
      Pipe((items) => items.map(each));

  /// Each element replaced by [each] of it, dropping the nulls.
  Pipe<A, B> nonnull<A, B extends Object>(B? Function(A item) each) => Pipe(
    (items) => items.map(each).where((value) => value != null).cast<B>(),
  );

  /// Each element through [each], at most [size] awaiting at a time.
  ///
  /// The capability that had no place in the vocabulary through 5.4.0: an
  /// operation whose element step is asynchronous has no `Iterable` form, so
  /// it could not be a `Transformer` and lived as `flow.run(worker, size: n)`
  /// — an extension in `concurrent`, reached past the two members a flow was
  /// documented to have.
  ///
  /// ```dart
  /// // setup: Future<String> fetch(String u) async => u; void save(String s) {}
  /// await system.console.reader.lines
  ///     .through(.map((line) => line.trim()))
  ///     .through(.where((line) => line.isNotEmpty))
  ///     .through(.map.async(fetch, size: 4))
  ///     .collect(.foreach(save));
  /// ```
  ///
  /// `size: 1` is `Stream.asyncMap`. [ordered] `true` — the default — yields
  /// in the order the elements arrived however the work finishes, which is
  /// what `concurrent.run` already means by *results come back in the order
  /// of items*; `false` yields in completion order.
  ///
  /// The first worker to throw propagates out of the terminal and no further
  /// element is started. `Pool.settle` is where collect-and-continue lives.
  Pipe<A, B> async<A, B>(
    FutureOr<B> Function(A item) each, {
    int size = 1,
    bool ordered = true,
  }) {
    final limit = size > 0 ? size : 1;
    return Pipe(
      (items) =>
          ordered ? inorder(items, each, limit) : asdone(items, each, limit),
    );
  }
}

/// The namespace behind [Pipe.where].
class _Where {
  const _Where();

  /// The elements [test] accepts.
  Pipe<A, A> call<A>(bool Function(A item) test) =>
      Pipe((items) => items.where(test));

  /// Only the elements that are a [R] — Kotlin's `filterIsInstance`.
  Pipe<Never, R> type<R>() => Pipe<Never, R>(
    (Stream<Object?> items) => items.where((item) => item is R).cast<R>(),
  );

  /// The elements [test] accepts, where the test awaits.
  ///
  /// At most [size] tests run at once; the elements keep their order however
  /// the tests finish, because a filter that reordered its input would be a
  /// different operation.
  Pipe<A, A> async<A>(FutureOr<bool> Function(A item) test, {int size = 1}) {
    final limit = size > 0 ? size : 1;
    return Pipe(
      (items) => inorder<A, (A, bool)>(
        items,
        (item) async => (item, await test(item)),
        limit,
      ).where((pair) => pair.$2).map((pair) => pair.$1),
    );
  }
}

/// The namespace behind [Pipe.flat].
class _Flat {
  const _Flat();

  /// The elements concatenated, each of them an [Iterable].
  Pipe<Iterable<B>, B> call<B>() =>
      Pipe((items) => items.expand((item) => item));

  /// Each element expanded into many by [each], and the lot concatenated.
  Pipe<A, B> map<A, B>(Iterable<B> Function(A item) each) =>
      Pipe((items) => items.expand(each));

  /// Each element expanded into a [Stream] by [each], and the lot concatenated.
  ///
  /// Dart's `asyncExpand`, in this vocabulary: one page of a paginated API
  /// per element, one file's lines per path.
  Pipe<A, B> async<A, B>(Stream<B> Function(A item) each) =>
      Pipe((items) => items.asyncExpand(each));
}

/// The namespace behind [Pipe.unique].
class _Unique {
  const _Unique();

  /// The elements, duplicates removed.
  Pipe<A, A> call<A>() => by<A, A>((item) => item);

  /// The elements, keeping the first of each distinct [key].
  Pipe<A, A> by<A, K>(K Function(A item) key) => Pipe((items) {
    final seen = <K>{};
    return items.where((item) => seen.add(key(item)));
  });
}

/// The namespace behind [Pipe.take].
class _Take {
  const _Take();

  /// The leading [n] elements, or all of them when there are fewer.
  Pipe<A, A> first<A>(int n) => Pipe((items) => items.take(n < 0 ? 0 : n));

  /// The leading elements [test] accepts, stopping at the first it does not.
  Pipe<A, A> when<A>(bool Function(A item) test) =>
      Pipe((items) => items.takeWhile(test));
}

/// The namespace behind [Pipe.skip].
class _Skip {
  const _Skip();

  /// Everything but the leading [n] elements — Kotlin's `drop`.
  Pipe<A, A> first<A>(int n) => Pipe((items) => items.skip(n < 0 ? 0 : n));

  /// Everything from the first element [test] rejects onwards.
  Pipe<A, A> when<A>(bool Function(A item) test) =>
      Pipe((items) => items.skipWhile(test));
}

/// The namespace behind [Pipe.chunk].
class _Chunk {
  const _Chunk();

  /// The elements in consecutive groups of [size], the last one short.
  ///
  /// Throws [ArgumentError] on a [size] below one, the way
  /// [Transformer.chunk] does — it yielded nothing through 5.4.0.
  Pipe<A, List<A>> call<A>(int size) {
    if (size < 1) {
      throw ArgumentError.value(size, 'size', 'must be at least 1');
    }
    return Pipe((items) => _counted(items, size));
  }

  static Stream<List<A>> _counted<A>(Stream<A> items, int size) async* {
    var batch = <A>[];
    await for (final item in items) {
      batch.add(item);
      if (batch.length == size) {
        yield batch;
        batch = <A>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// Whatever has arrived, every [every] — the batch a clock closes.
  ///
  /// For a source that trickles, where `chunk(100)` would hold ninety-nine
  /// rows for an hour waiting for the hundredth. An empty window emits
  /// nothing, so an idle source is silent rather than a stream of empty
  /// batches, and whatever is held when the source ends is emitted.
  Pipe<A, List<A>> time<A>(Duration every) =>
      Pipe((items) => _timed(items, every));

  static Stream<List<A>> _timed<A>(Stream<A> items, Duration every) {
    late StreamController<List<A>> out;
    late StreamSubscription<A> input;
    Timer? clock;
    var batch = <A>[];

    void close() {
      if (batch.isEmpty) return;
      out.add(batch);
      batch = <A>[];
    }

    out = StreamController<List<A>>(
      onListen: () {
        clock = Timer.periodic(every, (_) => close());
        input = items.listen(
          // A closure, not `batch.add`: the tear-off would bind the list
          // that is current now, and `close` swaps in a new one.
          (item) => batch.add(item),
          onError: out.addError,
          onDone: () {
            clock?.cancel();
            close();
            out.close();
          },
        );
      },
      onPause: () => input.pause(),
      onResume: () => input.resume(),
      onCancel: () {
        clock?.cancel();
        return input.cancel();
      },
    );
    return out.stream;
  }
}

// ============================================================================
// THE POUR NAMESPACES
// ============================================================================

/// The namespace behind [Pour.count].
class _Count {
  const _Count();

  /// How many elements there are.
  Pour<A, int> call<A>() => Pour((items) => items.length);

  /// How many elements [test] accepts.
  Pour<A, int> where<A>(bool Function(A item) test) =>
      Pour((items) => items.where(test).length);

  /// How many elements fall under each [key] — Kotlin's `countBy`.
  Pour<A, Map<K, int>> by<A, K>(K Function(A item) key) =>
      const _Group().into(key, Collector.count<A>());
}

/// The namespace behind [Pour.first].
class _First {
  const _First();

  /// The first element, or `null` when there is none.
  Pour<A, A?> call<A>() => where((_) => true);

  /// The first element [test] accepts, or `null`.
  Pour<A, A?> where<A>(bool Function(A item) test) => Pour((items) async {
    await for (final item in items) {
      if (test(item)) return item;
    }
    return null;
  });
}

/// The namespace behind [Pour.last].
class _Last {
  const _Last();

  /// The last element, or `null` when there is none.
  Pour<A, A?> call<A>() => where((_) => true);

  /// The last element [test] accepts, or `null`.
  Pour<A, A?> where<A>(bool Function(A item) test) => Pour((items) async {
    A? found;
    await for (final item in items) {
      if (test(item)) found = item;
    }
    return found;
  });
}

/// The namespace behind [Pour.single].
class _Single {
  const _Single();

  /// The only element, or `null` when there is not exactly one.
  Pour<A, A?> call<A>() => where((_) => true);

  /// The only element [test] accepts, or `null` when it is not exactly one.
  Pour<A, A?> where<A>(bool Function(A item) test) => Pour((items) async {
    A? found;
    var seen = 0;
    await for (final item in items) {
      if (!test(item)) continue;
      if (++seen > 1) return null;
      found = item;
    }
    return seen == 1 ? found : null;
  });
}

/// The namespace behind [Pour.index].
class _Index {
  const _Index();

  /// The position of the first element equal to [value], or `null`.
  Pour<A, int?> of<A>(A value) => where((item) => item == value);

  /// The position of the first element [test] accepts, or `null`.
  Pour<A, int?> where<A>(bool Function(A item) test) => Pour((items) async {
    var i = 0;
    await for (final item in items) {
      if (test(item)) return i;
      i++;
    }
    return null;
  });
}

/// The namespace behind [Pour.max].
class _Max {
  const _Max();

  /// The element with the largest [key], or `null` when empty.
  Pour<A, A?> by<A>(Comparable<Object?> Function(A item) key) =>
      Pour((items) => _extreme(items, key, 1));
}

/// The namespace behind [Pour.min].
class _Min {
  const _Min();

  /// The element with the smallest [key], or `null` when empty.
  Pour<A, A?> by<A>(Comparable<Object?> Function(A item) key) =>
      Pour((items) => _extreme(items, key, -1));
}

Future<A?> _extreme<A>(
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

/// The namespace behind [Pour.sort].
class _Sort {
  const _Sort();

  /// The elements in ascending order, which needs them [Comparable].
  Pour<A, List<A>> call<A>() =>
      using((a, b) => (a as Comparable<Object?>).compareTo(b));

  /// The elements in ascending order of [key].
  Pour<A, List<A>> by<A>(Comparable<Object?> Function(A item) key) =>
      using((a, b) => key(a).compareTo(key(b)));

  /// The elements ordered by [compare] — Kotlin's `sortedWith`.
  Pour<A, List<A>> using<A>(int Function(A a, A b) compare) => Pour(
    (items) async => await items.toList()..sort(compare),
  );
}

/// The namespace behind [Pour.take].
class _Take2 {
  const _Take2();

  /// The trailing [n] elements, or all of them when there are fewer.
  Pour<A, List<A>> last<A>(int n) => Pour((items) async {
    if (n <= 0) return const [];
    final all = await items.toList();
    return all.length <= n ? all : all.sublist(all.length - n);
  });
}

/// The namespace behind [Pour.skip].
class _Skip2 {
  const _Skip2();

  /// Everything but the trailing [n] elements — Kotlin's `dropLast`.
  Pour<A, List<A>> last<A>(int n) => Pour((items) async {
    final all = await items.toList();
    if (n <= 0) return all;
    return all.length <= n ? const [] : all.sublist(0, all.length - n);
  });
}

/// The namespace behind [Pour.group].
class _Group {
  const _Group();

  /// The elements bucketed by [key], every bucket a [List].
  Pour<A, Map<K, List<A>>> by<A, K>(K Function(A item) key) =>
      into(key, Collector<A, List<A>>((items) => items.toList()));

  /// The elements bucketed by [key], every bucket reduced by [down].
  ///
  /// One pass, and [down] is a [Collector]: by the time a bucket is reduced
  /// it is a list in memory, so the sequence-side vocabulary is the right one
  /// and `group.into(f, .count())` infers exactly as it does there.
  Pour<A, Map<K, R>> into<A, K, R>(
    K Function(A item) key,
    Collector<A, R> down,
  ) => Pour((items) async {
    final buckets = <K, List<A>>{};
    await for (final item in items) {
      (buckets[key(item)] ??= <A>[]).add(item);
    }
    return {
      for (final entry in buckets.entries) entry.key: down.run(entry.value),
    };
  });
}

/// The namespace behind [Pour.associate].
class _Associate {
  const _Associate();

  /// A lookup table keyed by [key], holding the elements themselves.
  Pour<A, Map<K, A>> by<A, K>(K Function(A item) key) =>
      Pour((items) async {
        final table = <K, A>{};
        await for (final item in items) {
          table[key(item)] = item;
        }
        return table;
      });
}
