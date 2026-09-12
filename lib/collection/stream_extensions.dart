/// # Stream Extensions (`StreamExtensions`)
///
/// Fluent, reactive operations and terminals on standard [Stream].
library;

import 'dart:async';

import 'streams.dart';

/// Fluent reactive operations on any [Stream].
extension StreamExtensions<T> on Stream<T> {
  /// Concurrently maps [worker] over stream events with at most [concurrency] in flight.
  Stream<R> parallelMap<R>(
    FutureOr<R> Function(T event) worker, {
    int concurrency = 4,
  }) {
    final controller = StreamController<R>();
    final active = <Future<void>>{};
    var isDone = false;
    StreamSubscription<T>? sub;

    void checkDone() {
      if (isDone && active.isEmpty && !controller.isClosed) {
        controller.close();
      }
    }

    controller.onListen = () {
      sub = listen(
        (event) {
          if (active.length >= concurrency) {
            sub?.pause();
          }
          late final Future<void> task;
          task = Future<void>(() async {
            try {
              final res = await worker(event);
              if (!controller.isClosed) controller.add(res);
            } catch (err, st) {
              if (!controller.isClosed) controller.addError(err, st);
            } finally {
              active.remove(task);
              if (active.length < concurrency && (sub?.isPaused ?? false)) {
                sub?.resume();
              }
              checkDone();
            }
          });
          active.add(task);
        },
        onError: controller.addError,
        onDone: () {
          isDone = true;
          checkDone();
        },
      );
    };

    controller.onCancel = () {
      return sub?.cancel();
    };

    return controller.stream;
  }

  /// Idiomatic alias for [where].
  Stream<T> filter(bool Function(T) test) => where(test);

  /// Maps events, silently discarding null results.
  Stream<R> mapNotNull<R>(R? Function(T) f) async* {
    await for (final event in this) {
      final res = f(event);
      if (res != null) yield res;
    }
  }

  /// Merges streams generated from each event.
  Stream<R> flatMap<R>(Stream<R> Function(T) f) async* {
    await for (final event in this) {
      yield* f(event);
    }
  }

  /// Emits only when the key extracted by [by] changes relative to the previous event.
  Stream<T> distinctBy([Object? Function(T)? by]) async* {
    var hasPrevious = false;
    Object? previousKey;
    await for (final event in this) {
      final key = by != null ? by(event) : event;
      if (!hasPrevious || key != previousKey) {
        hasPrevious = true;
        previousKey = key;
        yield event;
      }
    }
  }

  /// Emits an event only after [quiet] duration of silence.
  Stream<T> debounce(Duration quiet) {
    final controller = StreamController<T>();
    Timer? timer;
    T? lastEvent;
    var hasEvent = false;

    controller.onListen = () {
      final sub = listen(
        (event) {
          timer?.cancel();
          lastEvent = event;
          hasEvent = true;
          timer = Timer(quiet, () {
            if (hasEvent) {
              controller.add(lastEvent as T);
              hasEvent = false;
            }
          });
        },
        onError: controller.addError,
        onDone: () {
          if (hasEvent) {
            controller.add(lastEvent as T);
          }
          timer?.cancel();
          controller.close();
        },
      );
      controller.onCancel = () {
        timer?.cancel();
        return sub.cancel();
      };
    };
    return controller.stream;
  }

  /// Emits at most one event per [every] interval.
  Stream<T> throttle(Duration every) {
    final controller = StreamController<T>();
    var ready = true;
    Timer? timer;

    controller.onListen = () {
      final sub = listen(
        (event) {
          if (ready) {
            controller.add(event);
            ready = false;
            timer = Timer(every, () {
              ready = true;
            });
          }
        },
        onError: controller.addError,
        onDone: () {
          timer?.cancel();
          controller.close();
        },
      );
      controller.onCancel = () {
        timer?.cancel();
        return sub.cancel();
      };
    };
    return controller.stream;
  }

  /// Buffers events into lists of [size] or on [maxWait] timeout.
  Stream<List<T>> chunk(int size, {Duration? maxWait}) {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'must be positive');
    final controller = StreamController<List<T>>();
    var batch = <T>[];
    Timer? timer;

    void flush() {
      if (batch.isNotEmpty) {
        controller.add(batch);
        batch = <T>[];
      }
      timer?.cancel();
      timer = null;
    }

    controller.onListen = () {
      final sub = listen(
        (event) {
          batch.add(event);
          if (batch.length >= size) {
            flush();
          } else if (maxWait != null && timer == null) {
            timer = Timer(maxWait, flush);
          }
        },
        onError: controller.addError,
        onDone: () {
          flush();
          controller.close();
        },
      );
      controller.onCancel = () {
        timer?.cancel();
        return sub.cancel();
      };
    };
    return controller.stream;
  }

  /// Merges events concurrently from this and [other].
  Stream<T> mergeWith(Stream<T> other) => Streams.merge([this, other]);

  /// Plays this stream to completion, then plays [other].
  Stream<T> concatWith(Stream<T> other) => Streams.concat([this, other]);

  /// Pairs events at matching index from two streams.
  Stream<V> zipWith<R, V>(
    Stream<R> other, [
    V Function(T a, R b)? combiner,
  ]) => Streams.zip(
    this,
    other,
    combiner ?? ((a, b) => (a, b) as V),
  );

  /// Replaces stream errors with a fallback event returned by [fallback].
  Stream<T> recover(T Function(Object error) fallback) {
    final controller = StreamController<T>();
    controller.onListen = () {
      final sub = listen(
        controller.add,
        onError: (Object err) {
          try {
            controller.add(fallback(err));
          } catch (e, st) {
            controller.addError(e, st);
          }
        },
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    };
    return controller.stream;
  }

  /// Side-effect per event without modifying stream.
  Stream<T> tap(void Function(T) action) async* {
    await for (final event in this) {
      action(event);
      yield event;
    }
  }
}

/// Null-filtering on nullable streams.
extension NullableStreamExtensions<T extends Object> on Stream<T?> {
  /// Emits only non-null events.
  Stream<T> whereNotNull() async* {
    await for (final event in this) {
      if (event != null) yield event;
    }
  }

  /// Ergonomic getter alias for [whereNotNull].
  Stream<T> get nonNull => whereNotNull();
}

/// Fluent stream terminals.
extension StreamTerminals<T> on Stream<T> {
  /// Consumes the stream and counts matching events.
  Future<int> count([bool Function(T event)? predicate]) async {
    var n = 0;
    await for (final item in this) {
      if (predicate == null || predicate(item)) n++;
    }
    return n;
  }

  /// First event or null if stream is empty.
  Future<T?> get firstOrNull async {
    await for (final item in this) {
      return item;
    }
    return null;
  }

  /// Last event or null if stream is empty.
  Future<T?> get lastOrNull async {
    T? result;
    await for (final item in this) {
      result = item;
    }
    return result;
  }
}
