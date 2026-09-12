/// # Streams (`Streams`)
///
/// Periodic flows, event generation, combining, merging, and concurrency racing over [Stream].
library;

import 'dart:async';

/// Static utility functions for creating and combining [Stream]s.
abstract final class Streams {
  /// Emits values at regular intervals.
  static Stream<T> periodic<T>(
    Duration period, [
    T Function(int computationCount)? computation,
  ]) => Stream.periodic(period, computation);

  /// Generates a stream by repeatedly invoking an async generator until it returns null.
  static Stream<T> generate<T>(FutureOr<T?> Function() generator) async* {
    while (true) {
      final value = await generator();
      if (value == null) break;
      yield value;
    }
  }

  /// Plays streams sequentially to completion.
  static Stream<T> concat<T>(Iterable<Stream<T>> streams) async* {
    for (final stream in streams) {
      yield* stream;
    }
  }

  /// Merges multiple streams concurrently into a single stream.
  static Stream<T> merge<T>(Iterable<Stream<T>> streams) {
    final controller = StreamController<T>();
    final streamList = streams.toList();
    var active = streamList.length;
    if (active == 0) {
      controller.close();
      return controller.stream;
    }

    final subscriptions = <StreamSubscription<T>>[];
    for (final stream in streamList) {
      final sub = stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          active--;
          if (active == 0) controller.close();
        },
      );
      subscriptions.add(sub);
    }

    controller.onCancel = () async {
      await Future.wait([for (final s in subscriptions) s.cancel()]);
    };

    return controller.stream;
  }

  /// Combines the latest events of two streams using [combiner].
  static Stream<R> combineLatest<A, B, R>(
    Stream<A> a,
    Stream<B> b,
    R Function(A a, B b) combiner,
  ) {
    final controller = StreamController<R>();
    A? lastA;
    B? lastB;
    var hasA = false;
    var hasB = false;

    void emit() {
      if (hasA && hasB) {
        controller.add(combiner(lastA as A, lastB as B));
      }
    }

    late final StreamSubscription<A> subA;
    late final StreamSubscription<B> subB;

    subA = a.listen(
      (val) {
        lastA = val;
        hasA = true;
        emit();
      },
      onError: controller.addError,
      onDone: () {
        if (hasB) controller.close();
      },
    );
    subB = b.listen(
      (val) {
        lastB = val;
        hasB = true;
        emit();
      },
      onError: controller.addError,
      onDone: () {
        if (hasA) controller.close();
      },
    );

    controller.onCancel = () async {
      await Future.wait([subA.cancel(), subB.cancel()]);
    };

    return controller.stream;
  }

  /// Zips emissions of two streams pairwise.
  static Stream<R> zip<A, B, R>(
    Stream<A> a,
    Stream<B> b,
    R Function(A a, B b) combiner,
  ) {
    final controller = StreamController<R>();
    final queueA = <A>[];
    final queueB = <B>[];
    var doneA = false;
    var doneB = false;

    void check() {
      while (queueA.isNotEmpty && queueB.isNotEmpty) {
        controller.add(combiner(queueA.removeAt(0), queueB.removeAt(0)));
      }
      if ((doneA && queueA.isEmpty) || (doneB && queueB.isEmpty)) {
        controller.close();
      }
    }

    late final StreamSubscription<A> subA;
    late final StreamSubscription<B> subB;

    subA = a.listen(
      (val) {
        queueA.add(val);
        check();
      },
      onError: controller.addError,
      onDone: () {
        doneA = true;
        check();
      },
    );
    subB = b.listen(
      (val) {
        queueB.add(val);
        check();
      },
      onError: controller.addError,
      onDone: () {
        doneB = true;
        check();
      },
    );

    controller.onCancel = () async {
      await Future.wait([subA.cancel(), subB.cancel()]);
    };

    return controller.stream;
  }

  /// Emits the stream that produces the first event and cancels the others.
  static Stream<T> race<T>(Iterable<Stream<T>> streams) {
    final controller = StreamController<T>();
    final subscriptions = <StreamSubscription<T>>[];
    var winnerFound = false;

    final streamList = streams.toList();
    if (streamList.isEmpty) {
      controller.close();
      return controller.stream;
    }

    for (final stream in streamList) {
      late StreamSubscription<T> sub;
      sub = stream.listen(
        (data) {
          if (!winnerFound) {
            winnerFound = true;
            for (final other in subscriptions) {
              if (other != sub) other.cancel();
            }
          }
          controller.add(data);
        },
        onError: (Object err, StackTrace st) {
          if (!winnerFound) {
            winnerFound = true;
            for (final other in subscriptions) {
              if (other != sub) other.cancel();
            }
          }
          controller.addError(err, st);
        },
        onDone: () {
          if (winnerFound) controller.close();
        },
      );
      subscriptions.add(sub);
    }

    controller.onCancel = () async {
      await Future.wait([for (final s in subscriptions) s.cancel()]);
    };

    return controller.stream;
  }
}
