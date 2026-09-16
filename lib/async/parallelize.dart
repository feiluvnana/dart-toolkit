import 'dart:async';
import 'dart:isolate';

import '../core/either.dart';
import 'sync.dart';

/// Concurrency extensions on [Iterable] to process work in parallel.
extension ParallelizeIterable<T> on Iterable<T> {
  /// Maps [worker] concurrently over all elements, **throwing on first error (Fail-Fast)**.
  ///
  /// - Preserves input order in the returned `List<R>`.
  /// - Throws immediately if any task throws an error, cancelling pending work.
  /// - Pass [concurrency] to control the maximum tasks in flight (default 4).
  /// - Set [isolate] to `true` to offload worker computation to background [Isolate]s.
  Future<List<R>> parallelMap<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];

    final limit = concurrency > 0 ? concurrency : 1;
    final workerCount = list.length < limit ? list.length : limit;
    final results = List<R?>.filled(list.length, null);
    var nextIndex = 0;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runWorker() async {
      while (true) {
        if (firstError != null) return;
        final index = nextIndex++;
        if (index >= list.length) return;

        final item = list[index];
        try {
          final R val;
          if (isolate) {
            val = await Isolate.run(() => worker(item));
          } else {
            val = await worker(item);
          }
          if (firstError != null) return;
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

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace ?? StackTrace.current);
    }

    return results.cast<R>();
  }

  /// Maps [worker] concurrently over all elements, **settling all tasks without throwing**.
  ///
  /// - Preserves input order in the returned `List<Either<Object, R>>`.
  /// - Successes are wrapped in [Right], failures in [Left]. Never throws on individual errors.
  /// - Pass [concurrency] to control the maximum tasks in flight (default 4).
  /// - Set [isolate] to `true` to offload worker computation to background [Isolate]s.
  Future<List<Either<Object, R>>> parallelSettle<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) async {
    final list = toList();
    if (list.isEmpty) return [];

    final limit = concurrency > 0 ? concurrency : 1;
    final workerCount = list.length < limit ? list.length : limit;
    final results = List<Either<Object, R>>.filled(list.length, Left<Object, R>(StateError('Uninitialized outcome')));
    var nextIndex = 0;

    Future<void> runWorker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= list.length) return;

        final item = list[index];
        if (isolate) {
          results[index] = await Either.guardAsync(() => Isolate.run(() => worker(item)));
        } else {
          results[index] = await Either.guardAsync(() async => worker(item));
        }
      }
    }

    final workers = List.generate(workerCount, (_) => runWorker());
    await Future.wait(workers);

    return results;
  }

  /// Alias for [parallelSettle] to preserve backwards compatibility.
  ///
  /// Maps [worker] concurrently over all elements and returns outcomes wrapped in [Either].
  Future<List<Either<Object, R>>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) => parallelSettle(worker, concurrency: concurrency, isolate: isolate);
}

/// Concurrency extensions on [Stream] to process items in parallel.
extension ParallelizeStream<T> on Stream<T> {
  /// Maps [worker] concurrently over stream items, emitting results as they finish.
  ///
  /// Errors from individual workers are emitted into the stream's error channel.
  Stream<R> parallelMap<R>(FutureOr<R> Function(T item) worker, {int concurrency = 4, bool isolate = false}) {
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
        subscription = listen(
          (item) {
            late final Future<void> task;
            task = pool
                .run(() async {
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

  /// Processes stream items concurrently, yielding outcomes as [Either<Object, R>]
  /// as soon as each completes. Never throws into the stream's error channel.
  Stream<Either<Object, R>> parallelSettle<R>(
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
            task = pool
                .run(() async {
                  if (isolate) {
                    return await Either.guardAsync(() => Isolate.run(() => worker(item)));
                  } else {
                    return await Either.guardAsync(() async => worker(item));
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

  /// Alias for [parallelSettle] to preserve backwards compatibility.
  Stream<Either<Object, R>> parallelize<R>(
    FutureOr<R> Function(T item) worker, {
    int concurrency = 4,
    bool isolate = false,
  }) => parallelSettle(worker, concurrency: concurrency, isolate: isolate);
}
