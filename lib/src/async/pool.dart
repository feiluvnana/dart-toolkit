import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

/// Up to [concurrency] persistent worker isolates, spawned on demand and reused.
///
/// ```dart
/// final pool = Pool(4);
/// final squares = await pool.map([1, 2, 3], (n) => n * n);
/// await pool.close();
/// ```
///
/// Isolates are spawned lazily, up to [concurrency], and reused across jobs
/// — no per-task spawn cost. One that dies is replaced on next use.
final class Pool {
  /// How many jobs may run at once.
  final int concurrency;

  final List<_Handle> _handles = [];
  final ListQueue<_Pending<dynamic>> _queue = ListQueue<_Pending<dynamic>>();
  final Map<int, _Pending<dynamic>> _flying = {};
  int _jobSeq = 0;
  int _active = 0;
  bool _closed = false;
  final List<Completer<void>> _drained = [];

  Pool(this.concurrency) {
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency', 'Must be at least 1');
  }

  /// Runs [fn] on the next free isolate. [fn] is sent over; it must be a top-level or static
  /// function, or a closure over sendable values only (rule 52).
  Future<T> run<T>(FutureOr<T> Function() fn) {
    if (_closed) throw StateError('Pool is closed');
    final pending = _Pending<T>(_jobSeq++, fn);
    _queue.add(pending);
    _pump();
    return pending.completer.future;
  }

  /// [fn] over every item, values in input order.
  Future<List<T>> map<I, T>(Iterable<I> items, FutureOr<T> Function(I item) fn) =>
      Future.wait([for (final item in items) run(() => fn(item))]);

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
      final pending = _queue.removeFirst();
      _active++;
      _assign(pending).then((_) {}, onError: (_) {});
    }
  }

  Future<void> _assign(_Pending<dynamic> pending) async {
    _Handle? handle;
    try {
      handle = await _takeHandle();
    } catch (e, st) {
      _finish(pending, null, e, st);
      return;
    }
    _flying[pending.id] = pending;
    pending.handle = handle;
    try {
      handle.jobs.send([pending.id, pending.fn]);
    } catch (e, st) {
      _flying.remove(pending.id);
      _dropHandle(handle);
      _finish(pending, null, e, st);
    }
  }

  Future<_Handle> _takeHandle() async {
    for (final h in _handles) {
      if (!h.busy && !h.dead) {
        h.busy = true;
        return h;
      }
    }
    final h = await _Handle.spawn();
    h.busy = true;
    h.onMessage = _onReply;
    h.onExit = () => _onGone(h);
    _handles.add(h);
    return h;
  }

  void _onReply(List<Object?> msg) {
    final id = msg[0] as int;
    final pending = _flying.remove(id);
    if (pending == null) return;
    pending.handle?.busy = false;
    if (msg.length == 2) {
      _finish(pending, msg[1], null, null);
    } else {
      final err = msg[1];
      final stack = msg[2] is StackTrace ? msg[2] as StackTrace : StackTrace.empty;
      _finish(pending, null, err is Object ? err : StateError('$err'), stack);
    }
  }

  void _onGone(_Handle handle) {
    handle.dead = true;
    // Release its ports at once: a dead worker's open ports keep the script
    // alive past close().
    handle.dispose();
    // Fail anything it was running; the next pump replaces it.
    for (final entry in _flying.entries.toList()) {
      if (identical(entry.value.handle, handle)) {
        _flying.remove(entry.key);
        _finish(entry.value, null, StateError('pool isolate exited'), null);
      }
    }
    _handles.remove(handle);
  }

  void _dropHandle(_Handle handle) {
    handle.dead = true;
    handle.dispose();
    _handles.remove(handle);
  }

  void _finish(_Pending<dynamic> pending, Object? value, Object? error, StackTrace? stack) {
    _active--;
    if (error == null) {
      pending.completer.complete(value);
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

final class _Pending<T> {
  final int id;
  final FutureOr<T> Function() fn;
  final Completer<T> completer = Completer<T>();
  _Handle? handle;

  _Pending(this.id, this.fn);
}

typedef _MessageFn = void Function(List<Object?> msg);

final class _Handle {
  final Isolate isolate;
  final SendPort jobs;
  final ReceivePort answers;
  bool busy = false;
  bool dead = false;
  _MessageFn? onMessage;
  void Function()? onExit;

  _Handle._(this.isolate, this.jobs, this.answers);

  static Future<_Handle> spawn() async {
    final answers = ReceivePort();
    final ready = Completer<SendPort>();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn(_workerEntry, answers.sendPort, debugName: 'pool-worker');
    isolate.addOnExitListener(exitPort.sendPort);
    _Handle? handle;
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
      handle = _Handle._(isolate, jobs, answers);
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
  var _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
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

/// A pool worker: runs `(id, fn)` jobs, answering `(id, value)` or
/// `(id, error, stack)`. Unsendable values fall back to strings, so every job
/// gets exactly one answer.
void _workerEntry(SendPort main) async {
  final jobs = ReceivePort();
  main.send(_Ready(jobs.sendPort));
  await for (final msg in jobs) {
    if (msg == null) {
      jobs.close();
      return;
    }
    final list = (msg as List).cast<Object?>();
    final id = list[0] as int;
    final fn = list[1] as FutureOr<Object?> Function();
    try {
      final value = await fn();
      try {
        main.send([id, value]);
      } catch (_) {
        main.send([id, StateError('Pool value is not sendable across isolates'), StackTrace.empty]);
      }
    } catch (e, st) {
      try {
        main.send([id, e, st]);
      } catch (_) {
        main.send([id, '$e', '']);
      }
    }
  }
}
