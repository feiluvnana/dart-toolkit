/// Fan work out: async lanes for I/O on this isolate, or long-lived worker
/// isolates for CPU work; results in input order. Pure `dart:isolate`.
///
/// ```dart
/// await Pool.map(urls, fetchPage, onDone: bar.tick);                     // 4 lanes, fail fast
/// final done = await Pool.settle(files, (f) => cdn.save(f.url, f.to));   // never throws
/// for (final Failed(:item, :error) in done.failures()) Console.log('✗ $item: $error');
/// final thumbs = await Pool.map(paths, makeThumb, isolates: true);       // CPU work
/// final lanes = Pool(limit: 8);                                          // one limit shared by many callers
/// await lanes.run(() => cdn.get(url) > file);
/// ```
///
/// Public surface is exactly: [Pool], [Outcome], [Done], [Failed], [Outcomes].
/// - `Pool.map()` fails fast: the first error is rethrown with its type and
///   stack once the jobs in flight finish.
/// - `Pool.settle()` never throws: one [Outcome] per item, in input order.
/// - Both take `limit` `retries` `rate` `isolates` `onDone`.
/// - `Pool(limit:)` holds lanes that any number of calls share:
///   `pool.run(job)` waits for a free lane, first come first served.
/// Nothing stays running between calls, so nothing needs closing.
library;

export 'core.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:isolate';

import 'core.dart';
import 'src/rate.dart' as rate;
import 'src/retry.dart' as retry;

/// Entry point: [map] (fail fast) and [settle] (an outcome per item).
///
/// - [limit] caps the jobs in flight: 4 lanes by default (I/O: the core
///   count says nothing), or the core count with `isolates: true`.
/// - [retries] re-runs a job that threw an Exception with the shared
///   jittered backoff (1 s, 2 s … ±25%). An Error (a bug), bad data
///   (`ContentException`), TLS and HTTP status errors fail at once: give the
///   client its own `retries:` for 429 and 503.
///   [rate] paces job starts (each attempt takes a slot).
/// - `isolates: true` runs the jobs on `limit` long-lived worker isolates
///   that pull items: the job and every item must be sendable (a top-level
///   function or a closure over plain data). A value that cannot cross is an
///   [ArgumentError] naming the item; an `ArgumentError` the job itself
///   throws stays as it is.
/// - [onDone] runs after every job, success or failure, so a bar's
///   `onDone: bar.tick` tear-off fits.
///
/// A held `Pool(limit: n)` is the same limit across calls that start at
/// different times (a download queue fed by several crawlers): [run] waits
/// for one of its `n` lanes. Nothing to close: an idle pool holds nothing.
final class Pool {
  /// [limit] lanes shared by every [run] on this pool (4 by default).
  Pool({int limit = 4}) : _free = limit {
    if (limit < 1) throw ArgumentError.value(limit, 'limit', 'must be at least 1');
  }

  int _free;
  final _waiting = Queue<Completer<void>>();

  /// Run [job] once a lane is free, first come first served, and return
  /// what it returns (or rethrow what it throws). The lane is freed either way.
  Future<R> run<R>(FutureOr<R> Function() job) async {
    if (_free > 0) {
      _free--;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    try {
      return await job();
    } finally {
      // Hand the lane straight to the next waiter, so a newcomer cannot jump the queue.
      _waiting.isEmpty ? _free++ : _waiting.removeFirst().complete();
    }
  }

  /// Run [job] over every item, results in input order. The first error
  /// stops new jobs, waits for those in flight, and is rethrown with its
  /// original type and stack.
  static Future<List<R>> map<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? limit,
    int retries = 0,
    Rate? rate,
    bool isolates = false,
    void Function()? onDone,
  }) async {
    final out = await _run(items, job, limit, retries, rate, isolates, onDone, failFast: true);
    return [
      for (final o in out)
        switch (o) {
          Done(:final value) => value,
          Failed(:final error, :final stack) => Error.throwWithStackTrace(error, stack),
        },
    ];
  }

  /// Run [job] over every item and never throw: one [Outcome] per item, in
  /// input order, each carrying its item, because "which one failed" is the
  /// first question.
  static Future<List<Outcome<T, R>>> settle<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job, {
    int? limit,
    int retries = 0,
    Rate? rate,
    bool isolates = false,
    void Function()? onDone,
  }) => _run(items, job, limit, retries, rate, isolates, onDone, failFast: false);

  static Future<List<Outcome<T, R>>> _run<T, R>(
    Iterable<T> items,
    FutureOr<R> Function(T item) job,
    int? limit,
    int retries,
    Rate? pace,
    bool isolates,
    void Function()? onDone, {
    required bool failFast,
  }) async {
    final list = items.toList();
    if (list.isEmpty) return []; // before the checks: `limit: items.length` is fine on an empty batch
    if (limit != null && limit < 1) throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    if (retries < 0) throw ArgumentError.value(retries, 'retries', 'must not be negative');
    final width = (limit ?? (isolates ? io.Platform.numberOfProcessors : 4)).clamp(1, list.length);
    final out = List<Outcome<T, R>?>.filled(list.length, null);
    final workers = <_Worker>[];
    var next = 0;
    var failed = false;
    // Fail-fast ends the other lanes' rate waits and backoffs at once.
    final halt = rate.Halt();

    Future<void> lane() async {
      _Worker? worker;
      while (!(failFast && failed)) {
        final i = next++;
        if (i >= list.length) return;
        final item = list[i];
        Outcome<T, R> result;
        try {
          for (var attempt = 0; ; attempt++) {
            if (pace != null) await rate.take(pace, failFast ? halt : null);
            if (failFast && failed) return; // the map throws the first failure
            try {
              final R value;
              if (isolates) {
                final w = worker ??= await _Worker.start(job);
                if (workers.isEmpty || !identical(workers.last, w)) workers.add(w);
                value = await w.run(item, i) as R;
              } else {
                value = await job(item);
              }
              result = Done._(item, value);
              break;
            } on _Unsendable {
              rethrow;
            } catch (e) {
              if (worker?.dead ?? false) worker = null; // the next attempt or item gets a fresh one
              // A bug, bad data or a status: running it again cannot help.
              if (attempt >= retries || (failFast && failed) || retry.isPermanent(e)) rethrow;
              await rate.sleep(retry.backoff(attempt, null), failFast ? halt : null);
              if (failFast && failed) rethrow;
            }
          }
        } on _Unsendable catch (e, st) {
          result = Failed._(item, e.error, st);
        } catch (e, st) {
          result = Failed._(item, e, st);
        }
        out[i] = result;
        if (result is Failed) {
          failed = true;
          if (failFast) halt.fire();
        }
        onDone?.call();
      }
    }

    try {
      await Future.wait([for (var k = 0; k < width; k++) lane()]);
    } finally {
      for (final w in workers.toSet()) {
        w.stop();
      }
    }
    if (failFast) {
      final first = out.whereType<Failed<T, R>>().firstOrNull;
      if (first != null) Error.throwWithStackTrace(first.error, first.stack);
    }
    return [for (final o in out) o!];
  }
}

