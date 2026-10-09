part of '../base.dart';

const _sinkKey = #dartToolkitWork;

/// How many warnings a task or batch keeps for a listener that comes late.
const _keptWarnings = 100;

/// How long a cancelled body has to stop on its own before its task ends without it.
const _grace = Duration(seconds: 1);

/// One piece of work that ends in one value. It *is* a `Future<T>`: awaiting it gives the value
/// or throws why it could not; on top of that it reports its [status] as it goes.
///
/// It starts at once. [statuses] gives the current status first, so a display attached a
/// moment later misses nothing; `show(title)` (in `cli`) draws it while you await it.
///
/// ```dart
/// final file = await url.download(into: 'out');           // a Path, or it throws
/// switch (await url.download(into: 'out').settled) {      // or look without throwing
///   case Done(:final value): print('saved $value');
///   case Failed(:final error): print('no: $error');
///   case _:
/// }
/// ```
///
/// A task made while another work's body runs is part of that work: its progress and warnings
/// show as that work's, so `return url.download(…)` from a worker shows the download.
///
/// {@category Concurrency}
abstract interface class Task<T> implements Future<T> {
  /// What it is about: the URL, the file, the label of [Task.run].
  Object? get item;

  /// How a display names it.
  String get label;

  /// What it is doing now: [Running] until it ends, then [Done], [Failed] or [Stopped].
  Status<Object?, T> get status;

  /// The warnings so far and the current status, then every change and every [Warned] note; it
  /// ends when the task does.
  Stream<Status<Object?, T>> get statuses;

  /// How it ended: [Done], [Failed] or [Stopped]. Never throws.
  Future<Status<Object?, T>> get settled;

  /// Stops it: its work is cancelled, its cleanups run, it ends [Stopped], and awaiting it throws
  /// a [CancelledException] with [reason]. Work that does not stop on its own within a second is
  /// left to finish unheard.
  void cancel([String reason = 'cancelled']);

  /// A task of your own: [body] runs at once with a [Work] to report progress and defer cleanup
  /// on, inside a [Cancel.scope] that [cancel] cancels.
  ///
  /// ```dart
  /// final task = Task.run('Render', (work) async {
  ///   final chrome = await Chrome.launch();
  ///   work.defer(chrome.close);                 // always runs, however the task ends
  ///   work.step('rendering');
  ///   return render(chrome);
  /// });
  /// ```
  static Task<T> run<T>(String label, FutureOr<T> Function(Work work) body) => _Task<T>(label, label, body);
}

/// What every body you write is handed, to report progress and to clean up: the body of
/// [Task.run], a `Worker`'s `init` and `run`, a crawl hook's context, a `Cli` handler's context.
///
/// {@category Concurrency}
abstract interface class Work {
  /// [received] of [total] so far, in [unit].
  void amount(int received, {int? total, Unit unit = Unit.bytes});

  /// What it is on now: `'verifying'`, `'finding a server'`.
  void step(String phrase);

  /// A note worth a line, which does not change the outcome.
  void warn(String note);

  /// Runs [cleanup] when the work ends, however it ends: done, failed, stopped. Cleanups run
  /// once, last deferred first; awaiting the work returns after them. One that throws is a
  /// [Warned] note, never the outcome.
  void defer(FutureOr<void> Function() cleanup);

  /// Inside a deferred cleanup, how the work ended; `null` while it runs.
  Status<Object?, Object?>? get ended;

  /// Whether the work has been asked to stop: the same as [Cancel.isCancelled] inside it.
  bool get isStopped;
}

/// Where reports from work inside a body go: a [_Task], a batch's item, a pool's job.
abstract class _Sink {
  /// [status] (a [Running] or a [Warned]) from work inside this one.
  void _child(Status<Object?, Object?> status);

  /// A task inside this one ended with [done].
  void _childDone(Done<Object?, Object?> done);
}

/// The value the last child task finished with when it was not fresh: a body that hands back
/// what a stale child made is stale too. A fresh child's value is not kept: the work may hold on
/// to this sink long after, and the value (a response, a file's bytes) is not its own.
mixin _Freshness on _Sink {
  Object? _staleValue;
  bool _hasStale = false;

  @override
  void _childDone(Done<Object?, Object?> done) {
    _hasStale = !done.fresh;
    _staleValue = _hasStale ? done.value : null;
  }

  /// Whether [value], this work's own, is fresh.
  bool _freshFor(Object? value, bool own) => own && !(_hasStale && identical(value, _staleValue));
}

