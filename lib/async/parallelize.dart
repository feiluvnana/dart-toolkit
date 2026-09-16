import 'dart:async';
import 'dart:isolate';

import '../core/either.dart';
import 'sync.dart';

/// Concurrency extensions on [Iterable] to process work in parallel with [Either] outcomes.
extension ParallelizeIterable<T> on Iterable<T> {
  /// Maps [worker] concurrently over all elements using [Semaphore] concurrency guarding.
  ///
  /// Preserves input order and returns each outcome wrapped in [Either<Object, R>]
  /// ([Right] on success, [Left] on failure), never throwing on individual task errors.
  ///
  /// - Pass [concurrency] to control the maximum tasks in flight (default 4).
  /// - Set [isolate] to `true` to offload worker computation to background [Isolate]s.
  Future<List<Either<Object, R>>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];

    final pool = Semaphore(concurrency > 0 ? concurrency : 1);

    final futures = list.map((item) {
      return pool.run(() async {
        if (isolate) {
          return Either.guardAsync(() => Isolate.run(() => worker(item)));
        } else {
          return Either.guardAsync(() async => worker(item));
        }
      });
    });

    return Future.wait(futures);
  }
}

/// Concurrency extensions on [Stream] to process items in parallel with [Either] outcomes.
extension ParallelizeStream<T> on Stream<T> {
  /// Processes stream items concurrently using [Semaphore] concurrency guarding,
  /// yielding each outcome as [Either<Object, R>] as soon as it completes.
  ///
  /// - Pass [concurrency] to control maximum workers in flight (default 4).
  /// - Set [isolate] to `true` to run worker computations on background [Isolate]s.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) {
    final pool = Semaphore(concurrency > 0 ? concurrency : 1);
    late final StreamController<Either<Object, R>> controller;
    final active = <Future<void>>{};
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
            task = pool.run(() async {
              if (isolate) {
                return await Either.guardAsync(() => Isolate.run(() => worker(item)));
              } else {
                return await Either.guardAsync(() async => worker(item));
              }
            }).then((outcome) {
              if (!controller.isClosed) controller.add(outcome);
            }).whenComplete(() {
              active.remove(task);
              if (subscription?.isPaused == true && pool.availablePermits > 0) {
                subscription?.resume();
              }
              checkDone();
            });
            active.add(task);
            if (pool.availablePermits == 0) subscription?.pause();
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
        if (pool.availablePermits > 0) subscription?.resume();
      },
    );

    return controller.stream;
  }
}

