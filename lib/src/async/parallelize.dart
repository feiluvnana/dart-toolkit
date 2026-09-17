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
  /// [CancellationException]. [isolate] runs each worker in a background [Isolate].
  ///
  /// ```dart
  /// final settled = await urls.parallelize(fetch);            // every outcome
  /// final pages   = (await urls.parallelize(fetch)).unwrap(); // or throw the first
  /// ```
  Future<List<Either<Object, R>>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    CancellationToken? cancelToken,
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
        outcome ?? Left<Object, R>(CancellationException(cancelToken?.reason?.toString() ?? 'Task was not executed.')),
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
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    CancellationToken? cancelToken,
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
        if (cancelToken != null && cancelToken.isCancelled) {
          controller.close();
          return;
        }

        cancelToken?.onCancel(() {
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
                  if (subscription?.isPaused == true && pool.availablePermits > 0) {
                    subscription?.resume();
                  }
                  checkDone();
                });
            active.add(task);
            if (pool.availablePermits == 0) subscription?.pause();
          },
          onError: (Object error, StackTrace st) {
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
