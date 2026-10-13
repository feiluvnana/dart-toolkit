/// One process-wide pool of worker isolates. Thin facade over
/// `package:worker_manager`.
///
/// ```dart
/// final bar = Console.bar(urls.length, label: 'Pages');
/// await Pool.map(urls, fetch, onResult: (_) => bar.tick());
/// await bar.close();
/// ```
///
/// Public surface is exactly: [Pool].
/// - `Pool.run()` runs one job, `Pool.map()` runs a job per item in order,
///   `Pool.close()` stops the workers.
/// Everything else is private.
library;

export 'core.dart';

import 'dart:async';
import 'dart:io' as io;

import 'package:worker_manager/worker_manager.dart';

/// Entry point: run jobs on reused worker isolates.
abstract final class Pool {
  /// Boot in progress or done; shared by concurrent first calls so two
  /// simultaneous first uses initialise the engine only once.
  static Future<void>? _initFuture;

  /// Shutdown in progress; a boot that starts while one runs waits for it
  /// instead of initialising a half-torn-down engine.
  static Future<void>? _shutdownFuture;

  /// Top-level [run]/[map] calls in flight. When the count reaches 0 the
  /// engine is shut down, so idle workers never keep the script alive; the
  /// next call boots it again lazily.
  static int _active = 0;

  /// Top-level [run]/[map] calls in flight, failed by [close] with a
  /// [StateError]. The engine gives no cancellation for a running job, so
  /// each outer future races its body against this signal instead; late
  /// body completions find a settled completer and are dropped.
  static final Set<Completer<Object?>> _inflight = {};

  static Future<void> _ensureInit() {
    final booted = _initFuture;
    if (booted != null) return booted;
    final draining = _shutdownFuture;
    Future<void> boot() async {
      if (draining != null) await draining;
      await workerManager.init(isolatesCount: _workerCount);
    }

    final next = boot();
    _initFuture = next;
    // A failed boot must not stick: drop it so the next call retries.
    next.then((_) {}, onError: (_) {
      if (identical(_initFuture, next)) _initFuture = null;
    });
    return next;
  }

  /// Run one [job] on a worker and return its result. An error in the job is
  /// rethrown with its stack trace. A job that captures a non-sendable value
  /// (a `Bar`, a socket, a `Page`) is an [ArgumentError] at the call.
  static Future<R> run<R>(FutureOr<R> Function() job) {
    final result = Completer<R>();
    _guard(result);
    _inflight.add(result);
    _active++;
    () async {
      try {
        // A close() in the gap before boot fails the result first; skip the
        // wasted boot.
        if (result.isCompleted) return;
        await _ensureInit();
        if (!result.isCompleted) {
          result.complete(
            await _submit<R>(job, 'job', () => workerManager.execute<R>(job)),
          );
        }
      } catch (e, st) {
        if (!result.isCompleted) result.completeError(e, st);
      } finally {
        _inflight.remove(result);
        _active--;
        if (_active == 0) await _idle();
      }
    }();
    return result.future;
  }

