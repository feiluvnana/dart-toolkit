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

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:worker_manager/worker_manager.dart';

/// Entry point: run jobs on reused worker isolates.
abstract final class Pool {
  static var _inited = false;

  static Future<void> _ensureInit() async {
    if (!_inited) {
      await workerManager.init();
      _inited = true;
    }
  }

  /// Run one [job] on a worker and return its result. An error in the job is
  /// rethrown with its stack trace. A job that captures a non-sendable value
  /// (a `Bar`, a socket, a `Page`) is an [ArgumentError] at the call.
  static Future<R> run<R>(FutureOr<R> Function() job) async {
    _assertSendable(job, 'job');
    await _ensureInit();
    return workerManager.execute<R>(job);
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
  }) async {
    if (limit != null && limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }
    final list = items.toList();
    if (list.isEmpty) return <R>[];
    for (var i = 0; i < list.length; i++) {
      _assertSendable(list[i], 'items[$i]');
    }
    _assertSendable(job, 'job');
    await _ensureInit();
    final max = (limit ?? _workerCount).clamp(1, list.length);
    final out = List<R?>.filled(list.length, null);
    var next = 0;
    var failed = false;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (true) {
        if (failed) return;
        final i = next++;
        if (i >= list.length) return;
        final item = list[i];
        try {
          final r = await workerManager.execute<R>(() => job(item));
          out[i] = r;
          if (!failed) onResult?.call(r);
        } catch (e, st) {
          if (!failed) {
            failed = true;
            firstError = e;
            firstStack = st;
          }
        }
      }
    }

    final workers = <Future<void>>[
      for (var w = 0; w < max; w++) worker(),
    ];
    await Future.wait(workers);
    if (failed) {
      await Future<List<R>>.error(firstError!, firstStack);
    }
    return [for (final r in out) r as R];
  }

  /// Stop the workers. Static, because the pool is process-wide, so [Pool] is
  /// not a [Closeable]. Idle workers never keep a script alive; the pool
  /// restarts on the next call.
  static Future<void> close() async {
    if (_inited) {
      await workerManager.dispose();
      _inited = false;
    }
  }

  static int get _workerCount {
    try {
      final n = io.Platform.numberOfProcessors;
      return n < 1 ? 1 : n;
    } catch (_) {
      return 1;
    }
  }

  static void _assertSendable(Object? value, String name) {
    // Probe: sending a value with non-sendable captures throws ArgumentError
    // synchronously, so the call fails fast instead of on the worker.
    final probe = RawReceivePort();
    try {
      probe.sendPort.send(value);
    } on ArgumentError catch (e) {
      throw ArgumentError.value(
        value,
        name,
        'must cross isolates (strings, numbers, lists, records, fs handles): $e',
      );
    } finally {
      probe.close();
    }
  }
}
