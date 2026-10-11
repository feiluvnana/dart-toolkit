import 'dart:async';
import 'dart:isolate';

import 'worker.dart';

/// A fixed-size pool of persistent worker isolates for high-throughput work.
///
/// ```dart
/// final pool = Pool(Upper.new, concurrency: 4);
/// final out = await pool.run('hello');
/// final many = await pool.map(['a', 'b', 'c']);
/// await pool.wait();
/// await pool.close();
/// ```
///
/// Workers are spawned lazily, up to [concurrency], and reused across jobs —
/// no per-task spawn cost. An equal unfinished item shares its job: two
/// [run] calls with the same item answer the same future. A worker that dies
/// is replaced on next use; an unexpected `Error` from worker code ends its
/// job at once and is rethrown as-is (r14).
final class Pool<I, T> {
  /// How many jobs may run at once.
  final int concurrency;

  final Worker<I, T> Function() _create;

  final List<_Handle<I, T>> _handles = [];
  final List<_Pending<I, T>> _queue = [];
  final Map<I, Future<T>> _unfinished = {};
  final Map<int, _Pending<I, T>> _flying = {};
  int _jobSeq = 0;
  int _active = 0;
  bool _closed = false;
  final List<Completer<void>> _drained = [];

  Pool(this._create, {this.concurrency = 4}) {
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency', 'Must be at least 1');
  }

  /// Whether the pool has been closed.
  bool get isClosed => _closed;

  /// Queues [item] on the next free worker and answers its value.
  ///
  /// An equal item that has not finished gives the job it already has.
  Future<T> run(I item) {
    if (_closed) throw StateError('Pool is closed');
    if (_unfinished[item] case final existing?) return existing;
    final pending = _Pending<I, T>(_jobSeq++, item);
    _unfinished[item] = pending.completer.future;
    _queue.add(pending);
    _pump();
    return pending.completer.future;
  }

  /// Every [items] entry through the workers, answering values in input order.
  Future<List<T>> map(Iterable<I> items) => Future.wait([for (final item in items) run(item)]);

  /// Waits until every queued and running job has finished.
  Future<void> wait() {
    if (_active == 0 && _queue.isEmpty) return Future<void>.value();
    final c = Completer<void>();
    _drained.add(c);
    return c.future;
  }

  /// Waits for the pool to drain and refuses further [run] calls.
  Future<void> close() async {
    if (_closed) return;
    await wait();
    _closed = true;
    for (final h in _handles) {
      h.dispose();
    }
    _handles.clear();
  }

  void _pump() {
    while (_active < concurrency && _queue.isNotEmpty) {
      final pending = _queue.removeAt(0);
      _active++;
      _assign(pending).then((_) {}, onError: (_) {});
    }
  }

  Future<void> _assign(_Pending<I, T> pending) async {
    _Handle<I, T>? handle;
    try {
      handle = await _takeHandle();
    } catch (e, st) {
      _finish(pending, null, e, st);
      return;
    }
    _flying[pending.id] = pending;
    pending.handle = handle;
    try {
      handle.jobs.send([pending.id, pending.item]);
    } catch (e, st) {
      _flying.remove(pending.id);
      _dropHandle(handle);
      _finish(pending, null, e, st);
    }
  }

  Future<_Handle<I, T>> _takeHandle() async {
    for (final h in _handles) {
      if (!h.busy && !h.dead) {
        h.busy = true;
        return h;
      }
    }
    if (_handles.length < concurrency) {
      final h = await _Handle.spawn(_create);
      h.busy = true;
      h.onMessage = _onWorkerMessage;
      h.onExit = () => _onWorkerExit(h);
      _handles.add(h);
      return h;
    }
    // All handles busy but _active < concurrency only when a handle died
    // while jobs were flying: replace it.
    final h = await _Handle.spawn(_create);
    h.busy = true;
    h.onMessage = _onWorkerMessage;
    h.onExit = () => _onWorkerExit(h);
    _handles.add(h);
    return h;
  }

  void _onWorkerMessage(List<Object?> msg) {
    final id = msg[0] as int;
    final ok = msg[1] as bool;
    final payload = msg[2];
    final pending = _flying.remove(id);
    if (pending == null) return;
    final handle = pending.handle;
    if (handle != null) {
      handle.busy = false;
    }
    if (ok) {
      _finish(pending, payload as T?, null, null);
    } else {
      final err = payload;
      _finish(pending, null, err is Object ? err : StateError('$err'), null);
    }
  }

