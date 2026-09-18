import 'dart:async';

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
    );
  }

  /// Emits an item only after [duration] has passed with no newer item.
  Stream<T> debounce(Duration duration) {
    Timer? timer;
    T? pending;
    var hasPending = false;
    return _lift<T>(
      onData: (item, sink, _) {
        pending = item;
        hasPending = true;
        timer?.cancel();
        timer = Timer(duration, () {
          timer = null;
          hasPending = false;
          sink.add(pending as T);
        });
      },
      onDone: (sink) {
        timer?.cancel();
        if (hasPending) sink.add(pending as T);
      },
    );
  }

  /// Emits at most one item per [duration] window.
  ///
  /// [leading] emits the item that opens a window, [trailing] the last *other* item
  /// seen during it. An item alone in its window is emitted once either way.
  Stream<T> throttle(Duration duration, {bool leading = true, bool trailing = false}) {
    if (!leading && !trailing) throw ArgumentError('throttle needs leading, trailing or both; neither emits nothing');
    Timer? timer;
    T? pending;
    var hasPending = false;
    return _lift<T>(
      onData: (item, sink, _) {
        if (timer != null) {
          pending = item;
          hasPending = true;
          return;
        }
        if (leading) {
          sink.add(item);
        } else {
          pending = item;
          hasPending = true;
        }
        timer = Timer(duration, () {
          timer = null;
          if (trailing && hasPending) {
            sink.add(pending as T);
            hasPending = false;
          }
        });
      },
      onDone: (sink) {
        timer?.cancel();
        if (trailing && hasPending) sink.add(pending as T);
      },
    );
  }

  /// Shifts the emission of every item forward by [duration].
  Stream<T> delayBy(Duration duration) {
    final timers = <Timer>{};
    return _lift<T>(
      onData: (item, sink, settled) {
        late final Timer timer;
        timer = Timer(duration, () {
          timers.remove(timer);
          sink.add(item);
          settled();
        });
        timers.add(timer);
      },
      onDone: (_) {},
      pending: () => timers.isNotEmpty,
    );
  }

  /// Maps each item to a stream and merges the results concurrently.
  ///
  /// Inner streams run at the same time; use `asyncExpand` for one at a time.
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
            onData(item, controller.sink, closeIfIdle);
            closeIfIdle();
          },
          onError: controller.addError,
          onDone: () {
            sourceDone = true;
            onDone(controller.sink);
            closeIfIdle();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
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
