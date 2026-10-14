/// One process-wide pool: async lanes for I/O on this isolate, worker isolates
/// for CPU work. Thin facade over `package:worker_manager`.
///
/// ```dart
/// await Pool.map(urls, fetchPage, concurrency: 4, onResult: (_) => bar.tick());
/// final thumbs = await Pool.computeAll(paths, makeThumb, onResult: (_) => bar.tick());
/// final digest = await Pool.compute(() => hashFile(path));
/// ```
///
/// Public surface is exactly: [Pool].
/// - `Pool.map()` runs async lanes on this isolate (for I/O: the job can
///   capture anything, results in input order).
/// - `Pool.compute()` runs one job on a worker, `Pool.computeAll()` runs a
///   job per item on workers, results in input order.
/// - `Pool.shutdown()` stops the workers now; the pool restarts on the next
///   call, so it is not a [Closeable].
/// Everything else is private.
library;

export 'core.dart';

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:worker_manager/worker_manager.dart';

/// Entry point: lanes here, CPU jobs on reused worker isolates.
abstract final class Pool {
  /// Boot in progress or done; shared by concurrent first calls so two
  /// simultaneous first uses initialise the engine only once.
  static Future<void>? _initFuture;

  /// Shutdown in progress; a boot that starts while one runs waits for it
  /// instead of initialising a half-torn-down engine.
  static Future<void>? _shutdownFuture;

  /// Top-level [compute]/[computeAll] calls in flight. When the count reaches
  /// 0 the engine is shut down, so idle workers never keep the script alive;
  /// the next call boots it again lazily. ([map] runs no workers, so lanes
  /// are not counted here, but they are still failed by [shutdown].)
  static int _active = 0;

  /// Top-level calls in flight ([map] lanes included), failed by [shutdown]
  /// with a [StateError]. The engine gives no cancellation for a running
  /// job, so each outer future races its body against this signal instead;
  /// late body completions find a settled completer and are dropped.
  static final Set<Completer<Object?>> _inflight = {};

  /// Job/item runtime types that already survived one [SendPort] round trip.
  /// The first call per type pays the probe; later calls skip it.
  static final Set<Type> _provenSendable = {};

  static Future<void> _ensureInit() {
    final booted = _initFuture;
    if (booted != null) return booted;
    final draining = _shutdownFuture;
    Future<void> boot() async {
      if (draining != null) await draining;
      try {
        await workerManager.init(isolatesCount: _workerCount);
      } catch (e) {
        throw StateError('pool unavailable: $e');
      }
    }

    final next = boot();
    _initFuture = next;
    // A failed boot must not stick: drop it so the next call retries.
    next.then((_) {}, onError: (_) {
      if (identical(_initFuture, next)) _initFuture = null;
    });
    return next;
  }