final class _Task<T> extends _Sink with _Freshness, _Awaitable<T> implements Task<T> {
  @override
  final Object? item;
  @override
  final String label;

  /// The work this task is part of: its reports go there too.
  final _Sink? _parent = Zone.current[_sinkKey] as _Sink?;

  final _done = Completer<T>();
  final _end = Completer<Status<Object?, T>>();
  final _listeners = <StreamController<Status<Object?, T>>>[];
  final _warnings = <Warned<Object?, T>>[];
  final _cleanups = <FutureOr<void> Function()>[];
  final _token = CancelToken();
  late final _TaskWork<T> _work = _TaskWork(this);
  late Status<Object?, T> _status = Running(item, label: label, unit: Unit.none);
  Status<Object?, T>? _final;
  bool _fresh = true;

  _Task(this.item, this.label, FutureOr<T> Function(Work work) body) {
    _start(body);
  }

  @override
  Status<Object?, T> get status => _status;

  @override
  // Listening while the cleanups run still hears their warnings and the end.
  Stream<Status<Object?, T>> get statuses =>
      _replaying(() => [..._warnings, _status], () => _end.isCompleted, _listeners);

  @override
  Future<Status<Object?, T>> get settled {
    // Whoever reads the outcome this way has handled it.
    _done.future.ignore();
    return _end.future;
  }

  @override
  void cancel([String reason = 'cancelled']) => _token.cancel(reason);

  void _start(FutureOr<T> Function(Work work) body) {
    final outer = Cancel.token;
    final unlink = outer?.onCancel(() => _token.cancel(outer.reason));
    _whenReady(_attempt<T>(() => body(_work), token: _token, sink: this, subject: label), (outcome) {
      unlink?.call();
      _finish(switch (outcome) {
        _Value(:final value) => Done(item, value, label: label, fresh: _freshFor(value, _fresh)),
        _Error(:final error, :final stackTrace) => Failed(item, error, stackTrace, label: label),
        _Stop(:final reason) => Stopped(item, reason, label: label),
      });
    });
  }

  void _finish(Status<Object?, T> status) {
    _final = status;
    // Most work defers nothing: it ends at once, with no turn of the event loop spent.
    if (_cleanups.isEmpty) return _ended(status);
    // Cleanups run whatever stopped the work: a cancel around it does not reach them, and what
    // they start is still this task's part.
    CancelInternals.run(() => _runCleanups(_cleanups, status, _warned), CancelToken(), {
      _sinkKey: this,
    }).then((_) => _ended(status));
  }

  void _ended(Status<Object?, T> status) {
    _status = status;
    for (final listener in [..._listeners]) {
      listener
        ..add(status)
        ..close();
    }
    _listeners.clear();
    if (status is Done<Object?, T>) _parent?._childDone(status);
    _end.complete(status);
    switch (status) {
      case Done(:final value):
        _done.complete(value);
      case Failed(:final error, :final stackTrace):
        _done.completeError(error, stackTrace);
      case Stopped(:final reason):
        // A stop is no news: it is never an unhandled error.
        _done.future.ignore();
        _done.completeError(CancelledException(reason));
      case _:
    }
  }

  void _report(Status<Object?, T> status) {
    if (_final != null) return;
    _status = status;
    for (final listener in _listeners) {
      listener.add(status);
    }
    _parent?._child(status);
  }

  void _warned(Warning warning) {
    final status = Warned<Object?, T>(item, warning, label: label);
    if (_warnings.length < _keptWarnings) _warnings.add(status);
    for (final listener in _listeners) {
      listener.add(status);
    }
    _parent?._child(status);
  }

  @override
  void _child(Status<Object?, Object?> status) {
    if (_final != null) return;
    switch (status) {
      case Warned(:final warning):
        _warned(warning);
      case Running(:final received, :final total, :final unit, :final step):
        // The latest report is what the work is on, whether its own or a part's.
        _report(Running(item, label: label, received: received, total: total, unit: unit, step: step));
      case _:
    }
  }

  @override
  Future<T> get _future => _done.future;

  @override
  String get _subject => label;

  @override
  String toString() => 'Task($label, $_status)';
}

final class _TaskWork<T> extends _BaseWork {
  final _Task<T> _task;
  int _received = 0;
  int? _total;
  Unit _unit = Unit.none;
  String? _step;

  _TaskWork(this._task);

  @override
  void amount(int received, {int? total, Unit unit = Unit.bytes}) {
    _received = received;
    _total = total;
    _unit = unit;
    _send();
  }

