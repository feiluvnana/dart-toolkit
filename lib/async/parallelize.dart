import 'dart:async';
import 'dart:isolate';

import '../core/either.dart';
import 'cancellation_token.dart';
import 'sync.dart';

/// Concurrency extensions on [Iterable] to process work in parallel.
///
/// {@category Concurrency}
extension ParallelizeIterable<T> on Iterable<T> {
  /// Maps [worker] concurrently over all elements, **throwing on first error (Fail-Fast)**.
  ///
  /// - Preserves input order in the returned `List<R>`.
  /// - Throws immediately if any task throws an error, skipping unstarted items.
  /// - Pass [concurrency] to control the maximum tasks in flight (default 4).
  /// - Set [isolate] to `true` to offload worker computation to background [Isolate]s.
  /// - Optionally pass [cancelToken] to cooperatively abort the operation.
  Future<List<R>> parallelMap<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    CancellationToken? cancelToken,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];

    cancelToken?.throwIfCancelled();

    final limit = concurrency > 0 ? concurrency : 1;
    final workerCount = list.length < limit ? list.length : limit;
    final results = List<R?>.filled(list.length, null);
    var nextIndex = 0;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runWorker() async {
      while (true) {
        if (firstError != null || (cancelToken != null && cancelToken.isCancelled)) return;
        final index = nextIndex++;
        if (index >= list.length) return;

        final item = list[index];
        try {
          cancelToken?.throwIfCancelled();
          final R val;
          if (isolate) {
            val = await Isolate.run(() => worker(item));
          } else {
            val = await worker(item);
          }
          if (firstError != null || (cancelToken != null && cancelToken.isCancelled)) return;
          results[index] = val;
        } catch (e, st) {
          firstError ??= e;
          firstStackTrace ??= st;
          return;
        }
      }
    }

    final workers = List.generate(workerCount, (_) => runWorker());
    await Future.wait(workers);

    if (cancelToken != null && cancelToken.isCancelled && firstError == null) {
      cancelToken.throwIfCancelled();
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace ?? StackTrace.current);
    }

    return results.cast<R>();
  }

  /// Maps [worker] concurrently over all elements, **settling all tasks without throwing**.
  ///
  /// - Preserves input order in the returned `List<Either<E, R>>`.
  /// - Successes are wrapped in [Right], failures in [Left]. Never throws on individual errors.
  /// - Pass [concurrency] to control the maximum tasks in flight (default 4).
  /// - Set [isolate] to `true` to offload worker computation to background [Isolate]s.
  /// - Optionally pass [cancelToken] to cooperatively abort the operation.
  Future<List<Either<E, R>>> parallelSettle<E extends Object, R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    E Function(Object error, StackTrace stackTrace)? onError,
    CancellationToken? cancelToken,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];

    cancelToken?.throwIfCancelled();

    final limit = concurrency > 0 ? concurrency : 1;
    final workerCount = list.length < limit ? list.length : limit;
    final results = List<Either<E, R>>.filled(
      list.length,
      Left<E, R>(
        (onError != null
                ? onError(StateError('Uninitialized outcome'), StackTrace.current)
                : StateError('Uninitialized outcome'))
            as E,
      ),
    );
    var nextIndex = 0;

    Future<void> runWorker() async {
      while (true) {
        if (cancelToken != null && cancelToken.isCancelled) return;
        final index = nextIndex++;
        if (index >= list.length) return;

        final item = list[index];
        if (isolate) {
          results[index] = await Either.tryCatchAsync<E, R>(() => Isolate.run(() => worker(item)), onError: onError);
        } else {
          results[index] = await Either.tryCatchAsync<E, R>(() async => worker(item), onError: onError);
        }
      }
    }

    final workers = List.generate(workerCount, (_) => runWorker());
    await Future.wait(workers);

    return results;
  }

  /// Alias for [parallelSettle] to preserve backwards compatibility.
  Future<List<Either<Object, R>>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) => parallelSettle<Object, R>(worker, concurrency: concurrency, isolate: isolate);
}

/// Concurrency extensions on [Stream] to process items in parallel.
///
/// {@category Concurrency}
extension ParallelizeStream<T> on Stream<T> {
  /// Maps [worker] concurrently over stream items, emitting results as they finish.
  ///
  /// Errors from individual workers are emitted into the stream's error channel.
  Stream<R> parallelMap<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    CancellationToken? cancelToken,
  }) {
    final pool = Semaphore(concurrency > 0 ? concurrency : 1);
    late final StreamController<R> controller;
    final active = <Future<void>>{};
    StreamSubscription<T>? subscription;

    void checkDone() {
      if (subscription == null && active.isEmpty && !controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<R>(
      onListen: () {
        if (cancelToken != null && cancelToken.isCancelled) {
          controller.addError(CancellationException(cancelToken.reason?.toString() ?? 'Operation cancelled'));
          controller.close();
          return;
        }

        cancelToken?.onCancel(() {
          subscription?.cancel();
          if (!controller.isClosed) {
            controller.addError(CancellationException(cancelToken.reason?.toString() ?? 'Operation cancelled'));
            controller.close();
          }
        });

        subscription = listen(
          (item) {
            if (cancelToken != null && cancelToken.isCancelled) return;
            late final Future<void> task;
            task = pool
                .run(() async {
                  cancelToken?.throwIfCancelled();
                  if (isolate) {
                    return await Isolate.run(() => worker(item));
                  } else {
                    return await worker(item);
                  }
                })
                .then(
                  (val) {
                    if (!controller.isClosed) controller.add(val);
                  },
                  onError: (Object err, StackTrace st) {
                    if (!controller.isClosed) controller.addError(err, st);
                  },
                )
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
            if (!controller.isClosed) controller.addError(error, st);
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

  /// Processes stream items concurrently, yielding outcomes as [Either<E, R>]
  /// as soon as each completes. Never throws into the stream's error channel.
  Stream<Either<E, R>> parallelSettle<E extends Object, R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
    E Function(Object error, StackTrace stackTrace)? onError,
    CancellationToken? cancelToken,
  }) {
    final pool = Semaphore(concurrency > 0 ? concurrency : 1);
    late final StreamController<Either<E, R>> controller;
    final active = <Future<void>>{};
    StreamSubscription<T>? subscription;

    void checkDone() {
      if (subscription == null && active.isEmpty && !controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<Either<E, R>>(
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
                .run(() async {
                  if (isolate) {
                    return await Either.tryCatchAsync<E, R>(() => Isolate.run(() => worker(item)), onError: onError);
                  } else {
                    return await Either.tryCatchAsync<E, R>(() async => worker(item), onError: onError);
                  }
                })
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
            final leftOutcome = onError != null ? onError(error, st) : (error as E);
            if (!controller.isClosed) controller.add(Left(leftOutcome));
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

  /// Alias for [parallelSettle] to preserve backwards compatibility.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) => parallelSettle<Object, R>(worker, concurrency: concurrency, isolate: isolate);
}
