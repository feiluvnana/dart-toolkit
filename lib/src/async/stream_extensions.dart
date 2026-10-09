part of '../async.dart';

/// Timing and de-duplication on any [Stream]. Each listener of a broadcast stream gets its own
/// state; an error from the source passes through, after what was held back before it; a
/// throwing callback is the stream's error. Timers read [Clock], so `Clock.fake()` drives them.
///
/// {@category Concurrency}
extension StreamOperators<T> on Stream<T> {
  /// Batches events into lists of [size], or of whatever arrived in each window of [every] (an
  /// empty window emits nothing); given both, a batch ends at whichever comes first. The last
  /// batch may be shorter.
  ///
  /// ```dart
  /// rows.chunk(size: 500);           // bulk inserts
  /// events.chunk(every: 1.s);        // one flush a second
  /// ```
  Stream<List<T>> chunk({int? size, Duration? every}) {
    if (size == null && every == null) throw ArgumentError('Invalid chunk: give size, every or both');
    if (size != null && size < 1) throw ArgumentError.value(size, 'size', 'Invalid size, expected at least 1');
    _checkSpan(every, 'every');
    return _lift((out) {
      var batch = <T>[];
      Timer? timer;
      void flush() {
        timer?.cancel();
        timer = null;
        if (batch.isEmpty) return;
        out.addSync(batch);
        batch = <T>[];
      }

      return _Op(
        data: (item) {
          batch.add(item);
          if (batch.length == size) return flush();
          if (every != null) timer ??= Timer(every, flush);
        },
        error: (error, trace) {
          flush();
          out.addErrorSync(error, trace);
        },
        done: () {
          flush();
          out.closeSync();
        },
        cancel: () => timer?.cancel(),
      );
    });
  }

  /// Each event only once [quiet] has passed with no newer one; the last is emitted at once
  /// when the source ends.
  Stream<T> debounce(Duration quiet) {
    _checkSpan(quiet, 'quiet');
    return _lift((out) {
      // One timer, re-armed for the remainder when it fires early, not one per event.
      Timer? timer;
      late T pending;
      var waiting = false;
      var last = Duration.zero;
      void fire() {
        final left = quiet - (Clock.current.elapsed - last);
        if (left > Duration.zero) {
          timer = Timer(left, fire);
          return;
        }
        timer = null;
        waiting = false;
        out.addSync(pending);
      }

      void flush() {
        timer?.cancel();
        timer = null;
        if (!waiting) return;
        waiting = false;
        out.addSync(pending);
      }

      return _Op(
        data: (item) {
          pending = item;
          waiting = true;
          last = Clock.current.elapsed;
          timer ??= Timer(quiet, fire);
        },
        error: (error, trace) {
          flush();
          out.addErrorSync(error, trace);
        },
        done: () {
          flush();
          out.closeSync();
        },
        cancel: () => timer?.cancel(),
      );
    });
  }

  /// At most one event per [window]: [leading] emits the one that opens a window, [trailing]
  /// the last other one seen in it. A trailing emission opens the next window, so no two events
  /// are closer than [window].
  Stream<T> throttle(Duration window, {bool leading = true, bool trailing = false}) {
    _checkSpan(window, 'window');
    if (!leading && !trailing) throw ArgumentError('Invalid throttle: neither leading nor trailing emits anything');
    return _lift((out) {
      Timer? timer;
      late T pending;
      var waiting = false;
      var ended = false;
      late void Function() windowEnds;
      windowEnds = () {
        timer = null;
        if (trailing && waiting) {
          waiting = false;
          out.addSync(pending);
          if (!ended) timer = Timer(window, windowEnds);
        }
        if (ended) out.closeSync();
      };

      return _Op(
        data: (item) {
          if (timer != null || !leading) {
            pending = item;
            waiting = true;
          } else {
            out.addSync(item);
          }
          timer ??= Timer(window, windowEnds);
        },
        error: (error, trace) {
          if (trailing && waiting) {
            waiting = false;
            out.addSync(pending);
          }
          out.addErrorSync(error, trace);
        },
        // An open window with a trailing event still emits it when it closes, not early.
        done: () {
          ended = true;
          if (trailing && waiting && timer != null) return;
          timer?.cancel();
          out.closeSync();
        },
        cancel: () => timer?.cancel(),
      );
    });
  }

  /// Each [key] once, keeping the first event that had it: `users.unique((u) => u.id)`.
  /// (`Stream.distinct` drops only repeats in a row.)
  Stream<T> unique(Object? Function(T event) key) => _lift((out) {
    final seen = <Object?>{};
    return _Op(
      data: (item) {
        if (seen.add(key(item))) out.addSync(item);
      },
      error: out.addErrorSync,
      done: out.closeSync,
    );
  });

