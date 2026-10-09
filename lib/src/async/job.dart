part of '../async.dart';

/// One item a [Pool] keeps: a [Task] of its value you can also [pause], [resume] and [remove].
///
/// Its statuses are the ordinary ones: [Waiting] for a worker, [Running] as the worker reports
/// (a task the worker returns or awaits reports for it), [Paused], then [Done], [Failed] or
/// [Stopped]. Awaiting it waits for its current run: [resume] after a failure starts a new one.
/// A failure is never an unhandled error: the pool holds it, in [Pool.jobs] and [Pool.changes].
/// A bug (an [Error] its worker threw) is one too, where the job was added.
///
/// ```dart
/// final job = pool.add(url);
/// job.pause(); job.resume();
/// await job;                    // the value, or why it failed
/// ```
///
/// A detached job ([isDetached]) runs in the pool's runner process and outlives this program;
/// this one only shows it, and its controls are sent there.
///
/// {@category Concurrency}
final class Job<I, T> implements Task<T> {
  /// Its name: what the pool's store knows it by.
  final String id;

  @override
  final I item;

  /// Whether it runs in the pool's runner process, outliving this program.
  final bool isDetached;

  final Pool<I, T> _pool;

  /// Where it was added: its runs read that place's scopes and stop with its cancel.
  final Zone _zone;

  late Status<I, T> _status = Waiting(item);
  late Completer<T> _done = _outcome();
  Completer<Status<I, T>> _end = Completer();
  final _listeners = <StreamController<Status<I, T>>>[];
  final _warnings = <Warned<I, T>>[];

  /// The run under way, and the token of its wait for a worker.
  Task<T>? _run;
  CancelToken? _waiting;

  /// Why it is being stopped: `'paused'` to pause, anything else to end it.
  String? _stopping;

  /// Whether [remove] forgot it.
  bool _removed = false;

  Job._(this._pool, this.id, this.item, {required this.isDetached}) : _zone = Zone.current;

  static Completer<T> _outcome<T>() {
    final done = Completer<T>();
    // The pool holds what happened to it: a failure nobody awaits is no unhandled error.
    done.future.ignore();
    return done;
  }

  @override
  String get label => _status.label;

  @override
  Status<I, T> get status => _status;

  @override
  Stream<Status<I, T>> get statuses {
    late final StreamController<Status<I, T>> controller;
    controller = StreamController(
      onListen: () {
        _warnings.forEach(controller.add);
        controller.add(_status);
        if (_status.isFinal) {
          controller.close();
        } else {
          _listeners.add(controller);
        }
      },
      onCancel: () => _listeners.remove(controller),
    );
    return controller.stream;
  }

  @override
  Future<Status<I, T>> get settled => _end.future;

  /// Whether its controls go to the runner rather than act here.
  bool get _remote => isDetached && !_pool._isRunner;

  /// Stops it where it is: its run is cancelled (its cleanups see `work.ended` as a `Stopped`
  /// with reason `'paused'`), and it is [Paused] until [resume]. A finished job stays as it is.
  void pause() {
    if (_remote) return _pool._link?.send({'pause': id});
    if (_status is! Waiting && _status is! Running) return;
    _stopping = Stopped.paused;
    _waiting?.cancel(Stopped.paused);
    _run?.cancel(Stopped.paused);
  }

  /// Runs it again: after a [pause], or a [Failed]. Anything else stays as it is.
  void resume() {
    if (_remote) return _pool._link?.send({'resume': id});
    if (_status is! Paused && _status is! Failed) return;
    if (_pool._closing != null) throw StateError('Cannot resume $label: its pool is closed');
    _pool._unfinished[item] ??= this; // unfinished again: an equal item added now gives this job
    _pool._start(this);
  }

  /// Stops it if it runs (it ends [Stopped], its cleanups run), and the pool forgets it. A
  /// finished job keeps its outcome.
  void remove() {
    if (_remote) return _pool._link?.send({'remove': id});
    if (_removed) return;
    _removed = true;
    _pool._forget(this);
    _halt(Stopped.removed);
  }

