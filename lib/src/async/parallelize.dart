import 'dart:async';
import 'dart:isolate';

import '../core/either.dart';
import 'cancellation_token.dart';
import 'sync.dart';

/// Concurrency extensions on [Iterable] to process work in parallel.
///
/// {@category Concurrency}
extension IterableParallelExtensions<T> on Iterable<T> {
  /// Maps [worker] concurrently over all elements, settling every task.
  ///
  /// - Preserves input order in the returned `List<Either<Object, R>>`.
  /// - Successes are wrapped in [Right], failures in [Left]. Never throws for an
  ///   individual task; call `.unwrap()` on the result to surface the first failure.
  /// - Pass [concurrency] to control the maximum tasks in flight (default 4).
  /// - Set [isolate] to `true` to offload worker computation to background [Isolate]s.
  /// - Optionally pass [cancelToken] to cooperatively abort the operation; tasks that
  ///   never ran come back as a [Left] holding a [CancellationException].
  ///
  /// ```dart
  /// final settled = await urls.parallelize(fetch);          // every outcome
  /// final pages   = (await urls.parallelize(fetch)).unwrap(); // or throw the first failure
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
  /// Maps [worker] concurrently over stream items, emitting outcomes as they settle.
  ///
  /// Never throws into the stream's error channel for an individual task; call
  /// `.unwrap()` on the result to forward the first failure as a stream error.
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
