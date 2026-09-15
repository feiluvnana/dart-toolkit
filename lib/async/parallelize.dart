import 'dart:async';

import '../core/either.dart';

/// Concurrency extensions on [Iterable] to process work in parallel with [Either] outcomes.
extension ParallelizeIterable<T> on Iterable<T> {
  /// Maps [worker] concurrently over all elements with up to [concurrency] tasks in flight.
  ///
  /// Preserves input order and returns each outcome wrapped in [Either<Object, R>]
  /// ([Right] on success, [Left] on failure), never throwing on individual task errors.
  Future<List<Either<Object, R>>> parallelize<R>(FutureOr<R> Function(T item) worker, {int concurrency = 4}) async {
    final list = toList();
    final results = List<Either<Object, R>?>.filled(list.length, null);
    final active = <Future<void>>{};
    final limit = concurrency > 0 ? concurrency : 1;

    for (var i = 0; i < list.length; i++) {
      final index = i;
      final item = list[index];
      late final Future<void> task;

      task = Future<void>(() async {
        try {
          final res = await worker(item);
          results[index] = Right(res);
        } catch (error) {
          results[index] = Left(error);
        } finally {
          active.remove(task);
        }
      });
      active.add(task);
      if (active.length >= limit) await Future.any(active);
    }

    await Future.wait(active);
    return List.generate(list.length, (i) => results[i]!);
  }
}

/// Concurrency extensions on [Stream] to process items in parallel with [Either] outcomes.
extension ParallelizeStream<T> on Stream<T> {
  /// Processes stream items concurrently with up to [concurrency] workers in flight,
  /// yielding each outcome as [Either<Object, R>] as soon as it completes.
  Stream<Either<Object, R>> parallelize<R>(FutureOr<R> Function(T item) worker, {int concurrency = 4}) {
    late final StreamController<Either<Object, R>> controller;
    final active = <Future<void>>{};
    final limit = concurrency > 0 ? concurrency : 1;
    StreamSubscription<T>? subscription;

    void checkDone() {
      if (subscription == null && active.isEmpty && !controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<Either<Object, R>>(
      onListen: () {
        subscription = listen(
          (item) {
            late final Future<void> task;
            task = Future<void>(() async {
              try {
                final res = await worker(item);
                if (!controller.isClosed) controller.add(Right(res));
              } catch (error) {
                if (!controller.isClosed) controller.add(Left(error));
              } finally {
                active.remove(task);
                if (subscription?.isPaused == true && active.length < limit) {
                  subscription?.resume();
                }
                checkDone();
              }
            });
            active.add(task);
            if (active.length >= limit) subscription?.pause();
          },
          onError: (Object error) {
            if (!controller.isClosed) controller.add(Left(error));
          },
          onDone: () {
            subscription = null;
            checkDone();
          },
        );
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
      onPause: () => subscription?.pause(),
      onResume: () {
        if (active.length < limit) subscription?.resume();
      },
    );

    return controller.stream;
  }
}
