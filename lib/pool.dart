/// Fan work out: async lanes for I/O on this isolate, worker isolates for
/// CPU work, results in input order. Pure `dart:isolate`.
///
/// ```dart
/// await Pool.map(urls, fetchPage, onResult: (_) => bar.tick()); // 4 lanes
/// final thumbs = await Pool.runAll(paths, makeThumb, onResult: (_) => bar.tick());
/// final digest = await Isolate.run(() => hashFile(path)); // one job: the SDK's
/// ```
///
/// Public surface is exactly: [Pool].
/// - `Pool.map()` runs async lanes on this isolate (for I/O: the job can
///   capture anything).
/// - `Pool.runAll()` runs a job per item on worker isolates (for CPU work:
///   the job and items must be sendable).
/// Nothing stays running between calls, so nothing needs closing.
library;

export 'core.dart';

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

/// Entry point: lanes here, CPU jobs on worker isolates.
abstract final class Pool {
  /// Run [job] over every item on async lanes on this isolate, results in
  /// input order. [limit] caps the lanes in flight (4 by default:
  /// lanes are I/O, so the core count says nothing; raise it for
  /// high-latency fan-out).
  /// [onResult] runs as each job finishes.
  /// The first error stops new jobs, waits for the lanes in flight, rethrows.
  ///
  /// For I/O: unlike [runAll], the job can capture anything (a client, a
  /// bar, a database handle), since nothing crosses isolates.
  static Future<List<R>> map<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? limit,
    void Function(R result)? onResult,
  }) => _lanes(items, (item, _) async => job(item), limit ?? 4, limit, onResult);

  /// Run [job] once per item on worker isolates, results in input order.
  /// [limit] caps the jobs in flight (the core count by default).
  /// [onResult] runs on this isolate as each job finishes. The first error
  /// stops new jobs and is rethrown.
  ///
  /// For CPU work: [job] and each item cross to another isolate, so they
  /// must be sendable (a top-level function or a closure over plain data);
  /// a port, a socket or a closure over one is an [ArgumentError]. Each job
  /// runs in a fresh isolate (`Isolate.run`), so a crashed job never takes a
  /// worker down and nothing is left running afterwards.
  static Future<List<R>> runAll<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? limit,
    void Function(R result)? onResult,
  }) => _lanes(
    items,
    (item, i) async {
      try {
        return await Isolate.run(() => job(item));
      } on ArgumentError catch (e) {
        // Isolate.run rejects what cannot cross: name the item.
        throw ArgumentError.value(item, 'items[$i]', 'cannot be sent to a worker isolate (${e.message})');
      }
    },
    limit ?? io.Platform.numberOfProcessors,
    limit,
    onResult,
  );

  /// [width] lanes over [items]; one isolate, so the shared `next++` needs
  /// no lock (it runs synchronously between awaits).
  static Future<List<R>> _lanes<T, R>(
    Iterable<T> items,
    Future<R> Function(T item, int index) run,
    int width,
    int? limit,
    void Function(R result)? onResult,
  ) async {
    if (limit != null && limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }
    final list = items.toList();
    if (list.isEmpty) return <R>[];
    final out = List<R?>.filled(list.length, null);
    var next = 0;
    Object? error;
    StackTrace? stack;

    Future<void> lane() async {
      while (error == null) {
        final i = next++;
        if (i >= list.length) return;
        try {
          final r = await run(list[i], i);
          out[i] = r;
          if (error == null) onResult?.call(r);
        } catch (e, st) {
          if (error == null) {
            error = e;
            stack = st;
          }
          return;
        }
      }
    }

    await Future.wait([for (var k = 0; k < width.clamp(1, list.length); k++) lane()]);
    final e = error;
    if (e != null) Error.throwWithStackTrace(e, stack!);
    return [for (final r in out) r as R];
  }
}