/// What one item came to: [Done] or [Failed].
sealed class Outcome<T, R> {
  const Outcome._(this.item);

  /// The item the job ran on.
  final T item;
}

/// A job that returned [value].
final class Done<T, R> extends Outcome<T, R> {
  const Done._(super.item, this.value) : super._();

  /// What the job returned.
  final R value;
}

/// A job that threw [error] (after its retries).
final class Failed<T, R> extends Outcome<T, R> {
  const Failed._(super.item, this.error, this.stack) : super._();

  /// What the last attempt threw.
  final Object error;

  /// Where it was thrown.
  final StackTrace stack;
}

/// `outcomes.values()`, `outcomes.failures()`.
extension Outcomes<T, R> on List<Outcome<T, R>> {
  /// The values of the jobs that succeeded, in input order.
  List<R> values() => [
    for (final o in this)
      if (o case Done(:final value)) value,
  ];

  /// The jobs that failed, in input order.
  List<Failed<T, R>> failures() => whereType<Failed<T, R>>().toList();
}

/// A value that cannot cross to or from a worker isolate.
final class _Unsendable {
  _Unsendable(this.error);

  final ArgumentError error;
}

/// One long-lived worker isolate: receives the job once, then items.
final class _Worker {
  _Worker._(this._isolate, this._send, this._replies);

  final Isolate _isolate;
  final SendPort _send;
  final StreamIterator<Object?> _replies;

  /// The isolate died (an uncaught async error, `Isolate.exit`).
  var dead = false;

  static Future<_Worker> start<T, R>(FutureOr<R> Function(T item) job) async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    Isolate isolate;
    try {
      // Its exit and uncaught errors arrive on the reply port too, so a
      // worker that dies fails its item instead of hanging the pool.
      isolate = await Isolate.spawn(
        _main,
        (port.sendPort, (Object? item) => job(item as T)),
        onExit: port.sendPort,
        onError: port.sendPort,
      );
    } on ArgumentError catch (e) {
      port.close();
      throw _Unsendable(ArgumentError.value(job, 'job', 'cannot be sent to a worker isolate (${e.message})'));
    }
    if (!await replies.moveNext() || replies.current is! SendPort) {
      port.close();
      throw RemoteError('worker isolate died while starting', '');
    }
    return _Worker._(isolate, replies.current! as SendPort, replies);
  }

  Future<Object?> run(Object? item, int index) async {
    try {
      _send.send(item);
    } on ArgumentError catch (e) {
      throw _Unsendable(
        ArgumentError.value(item, 'items[$index]', 'cannot be sent to a worker isolate (${e.message})'),
      );
    }
    final reply = await _replies.moveNext() ? _replies.current : null;
    if (reply is! List<Object?> || reply[0] is String) {
      // null: the isolate exited; [error, stack] strings: it died of an
      // uncaught error outside the job's own future.
      dead = true;
      throw reply is List<Object?>
          ? RemoteError(reply[0]! as String, (reply[1] as String?) ?? '')
          : RemoteError('worker isolate exited while running items[$index]', '');
    }
    if (reply[0] == true) return reply[1];
    final error = reply[1]!;
    final stack = StackTrace.fromString(reply[2]! as String);
    if (reply.length > 3) {
      throw _Unsendable(ArgumentError.value(item, 'items[$index]', 'result cannot be sent back ($error)'));
    }
    Error.throwWithStackTrace(error, stack);
  }

  void stop() {
    _isolate.kill(priority: Isolate.immediate);
    unawaited(_replies.cancel());
  }
}

/// The worker loop: hand back its port, then answer each item with
/// `[true, value]` or `[false, error, stack]` (a [RemoteError] when the
/// error itself cannot cross; a fourth entry marks an unsendable result).
Future<void> _main((SendPort, FutureOr<Object?> Function(Object? item)) start) async {
  final (reply, job) = start;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  await for (final item in inbox) {
    Object? value;
    try {
      value = await job(item);
    } catch (e, st) {
      try {
        reply.send([false, e, '$st']);
      } on ArgumentError {
        reply.send([false, RemoteError('$e', '$st'), '$st']);
      }
      continue;
    }
    try {
      reply.send([true, value]);
    } on ArgumentError catch (e) {
      reply.send([false, '${e.message}', '', true]);
    }
  }
}
