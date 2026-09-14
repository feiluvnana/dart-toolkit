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

  /// Emits an event only when its [key] differs from the one before it.
  ///
  /// The keyed form of `Stream.distinct`, which `dart:async` already has —
  /// the way [IterableExtensions.distinctBy] is to `distinct`.
  ///
  /// `filter`, `mapNotNull` and `flatMap` stood here through 8.1.0: second
  /// names for `where`, `map(…).nonNulls` and `asyncExpand`.
  Stream<T> distinctBy(Object? Function(T event) key) async* {
    var hasPrevious = false;
    Object? previousKey;
    await for (final event in this) {
      final current = key(event);
      if (!hasPrevious || current != previousKey) {
        hasPrevious = true;
        previousKey = current;
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
  ///
  /// Named for `Iterable.followedBy`, the same operation on the sync side. It
  /// was `concatWith` through 8.1.0.
  Stream<T> followedBy(Stream<T> other) => Streams.concat([this, other]);

  /// Pairs events at matching index from two streams.
  Stream<V> zipWith<R, V>(Stream<R> other, [V Function(T a, R b)? combiner]) =>
      Streams.zip(this, other, combiner ?? ((a, b) => (a, b) as V));

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
  /// The events that are not null.
  ///
  /// Spelled as `dart:core` spells it for `Iterable<T?>`, which has had
  /// `nonNulls` since 3.0. `Stream` does not, so this is the one that was
  /// missing — where 8.1.0 offered `whereNotNull()` *and* `nonNull`, two names
  /// for an operation the language had already named.
  Stream<T> get nonNulls => _nonNulls();

  Stream<T> _nonNulls() async* {
    await for (final event in this) {
      if (event != null) yield event;
    }
  }
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
