part of '../../async.dart';

/// Stream operators built on `dart:async`.
///
/// {@category Concurrency}
extension StreamExtensions<T> on Stream<T> {
  /// Batches items into lists of [size] (mirrors `Iterable.chunk`).
  ///
  /// The final batch is short if the stream does not divide evenly.
  Stream<List<T>> chunk(int size) async* {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'Must be positive');
    var batch = <T>[];
    await for (final item in this) {
      batch.add(item);
      if (batch.length == size) {
        yield batch;
        batch = <T>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  /// Batches items collected within each window of [duration].
  ///
  /// A window that collects nothing emits nothing.
  Stream<List<T>> chunkEvery(Duration duration) {
    var batch = <T>[];
    Timer? timer;
    return _lift<List<T>>(
      onData: (item, sink, _) {
        batch.add(item);
        timer ??= Timer(duration, () {
          timer = null;
          if (batch.isNotEmpty) {
            sink.add(batch);
            batch = <T>[];
          }
        });
      },
      onDone: (sink) {
        timer?.cancel();
        if (batch.isNotEmpty) sink.add(batch);
      },
      onCancel: () async => timer?.cancel(),
    );
  }

  /// Emits an item only after [duration] has passed with no newer item.
  Stream<T> debounce(Duration duration) {
    // One timer, re-armed for the remainder when it fires early, instead of a new timer per
    // item: a burst of a hundred thousand items costs one timer, not a hundred thousand.
    Timer? timer;
    T? pending;
    var hasPending = false;
    final clock = Stopwatch()..start();
    var last = 0;
    late EventSink<T> out;
    void fire() {
      final left = duration.inMicroseconds - (clock.elapsedMicroseconds - last);
      if (left > 0) {
        timer = Timer(Duration(microseconds: left), fire);
        return;
      }
      timer = null;
      hasPending = false;
      out.add(pending as T);
    }

    return _lift<T>(
      onData: (item, sink, _) {
        out = sink;
        pending = item;
        hasPending = true;
        last = clock.elapsedMicroseconds;
        timer ??= Timer(duration, fire);
      },
      onDone: (sink) {
        timer?.cancel();
        if (hasPending) sink.add(pending as T);
      },
      onCancel: () async => timer?.cancel(),
    );
  }

  /// Emits at most one item per [duration] window.
  ///
  /// [leading] emits the item that opens a window, [trailing] the last *other* item
  /// seen during it. An item alone in its window is emitted once either way. A trailing
  /// emission opens the next window, so two items are never closer than [duration].
  Stream<T> throttle(Duration duration, {bool leading = true, bool trailing = false}) {
    if (!leading && !trailing) throw ArgumentError('throttle needs leading, trailing or both; neither emits nothing');
    Timer? timer;
    T? pending;
    var hasPending = false;
    var ended = false;
    late EventSink<T> out;
    late void Function() settle;

    void windowEnds() {
      timer = null;
      if (trailing && hasPending) {
        hasPending = false;
        out.add(pending as T);
        if (!ended) timer = Timer(duration, windowEnds);
      }
      settle();
    }

    return _lift<T>(
      onData: (item, sink, settled) {
        (out, settle) = (sink, settled);
        if (timer != null || !leading) {
          pending = item;
          hasPending = true;
        } else {
          sink.add(item);
        }
        timer ??= Timer(duration, windowEnds);
      },
      // An open window with a trailing item still emits it when it closes, not early.
      onDone: (_) {
        ended = true;
        if (!(trailing && hasPending)) timer?.cancel();
      },
      onError: (error, trace, sink, _) {
        if (trailing && hasPending) {
          hasPending = false;
          timer?.cancel();
          timer = null;
          sink.add(pending as T);
        }
        sink.addError(error, trace);
      },
      pending: () => trailing && hasPending,
      onCancel: () async => timer?.cancel(),
    );
  }

  /// Shifts the emission of every item forward by [duration].
  Stream<T> delayBy(Duration duration) {
    // The delay is the same for every item, so they come due in arrival order: a queue and
    // one timer on its head, rather than a timer per item.
    final queue = Queue<(int, T)>();
    final clock = Stopwatch()..start();
    Timer? timer;
    late EventSink<T> out;
    late void Function() settle;
    void due() {
      timer = null;
      final now = clock.elapsedMicroseconds;
      while (queue.isNotEmpty && queue.first.$1 <= now) {
        out.add(queue.removeFirst().$2);
      }
      if (queue.isNotEmpty) timer = Timer(Duration(microseconds: queue.first.$1 - now), due);
      settle();
    }

    return _lift<T>(
      onData: (item, sink, settled) {
        (out, settle) = (sink, settled);
        queue.add((clock.elapsedMicroseconds + duration.inMicroseconds, item));
        timer ??= Timer(duration, due);
      },
      onDone: (_) {},
      pending: () => queue.isNotEmpty,
      onCancel: () async => timer?.cancel(),
    );
  }

  /// Maps each item to a stream and merges the results concurrently.
  ///
  /// Inner streams run at the same time; use `asyncExpand` for one at a time. A paused
  /// consumer pauses them all, not only the outer stream.
  Stream<R> flatMap<R>(Stream<R> Function(T item) mapper) {
    final inner = <StreamSubscription<R>>{};
    return _lift<R>(
      onData: (item, sink, settled) {
        late final StreamSubscription<R> sub;
        sub = mapper(item).listen(
          sink.add,
          onError: sink.addError,
          onDone: () {
            inner.remove(sub);
            settled();
          },
        );
        inner.add(sub);
      },
      onDone: (_) {},
      pending: () => inner.isNotEmpty,
      onCancel: () => Future.wait(inner.map((s) => s.cancel())),
      onPause: () {
        for (final sub in inner) {
          sub.pause();
        }
      },
      onResume: () {
        for (final sub in inner) {
          sub.resume();
        }
      },
    );
  }

  /// Shared plumbing for the operators above: forwards events through a controller,
  /// honours pause and resume, and stays open past the source's `done` for as long
  /// as [pending] reports outstanding work — which is what stops [delayBy] and
  /// [flatMap] from dropping their last events.
  Stream<R> _lift<R>({
    required void Function(T item, EventSink<R> sink, void Function() settled) onData,
    required void Function(EventSink<R> sink) onDone,
    bool Function()? pending,
    Future<void> Function()? onCancel,
    void Function()? onPause,
    void Function()? onResume,
    void Function(Object error, StackTrace trace, EventSink<R> sink, void Function() settled)? onError,
  }) {
    late final StreamController<R> controller;
    StreamSubscription<T>? subscription;
    var sourceDone = false;

    void closeIfIdle() {
      if (sourceDone && !(pending?.call() ?? false) && !controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<R>(
      onListen: () {
        subscription = listen(
          (item) {
            // What an operator's callback throws — a `flatMap` mapper — is the stream's error,
            // not the zone's.
            try {
              onData(item, controller.sink, closeIfIdle);
            } catch (error, trace) {
              controller.addError(error, trace);
            }
            closeIfIdle();
          },
          onError: (Object error, StackTrace trace) {
            if (onError != null) {
              try {
                onError(error, trace, controller.sink, closeIfIdle);
              } catch (e, st) {
                controller.addError(e, st);
              }
            } else {
              controller.addError(error, trace);
            }
            closeIfIdle();
          },
          onDone: () {
            sourceDone = true;
            onDone(controller.sink);
            closeIfIdle();
          },
        );
      },
      onPause: () {
        subscription?.pause();
        onPause?.call();
      },
      onResume: () {
        subscription?.resume();
        onResume?.call();
      },
      onCancel: () async {
        await onCancel?.call();
        await subscription?.cancel();
        subscription = null;
      },
    );

    return controller.stream;
  }
}

/// Combining several streams.
///
/// {@category Concurrency}
extension IterableStreamExtensions<T> on Iterable<Stream<T>> {
  /// One stream of every item from all of these, as they arrive; done when all are done.
  ///
  /// Unlike `yield*` after `yield*`, the sources run at the same time. Errors pass through
  /// and the stream continues. Cancelling cancels every source.
  Stream<T> merge() => Stream<Stream<T>>.fromIterable(this).flatMap((s) => s);
}

/// Nullability filter on streams of nullable items.
///
/// {@category Concurrency}
extension StreamNullableExtensions<T extends Object> on Stream<T?> {
  /// This stream without its nulls (mirrors `Iterable.nonNulls`).
  Stream<T> get nonNulls => where((item) => item != null).cast<T>();
}
