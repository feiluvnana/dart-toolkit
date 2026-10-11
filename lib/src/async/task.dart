import 'dart:async';
import 'dart:isolate';

/// One-shot background work: [run], [all] and the long-running [bg].
///
/// ```dart
/// final hash = await Task.run(() => calcHash(buf));
/// final heavy = await Task.run(() => calcHash(buf), isolate: true);
/// final res  = await Task.run(() => slow(), timeout: const Duration(seconds: 5));
/// final both = await Task.all([() => fetch(1), () => fetch(2)]);
/// ```
///
/// With `isolate: true` the function runs on a background isolate, so a
/// CPU-bound job never blocks the event loop (timers still fire). The function
/// is copied to the isolate, so it must be a top-level or static function
/// holding nothing else (r58); a capturing closure throws an [ArgumentError].
/// Without it (the default) small work stays on the caller (r58).
abstract final class Task {
  /// Runs [fn] and answers its value.
  ///
  /// With `isolate: true` the work runs on a background isolate. A [timeout]
  /// bounds the wait *and* stops the work: on the caller the wait is
  /// abandoned, and the isolate is killed so nothing keeps running (a
  /// [TimeoutException] is thrown).
  static Future<T> run<T>(FutureOr<T> Function() fn, {Duration? timeout, String? name, bool isolate = false}) {
    if (!isolate) {
      final future = Future<T>.sync(fn);
      if (timeout == null) return future;
      return future.timeout(timeout);
    }
    return _runIsolate(fn, timeout: timeout, name: name);
  }

  static Future<T> _runIsolate<T>(FutureOr<T> Function() fn, {Duration? timeout, String? name}) async {
    final main = ReceivePort();
    Isolate? worker;
    try {
      try {
        worker = await Isolate.spawn(_entry<T>, [main.sendPort, fn], debugName: name ?? 'task');
      } on ArgumentError {
        main.close();
        throw ArgumentError.value(fn, 'fn', 'isolate: true needs a top-level or static function (r58)');
      }
    } catch (e) {
      main.close();
      rethrow;
    }
    try {
      final result = timeout == null ? await main.first : await main.first.timeout(timeout);
      if (result is _Fail) {
        if (result.error is Error) throw result.error!;
        throw result.error ?? StateError('Task failed without an error');
      }
      return (result as _Ok<T>).value;
    } on TimeoutException {
      worker.kill(priority: Isolate.immediate);
      throw TimeoutException('Task timed out${timeout == null ? '' : ' after $timeout'}', timeout);
    } finally {
      worker.kill(priority: Isolate.immediate);
      main.close();
    }
  }

  /// Runs every [fns] entry concurrently, answering their values in input order.
  ///
  /// With `isolate: true` each entry runs on its own background isolate.
  static Future<List<T>> all<T>(List<FutureOr<T> Function()> fns, {bool isolate = false}) =>
      Future.wait([for (final fn in fns) run<T>(fn, isolate: isolate)]);

  /// Starts a long-running background job that receives a [CancelToken]. Call [Bg.cancel]
  /// to ask it to stop.
  static Bg bg(Future<void> Function(CancelToken cancel) fn) => Bg.start(fn);
}

final class _Ok<T> {
  final T value;
  _Ok(this.value);
}

final class _Fail {
  final Object? error;
  _Fail(this.error);
}

void _entry<T>(List<Object?> args) {
  final port = args[0] as SendPort;
  final fn = args[1] as FutureOr<T> Function();
  Future.sync(fn).then((v) => port.send(_Ok<T>(v)), onError: (Object e) => port.send(_Fail(e)));
}

/// A cooperative cancellation flag handed to [Task.bg] jobs.
final class CancelToken {
  bool _done = false;

  /// Whether [cancel] has been called.
  bool get isDone => _done;

  /// Raises the flag. The flag is checked cooperatively by the job.
  void cancel() => _done = true;
}

/// A running [Task.bg] job.
final class Bg {
  final CancelToken _token;
  final Future<void> _done;

  Bg._(this._token, this._done);

  /// Starts [fn] with a fresh token.
  static Bg start(Future<void> Function(CancelToken cancel) fn) {
    final token = CancelToken();
    return Bg._(token, Future<void>.sync(() => fn(token)));
  }

  /// Whether the job has finished.
  bool get isDone => _token.isDone;

  /// The job's completion.
  Future<void> get done => _done;

  /// Asks the job to stop and waits for it.
  Future<void> cancel() async {
    _token.cancel();
    await _done;
  }
}