  /// Stops it: it ends [Stopped], and stays in [Pool.jobs] until removed.
  @override
  void cancel([String reason = 'cancelled']) {
    if (_remote) return _pool._link?.send({'cancel': id, 'reason': reason});
    _halt(reason);
  }

  void _halt(String reason) {
    if (_status.isFinal) return _pool._changed(this);
    _stopping = reason;
    if (_status is Paused) return _finish(Stopped(item, reason, label: label));
    _waiting?.cancel(reason);
    _run?.cancel(reason);
  }

  /// Runs it: waits for a worker, then runs the item on it.
  Future<void> _go() async {
    final token = _waiting = CancelToken();
    _stopping = null;
    _set(Waiting(item, label: label));
    final _Lane<I, T> lane;
    try {
      lane = await Cancel.scope(_pool._lanes.take, token: token);
    } on CancelledException catch (e) {
      _waiting = null;
      return _stopped(e.reason);
    } catch (e, st) {
      // A worker that could not start: its init's failure is the job's.
      _waiting = null;
      return _finish(Failed(item, e, st, label: label));
    }
    _waiting = null;
    if (token.isCancelled) {
      _pool._lanes.give(lane);
      return _stopped(_stopping ?? 'cancelled');
    }
    final run = _run = TaskInternals.start(item, label, (work) => lane.run(item, work));
    final heard = run.statuses.listen((status) {
      if (!status.isFinal) _set(StatusInternals.about(status, item));
    });
    final outcome = await run.settled;
    await heard.cancel();
    _pool._lanes.give(lane);
    _run = null;
    switch (outcome) {
      case Done(:final value, :final fresh):
        if (_pool._isRunner) {
          // A value that cannot reach the program that waits for it is the job's failure.
          try {
            _pool._codec.value(value);
          } on ArgumentError catch (e, st) {
            return _finish(Failed(item, e, st, label: label));
          }
        }
        _finish(Done(item, value, fresh: fresh, label: label));
      case Failed(:final error, :final stackTrace):
        _finish(Failed(item, error, stackTrace, label: label));
      case Stopped(:final reason):
        _stopped(reason);
      case _:
    }
  }

  /// Its run stopped for [reason]: a pause, or its end.
  void _stopped(String reason) {
    final why = _stopping ?? reason;
    _stopping = null;
    if (why == Stopped.paused) return _set(Paused(item, label: label));
    _finish(Stopped(item, why, label: label));
  }

  /// [status], a step on the way: a [Warned] is a note, the rest its status now.
  void _set(Status<I, T> status) {
    if (status case final Warned<I, T> warned) {
      if (_warnings.length < 100) _warnings.add(warned);
    } else {
      // A failed job that runs again is a new run: a new outcome to await.
      if (_status is Failed && !status.isFinal) {
        _done = _outcome();
        _end = Completer();
        _warnings.clear();
      }
      _status = status;
    }
    for (final listener in [..._listeners]) {
      listener.add(status);
    }
    _pool._changed(this, note: status is Warned<I, T> ? status : null);
  }

  /// How its run ended: [status], a [Done], [Failed] or [Stopped].
  void _finish(Status<I, T> status) {
    if (_status is Failed && status is! Failed) {
      _done = _outcome();
      _end = Completer();
    }
    _status = status;
    for (final listener in [..._listeners]) {
      listener
        ..add(status)
        ..close();
    }
    _listeners.clear();
    if (!_end.isCompleted) {
      _end.complete(status);
      switch (status) {
        case Done(:final value):
          _done.complete(value);
        case Failed(:final error, :final stackTrace):
          _done.completeError(error, stackTrace);
          // A bug is never only a status: it reaches the place the job was added, as an
          // unhandled error would.
          if (error is Error && !_remote) _zone.handleUncaughtError(error, stackTrace);
        case Stopped(:final reason):
          _done.completeError(CancelledException(reason));
        case _:
      }
    }
    _pool._changed(this, rest: true);
  }

  // ---- Future<T>: the current run's outcome

  @override
  Stream<T> asStream() => _done.future.asStream();

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) =>
      _done.future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) =>
      _done.future.then(onValue, onError: onError);

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      _done.future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) => _done.future.whenComplete(action);

  @override
  String toString() => 'Job($id, $_status${isDetached ? ', detached' : ''})';
}