  /// Run [job] over every item on async lanes on this isolate, results in
  /// input order. [concurrency] caps the lanes in flight (defaults to the
  /// worker count; pass a higher number for high-latency fan-out).
  /// [onResult] runs on the caller's isolate as each job finishes.
  /// The first error stops new jobs, waits for the lanes in flight, rethrows.
  ///
  /// For I/O: unlike [computeAll], the job can capture anything (a client, a
  /// bar, a database handle), since nothing crosses isolates.
  static Future<List<R>> map<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? concurrency,
    void Function(R result)? onResult,
  }) {
    if (concurrency != null && concurrency < 1) {
      throw ArgumentError.value(
          concurrency, 'concurrency', 'must be at least 1');
    }
    final list = items.toList();
    if (list.isEmpty) return Future.value(<R>[]);
    final result = Completer<List<R>>();
    _guard(result);
    _inflight.add(result);
    () async {
      try {
        final out = List<R?>.filled(list.length, null);
        var next = 0;
        var failed = false;
        Object? firstError;
        StackTrace? firstStack;

        // One isolate, so the shared `next++` needs no lock: it runs
        // synchronously between awaits.
        Future<void> lane() async {
          while (true) {
            if (failed || result.isCompleted) return;
            final i = next++;
            if (i >= list.length) return;
            R r;
            try {
              r = await job(list[i]);
            } catch (e, st) {
              if (!failed) {
                failed = true;
                firstError = e;
                firstStack = st;
              }
              return;
            }
            out[i] = r;
            if (!failed && !result.isCompleted) {
              try {
                onResult?.call(r);
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

        final width = (concurrency ?? _workerCount).clamp(1, list.length);
        await Future.wait([for (var k = 0; k < width; k++) lane()]);
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
      }
    }();
    return result.future;
  }

  /// Run one [job] on a worker and return its result. An error in the job is
  /// rethrown with its stack trace. A job that captures a non-sendable value
  /// (a socket, a bar) is an [ArgumentError] at the call.
  static Future<R> compute<R>(FutureOr<R> Function() job) {
    final result = Completer<R>();
    _guard(result);
    _inflight.add(result);
    _active++;
    () async {
      try {
        // A shutdown() in the gap before boot fails the result first; skip
        // the wasted boot.
        if (result.isCompleted) return;
        _ensureSendable(job, 'job');
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
  /// [concurrency] caps the jobs in flight (defaults to the worker count).
  /// [onResult] runs on the caller's isolate as each job finishes.
  /// The first error stops new jobs, waits for the ones in flight, rethrows.
  static Future<List<R>> computeAll<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? concurrency,
    void Function(R result)? onResult,
  }) {
    if (concurrency != null && concurrency < 1) {
      throw ArgumentError.value(
          concurrency, 'concurrency', 'must be at least 1');
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
        _ensureSendable(job, 'job');
        for (var i = 0; i < list.length; i++) {
          _ensureSendable(list[i], 'items[$i]');
        }
        await _ensureInit();
        final max = (concurrency ?? _workerCount).clamp(1, list.length);
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
  /// restarts on the next call. Jobs still in flight (lanes included) fail
  /// with a [StateError]. Idempotent: concurrent or repeated calls share one
  /// shutdown and never throw from the engine teardown itself.
  static Future<void> shutdown() async {
    final boot = _initFuture;
    _initFuture = null;
    _failInflight();
    final draining = _shutdownFuture;
    if (draining != null) await draining;
    if (boot != null) {
      // A boot that was in flight when shutdown was called lands now, if ever.
      try {
        await boot;
      } catch (_) {
        // A stillborn engine needs no shutdown; drop through to sweep.
      }
    }
    try {
      await _shutdown();
    } catch (_) {
      // Teardown itself never fails shutdown().
    }
  }

  /// Shut the engine down when no top-level worker call is left. Best
  /// effort: a failing shutdown must not replace the job's own result, so
  /// errors here are swallowed; the next use boots (or sweeps) again.
  static Future<void> _idle() async {
    if (_initFuture == null) return;
    _initFuture = null;
    try {
      await _shutdown();
    } catch (_) {
      // Keep the caller's result; shutdown() retries the sweep.
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
  /// [compute]/[computeAll]/[map]). Futures nobody ever awaits stay silent
  /// instead of killing the isolate as unhandled (see [_guard]).
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

  /// Mark [result]'s error as handled up front, so a [shutdown] that fails
  /// it before the caller first listens never kills the isolate as an
  /// unhandled error. Every later listener still receives the outcome
  /// unchanged.
  static void _guard(Completer<Object?> result) {
    unawaited(result.future.then<void>((_) {}, onError: (_) {}));
  }

  /// Check [value] crosses isolates, once per runtime type. A [SendPort]
  /// round trip throws [ArgumentError] synchronously for a non-sendable
  /// value, so no message-text matching is needed; the first call per job or
  /// item type pays one throwaway port, later calls skip it.
  static void _ensureSendable(Object? value, String name) {
    if (_provenSendable.contains(value.runtimeType)) return;
    final probe = ReceivePort();
    try {
      probe.sendPort.send(value);
    } on ArgumentError catch (e) {
      throw ArgumentError.value(
        value,
        name,
        'must cross isolates (strings, numbers, lists, records, plain data): $e',
      );
    } finally {
      probe.close();
    }
    _provenSendable.add(value.runtimeType);
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
  /// [shutdown] racing it never surfaces an unhandled error), and engine
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
  /// a non-sendable job or item. Classification is by type
  /// ([ArgumentError], [IsolateSpawnException]), never by matching
  /// `sendable`/`transferable` in the message string, so an SDK wording
  /// change cannot break it and `throw 'isolate failed'` is not
  /// misclassified. Anything else (the job's own errors) passes through.
  static Object _sendableError(Object? value, String name, Object error) {
    if (error is ArgumentError) return error;
    if (error is IsolateSpawnException) {
      return ArgumentError.value(
        value,
        name,
        'must cross isolates (strings, numbers, lists, records, plain data): $error',
      );
    }
    return error;
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