  void _onWorkerExit(_Handle<I, T> handle) {
    handle.dead = true;
    // Fail anything it was running; the next pump replaces it.
    for (final entry in _flying.entries.toList()) {
      if (identical(entry.value.handle, handle)) {
        _flying.remove(entry.key);
        _finish(entry.value, null, StateError('Worker isolate exited'), null);
      }
    }
    _handles.remove(handle);
  }

  void _dropHandle(_Handle<I, T> handle) {
    handle.dead = true;
    handle.dispose();
    _handles.remove(handle);
  }

  void _finish(_Pending<I, T> pending, T? value, Object? error, StackTrace? stack) {
    _active--;
    _unfinished.remove(pending.item);
    if (error == null) {
      pending.completer.complete(value as T);
    } else {
      if (error is Error) {
        pending.completer.completeError(error, stack ?? StackTrace.empty);
      } else {
        pending.completer.completeError(error, stack);
      }
    }
    if (_active == 0 && _queue.isEmpty) {
      for (final c in _drained) {
        c.complete();
      }
      _drained.clear();
    }
    _pump();
  }
}

final class _Pending<I, T> {
  final int id;
  final I item;
  final Completer<T> completer = Completer<T>();
  _Handle<I, T>? handle;

  _Pending(this.id, this.item);
}

typedef _MessageFn = void Function(List<Object?> msg);

final class _Handle<I, T> {
  final Isolate isolate;
  final SendPort jobs;
  final ReceivePort answers;
  bool busy = false;
  bool dead = false;
  _MessageFn? onMessage;
  void Function()? onExit;

  _Handle._(this.isolate, this.jobs, this.answers);

  static Future<_Handle<I, T>> spawn<I, T>(Worker<I, T> Function() create) async {
    final answers = ReceivePort();
    final ready = Completer<SendPort>();
    final exitPort = ReceivePort();
    late Isolate isolate;
    try {
      isolate = await Isolate.spawn(_workerEntry<I, T>, [answers.sendPort, create], debugName: 'pool-worker');
    } on ArgumentError {
      answers.close();
      exitPort.close();
      throw ArgumentError.value(create, 'create', 'Pool needs a top-level or static worker factory (r58)');
    }
    isolate.addOnExitListener(exitPort.sendPort);
    _Handle<I, T>? handle;
    final sub = answers.listen((msg) {
      if (msg is _Ready) {
        ready.complete(msg.jobs);
        return;
      }
      handle?.onMessage?.call((msg as List).cast<Object?>());
    });
    exitPort.listen((_) {
      handle?.dead = true;
      handle?.onExit?.call();
    });
    try {
      final jobs = await ready.future;
      handle = _Handle<I, T>._(isolate, jobs, answers);
      // Keep the subscription alive on the handle so it is not cancelled.
      handle._sub = sub;
      handle._exit = exitPort;
      return handle;
    } catch (e) {
      await sub.cancel();
      answers.close();
      exitPort.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  StreamSubscription<dynamic>? _sub;
  ReceivePort? _exit;

  void dispose() {
    try {
      jobs.send(null);
    } catch (_) {
      // Already gone: kill below.
    }
    isolate.kill(priority: Isolate.immediate);
    _sub?.cancel();
    answers.close();
    _exit?.close();
  }
}

final class _Ready {
  final SendPort jobs;
  _Ready(this.jobs);
}

void _workerEntry<I, T>(List<Object?> args) async {
  final main = args[0] as SendPort;
  final create = args[1] as Worker<I, T> Function();
  final Worker<I, T> worker;
  try {
    worker = create();
    await worker.init();
  } catch (e) {
    // Init failed: no job port; tell the pool by closing without _Ready
    // (its spawn waits on _Ready and times out at the caller). Send the
    // error first so a racing listener can surface it, then exit.
    try {
      main.send([0, false, e]);
    } catch (_) {
      // Not sendable: send its text instead.
      main.send([0, false, '$e']);
    }
    return;
  }
  final jobs = ReceivePort();
  main.send(_Ready(jobs.sendPort));
  await for (final msg in jobs) {
    if (msg == null) {
      jobs.close();
      return;
    }
    final list = (msg as List).cast<Object?>();
    final id = list[0] as int;
    final item = list[1] as I;
    try {
      final value = await worker.run(item);
      try {
        main.send([id, true, value]);
      } catch (_) {
        main.send([id, false, StateError('Worker value is not sendable across isolates')]);
      }
    } catch (e) {
      try {
        main.send([id, false, e]);
      } catch (_) {
        main.send([id, false, '$e']);
      }
    }
  }
}