  @override
  void step(String phrase) {
    _step = phrase;
    _send();
  }

  void _send() => _task._report(
    Running(_task.item, label: _task.label, received: _received, total: _total, unit: _unit, step: _step),
  );

  @override
  void warn(String note) => _task._warned(NoteWarning(note));

  @override
  void defer(FutureOr<void> Function() cleanup) {
    if (_task._final != null) throw StateError('Cannot defer a cleanup of ${_task.label}: it has ended');
    _task._cleanups.add(cleanup);
  }

  @override
  Status<Object?, Object?>? get ended => _task._final;

  @override
  bool get isStopped => _task._token.isCancelled;

  @override
  void _markStale() => _task._fresh = false;
}

/// A [Future] of [_future]'s outcome, timed out as a [Task] is: what is out of time is cancelled
/// (nobody waits for it) and the [TimeoutException] names [_subject].
mixin _Awaitable<T> implements Future<T> {
  Future<T> get _future;

  /// What a timeout names.
  String get _subject;

  void cancel([String reason = 'cancelled']);

  @override
  Stream<T> asStream() => _future.asStream();

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) =>
      _future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) =>
      _future.then(onValue, onError: onError);

  /// The value, or [onTimeout]'s (else a [TimeoutException] naming this work) if it takes
  /// longer than [timeLimit]. Either way work out of time is cancelled: nobody waits for it.
  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      _timeout(_future, timeLimit, onTimeout, cancel, _subject);

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) => _future.whenComplete(action);
}

/// [future] timed out as a [Task] is: out of time, the work is [cancel]led and the
/// [TimeoutException] names [subject].
Future<T> _timeout<T>(
  Future<T> future,
  Duration timeLimit,
  FutureOr<T> Function()? onTimeout,
  void Function([String reason]) cancel,
  String subject,
) => future.timeout(
  timeLimit,
  onTimeout: () {
    cancel('timed out after ${timeLimit.humanized}');
    if (onTimeout != null) return onTimeout();
    throw TimeoutBridge(subject, timeLimit);
  },
);

/// What every [Work] in this library can do beyond the interface.
abstract class _BaseWork implements Work {
  /// The value the body returns is not fresh: nothing had to be done.
  void _markStale();
}

/// Runs [cleanups] once each, last first, with [ended] as how the work ended; one that throws is
/// handed to [warn] and the rest still run.
Future<void> _runCleanups(
  List<FutureOr<void> Function()> cleanups,
  Status<Object?, Object?> ended,
  void Function(Warning warning) warn,
) async {
  while (cleanups.isNotEmpty) {
    final cleanup = cleanups.removeLast();
    try {
      await cleanup();
    } catch (e) {
      warn(NoteWarning('cleanup failed: $e'));
    }
  }
}

/// Not API: what other libraries' producers need from [Task] and [Work].
abstract final class TaskInternals {
  /// A task about [item] (a URL, a file) labelled [label], as [Task.run] makes one.
  static Task<T> start<T>(Object? item, String label, FutureOr<T> Function(Work work) body) =>
      _Task<T>(item, label, body);

  /// Marks the value [work]'s body returns as not fresh: nothing had to be done.
  static void stale(Work work) {
    if (work is _BaseWork) work._markStale();
  }

  /// Reports [warning] to the work around the caller, if there is one: how a retry loop deep in
  /// a library reaches the row of the work it serves.
  static void warn(Warning warning) {
    final sink = Zone.current[_sinkKey] as _Sink?;
    sink?._child(Warned<Object?, Object?>(null, warning));
  }

  /// Reports [status] (a [Running]) to the work around the caller, as a part of it.
  static void report(Running<Object?, Object?> status) {
    final sink = Zone.current[_sinkKey] as _Sink?;
    sink?._child(status);
  }

  /// [body] run with no work around it: what it starts is nobody's part.
  static R detached<R>(R Function() body) => runZoned(body, zoneValues: {_sinkKey: null});

  /// [future] timed out as a [Task]'s `timeout` is: out of time, [cancel] stops the work and the
  /// [TimeoutException] names [subject]. For a `Future` a module implements itself.
  static Future<T> timeout<T>(
    Future<T> future,
    Duration timeLimit,
    FutureOr<T> Function()? onTimeout, {
    required void Function([String reason]) cancel,
    required String subject,
  }) => _timeout(future, timeLimit, onTimeout, cancel, subject);
}