  /// This stream through an operator [start] makes for each listener.
  Stream<R> _lift<R>(_Op<T> Function(MultiStreamController<R> out) start) => Stream<R>.multi((out) {
    final op = start(out);
    final subscription = listen(
      (item) {
        try {
          op.data(item);
        } catch (e, st) {
          out.addErrorSync(e, st);
        }
      },
      onError: (Object error, StackTrace trace) {
        try {
          op.error(error, trace);
        } catch (e, st) {
          out.addErrorSync(e, st);
        }
      },
      onDone: op.done,
    );
    out
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = () {
        op.cancel?.call();
        return subscription.cancel();
      };
  }, isBroadcast: isBroadcast);
}

/// What an operator does with each event, error and the end of its source.
final class _Op<T> {
  final void Function(T item) data;
  final void Function(Object error, StackTrace trace) error;
  final void Function() done;
  final void Function()? cancel;

  const _Op({required this.data, required this.error, required this.done, this.cancel});
}

void _checkSpan(Duration? span, String name) {
  if (span != null && span <= Duration.zero) {
    throw ArgumentError.value(span, name, 'Invalid $name, expected more than zero');
  }
}

/// Combining plain streams.
///
/// {@category Concurrency}
extension StreamsMerge<T> on Iterable<Stream<T>> {
  /// Every event of these streams as it comes, at most [concurrency] of them listened to at a
  /// time, each taken from this iterable when there is room. Errors pass through; a pause holds
  /// them all; a cancel cancels them all; it ends when all have.
  ///
  /// For streams that arrive as events, `stream.map(toStream).merge()`; for batches,
  /// `Batch.merge`; for items, `parallelize`.
  Stream<T> merge({int concurrency = 4}) {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Invalid concurrency, expected at least 1');
    }
    final sources = iterator;
    late final StreamController<T> out;
    final active = <StreamSubscription<T>>{};
    var exhausted = false;
    var paused = false;

    void fill() {
      while (!exhausted && active.length < concurrency) {
        if (!sources.moveNext()) {
          exhausted = true;
          break;
        }
        late final StreamSubscription<T> subscription;
        subscription = sources.current.listen(
          out.add,
          onError: out.addError,
          onDone: () {
            active.remove(subscription);
            fill();
          },
        );
        if (paused) subscription.pause();
        active.add(subscription);
      }
      if (exhausted && active.isEmpty && !out.isClosed) out.close();
    }

    out = StreamController<T>(
      onListen: fill,
      onPause: () {
        paused = true;
        for (final s in active) {
          s.pause();
        }
      },
      onResume: () {
        paused = false;
        for (final s in active) {
          s.resume();
        }
      },
      onCancel: () async {
        exhausted = true;
        final all = [...active];
        active.clear();
        await Future.wait([for (final s in all) s.cancel()]);
      },
    );
    return out.stream;
  }
}

/// Combining streams that arrive as events: `stream.map(toStream).merge()`.
///
/// {@category Concurrency}
extension StreamOfStreamsMerge<T> on Stream<Stream<T>> {
  /// Every event of the streams this one gives, as it comes, at most [concurrency] of them
  /// listened to at a time: this stream is held while that many run. Errors pass through; it
  /// ends when this stream and every stream it gave have.
  Stream<T> merge({int concurrency = 4}) {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Invalid concurrency, expected at least 1');
    }
    late final StreamController<T> out;
    StreamSubscription<Stream<T>>? sources;
    final active = <StreamSubscription<T>>{};
    var ended = false, full = false;

    void settle() {
      if (full && active.length < concurrency) {
        full = false;
        sources?.resume();
      }
      if (ended && active.isEmpty && !out.isClosed) out.close();
    }

    void start(Stream<T> source) {
      late final StreamSubscription<T> subscription;
      subscription = source.listen(
        out.add,
        onError: out.addError,
        onDone: () {
          active.remove(subscription);
          settle();
        },
      );
      if (out.isPaused) subscription.pause();
      active.add(subscription);
      if (active.length >= concurrency && !full) {
        full = true;
        sources?.pause();
      }
    }

    out = StreamController<T>(
      onListen: () => sources = listen(
        start,
        onError: out.addError,
        onDone: () {
          ended = true;
          settle();
        },
      ),
      onPause: () {
        sources?.pause();
        for (final s in active) {
          s.pause();
        }
      },
      onResume: () {
        sources?.resume();
        for (final s in active) {
          s.resume();
        }
      },
      onCancel: () async {
        final all = [...active];
        active.clear();
        await Future.wait([sources?.cancel() ?? Future<void>.value(), for (final s in all) s.cancel()]);
      },
    );
    return out.stream;
  }
}

/// Nullability filter on streams of nullable events.
///
/// {@category Concurrency}
extension StreamNonNulls<T extends Object> on Stream<T?> {
  /// This stream without its nulls, as `Iterable.nonNulls`.
  Stream<T> get nonNulls => where((event) => event != null).cast<T>();
}
