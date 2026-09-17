import 'dart:async';
import 'dart:isolate';

import '../core/either.dart';
import 'cancellation_token.dart';
import 'sync.dart';

/// Concurrency extensions on [Iterable] to process work in parallel.
///
/// {@category Concurrency}
extension IterableParallelExtensions<T> on Iterable<T> {
  /// Maps [worker] over all elements, at most [concurrency] at a time.
  ///
  /// Settles every task and preserves input order; an individual failure never
  /// throws. Tasks skipped by [cancelToken] come back as a [Left] holding a
  /// [CancelledException].
  ///
  /// [isolate] runs each worker in a background [Isolate]. The worker and everything
  /// it captures is copied **per item**, not per isolate — hoist shared data into the
  /// worker rather than closing over it.
  ///
  /// ```dart
  /// final settled = await urls.parallelize(fetch);            // every outcome
  /// final pages   = (await urls.parallelize(fetch)).unwrap(); // or throw the first
  /// ```
  Future<List<Either<Object, R>>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    CancelToken? cancelToken,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];

    final limit = concurrency > 0 ? concurrency : 1;
    final workerCount = list.length < limit ? list.length : limit;
    final results = List<Either<Object, R>?>.filled(list.length, null);
    var nextIndex = 0;

    Future<void> runWorker() async {
      while (true) {
        if (cancelToken != null && cancelToken.isCancelled) return;
        final index = nextIndex++;
        if (index >= list.length) return;

        final item = list[index];
        results[index] = isolate
            ? await Either.tryCatchAsync(() => Isolate.run(() => worker(item)))
            : await Either.tryCatchAsync(() => worker(item));
      }
    }

    await Future.wait(List.generate(workerCount, (_) => runWorker()));

    return [
      for (final outcome in results)
        outcome ?? Left<Object, R>(CancelledException(cancelToken?.reason?.toString() ?? 'Task was not executed.')),
    ];
  }
}

/// Concurrency extensions on [Stream] to process items in parallel.
///
/// {@category Concurrency}
extension StreamParallelExtensions<T> on Stream<T> {
  /// Maps [worker] over stream items, emitting outcomes as they settle.
  ///
  /// An individual failure never reaches the error channel; `.unwrap()` forwards it.
  /// A paused consumer pauses the source: nothing is buffered on its behalf.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    CancelToken? cancelToken,
  }) {
    final pool = Semaphore(concurrency > 0 ? concurrency : 1);
    late final StreamController<Either<Object, R>> controller;
    final active = <Future<void>>{};
    StreamSubscription<T>? subscription;
    void Function()? unregister;
    // Two independent reasons to hold the source: no free permit, and a paused consumer.
    var heldForPermit = false;

    void checkDone() {
      if (subscription == null && active.isEmpty && !controller.isClosed) {
        unregister?.call();
        controller.close();
      }
    }

    void hold() {
      if (!heldForPermit) {
        heldForPermit = true;
        subscription?.pause();
      }
    }

    void releaseIfIdle() {
      if (heldForPermit && pool.permits > 0) {
        heldForPermit = false;
        subscription?.resume();
      }
    }

    controller = StreamController<Either<Object, R>>(
      onListen: () {
        if (cancelToken != null && cancelToken.isCancelled) {
          controller.close();
          return;
        }

        unregister = cancelToken?.onCancel(() {
          subscription?.cancel();
          if (!controller.isClosed) controller.close();
        });

        subscription = listen(
          (item) {
            if (cancelToken != null && cancelToken.isCancelled) return;
            late final Future<void> task;
            task = pool
                .run(
                  () => isolate
                      ? Either.tryCatchAsync(() => Isolate.run(() => worker(item)))
                      : Either.tryCatchAsync(() => worker(item)),
                )
                .then((outcome) {
                  if (!controller.isClosed) controller.add(outcome);
                })
                .whenComplete(() {
                  active.remove(task);
                  releaseIfIdle();
                  checkDone();
                });
            active.add(task);
            if (pool.permits == 0) hold();
          },
          onError: (Object error, StackTrace st) {
            if (!controller.isClosed) controller.add(Left(error, st));
          },
          onDone: () {
            subscription = null;
            checkDone();
          },
        );
      },
      onCancel: () async {
        unregister?.call();
        await subscription?.cancel();
        subscription = null;
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
    );

    return controller.stream;
  }
}