  /// Run [job] over every item on the workers, results in input order.
  /// [limit] caps the jobs in flight (defaults to the worker count).
  /// [onResult] runs on the caller's isolate as each job finishes.
  /// The first error stops new jobs, waits for the ones in flight, rethrows.
  static Future<List<R>> map<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? limit,
    void Function(R result)? onResult,
  }) {
    if (limit != null && limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }
    final list = items.toList();
    if (list.isEmpty) return Future.value(<R>[]);
    final result = Completer<List<R>>();
    _guard(result);
    _inflight.add(result);
    _active++;
    () async {
      try {
        if (result.isCompleted) return;
        await _ensureInit();
        final max = (limit ?? _workerCount).clamp(1, list.length);
        final out = List<R?>.filled(list.length, null);
        var next = 0;
        var failed = false;
        Object? firstError;
        StackTrace? firstStack;

        Future<void> worker() async {
          while (true) {
            if (failed || result.isCompleted) return;
            final i = next++;
            if (i >= list.length) return;
            final item = list[i];
            R? r;
            try {
              r = await _submit<R>(
                item,
                'items[$i]',
                () => workerManager.execute<R>(_thunk(job, item)),
              );
              out[i] = r;
            } catch (e, st) {
              if (!failed) {
                failed = true;
                firstError = e;
                firstStack = st;
              }
              continue;
            }
            if (!failed && !result.isCompleted) {
              try {
                onResult?.call(r as R);
              } catch (e, st) {
                // Progress-callback failure, not a job failure.
                if (!failed) {
                  failed = true;
                  firstError = e;
                  firstStack = st;
                }
              }
            }
          }
        }

        final workers = <Future<void>>[
          for (var w = 0; w < max; w++) worker(),
        ];
        await Future.wait(workers);
        if (result.isCompleted) return;
        if (failed) {
          result.completeError(firstError!, firstStack);
        } else {
          result.complete([for (final r in out) r as R]);
        }
      } catch (e, st) {
        if (!result.isCompleted) result.completeError(e, st);
      } finally {
        _inflight.remove(result);
        _active--;
        if (_active == 0) await _idle();
      }
    }();
    return result.future;
  }

  /// Stop the workers. Static, because the pool is process-wide, so [Pool] is
  /// not a [Closeable]. Idle workers never keep a script alive; the pool
  /// restarts on the next call. Jobs still in flight fail with a [StateError].
  /// Idempotent: concurrent or repeated calls share one shutdown and never
  /// throw from the engine teardown itself.
  static Future<void> close() async {
    final boot = _initFuture;
    _initFuture = null;
    _failInflight();
    final draining = _shutdownFuture;
    if (draining != null) await draining;
    if (boot != null) {
      // A boot that was in flight when close was called lands now, if ever.
      try {
        await boot;
      } catch (_) {
        // A stillborn engine needs no shutdown; drop through to sweep.
      }
    }
    try {
      await _shutdown();
    } catch (_) {
      // Teardown itself never fails close().
    }
  }

  /// Shut the engine down when no top-level call is left. Best effort: a
  /// failing shutdown must not replace the job's own result, so errors here
  /// are swallowed; the next use boots (or sweeps) again.
  static Future<void> _idle() async {
    if (_initFuture == null) return;
    _initFuture = null;
    try {
      await _shutdown();
    } catch (_) {
      // Keep the caller's result; close() retries the sweep.
    }
  }

  static Future<void> _shutdown() async {
    final draining = _shutdownFuture;
    if (draining != null) {
      await draining;
      return;
    }
    final gate = Completer<void>();
    _shutdownFuture = gate.future;
    try {
      await workerManager.dispose();
    } finally {
      gate.complete();
      if (identical(_shutdownFuture, gate.future)) _shutdownFuture = null;
    }
  }

  /// Fail every in-flight top-level call with `StateError('pool closed')`.
  /// Late body completions find settled completers and are dropped (see
  /// [run]/[map]). Futures nobody ever awaits stay silent instead of
  /// killing the isolate as unhandled (see [_guard]).
  static void _failInflight() {
    if (_inflight.isEmpty) return;
    final pending = _inflight.toList();
    _inflight.clear();
    for (final result in pending) {
      if (!result.isCompleted) {
        result.completeError(StateError('pool closed'));
      }
    }
  }

  /// Mark [result]'s error as handled up front, so a [close] that fails it
  /// before the caller first listens never kills the isolate as an
  /// unhandled error. Every later listener still receives the outcome
  /// unchanged.
  static void _guard(Completer<Object?> result) {
    unawaited(result.future.then<void>((_) {}, onError: (_) {}));
  }

  /// A zero-argument thunk around [job] applied to [item], built in a scope
  /// that holds nothing else: the closure sent to the worker isolate must
  /// not capture the enclosing call state (completers are unsendable).
  static FutureOr<R> Function() _thunk<T, R>(
    FutureOr<R> Function(T) job,
    T item,
  ) =>
      () => job(item);

  /// Submit one engine job. The engine future is always listened (so a
  /// [close] racing it never surfaces an unhandled error), and engine
  /// errors that report a non-sendable value surface as [ArgumentError] at
  /// the call; anything else (including the job's own errors) passes
  /// through as is.
  static Future<R> _submit<R>(
    Object? value,
    String name,
    Cancelable<R> Function() start,
  ) {
    final result = Completer<R>();
    _guard(result);
    Cancelable<R> engine;
    try {
      engine = start();
    } catch (e, st) {
      result.completeError(_sendableError(value, name, e), st);
      return result.future;
    }
    unawaited(
      engine.then((v) {
        if (!result.isCompleted) result.complete(v);
      }, onError: (Object e, StackTrace st) {
        if (!result.isCompleted) {
          result.completeError(_sendableError(value, name, e), st);
        }
      }),
    );
    return result.future;
  }

  /// Map an engine failure to the [ArgumentError] the call site expects for
  /// a non-sendable job or item. An [ArgumentError] from the engine already
  /// is one, so it passes through; isolate send failures (unsendable values)
  /// become [ArgumentError], anything else (the job's own errors) passes
  /// through as is. Matching is on `sendable`/`transferable`, not generic
  /// `isolate`/`send`, so `throw 'isolate failed'` is not misclassified.
  static Object _sendableError(Object? value, String name, Object error) {
    if (error is ArgumentError) return error;
    final message = error.toString().toLowerCase();
    final sendFailure =
        message.contains('sendable') || message.contains('transferable');
    if (!sendFailure) return error;
    return ArgumentError.value(
      value,
      name,
      'must cross isolates (strings, numbers, lists, records, fs handles): $error',
    );
  }

  static int get _workerCount {
    try {
      final n = io.Platform.numberOfProcessors - 1;
      return n < 1 ? 1 : n;
    } catch (_) {
      return 1;
    }
  }
}
