import 'dart:async';

/// One-shot background work: [run], [all] and the long-running [bg].
///
/// ```dart
/// final hash = await Task.run(() => calcHash(buf));
/// final res  = await Task.run(() => slow(), timeout: const Duration(seconds: 5));
/// final both = await Task.all([() => fetch(1), () => fetch(2)]);
/// ```
abstract final class Task {
  /// Runs [fn] and answers its value. A [timeout] abandons the wait with a [TimeoutException].
  static Future<T> run<T>(FutureOr<T> Function() fn, {Duration? timeout, String? name}) {
    final future = Future<T>.sync(fn);
    if (timeout == null) return future;
    return future.timeout(timeout);
  }

  /// Runs every [fns] entry concurrently, answering their values in input order.
  static Future<List<T>> all<T>(List<FutureOr<T> Function()> fns) =>
      Future.wait([for (final fn in fns) Future<T>.sync(fn)]);

  /// Starts a long-running background job that receives a [CancelToken]. Call [Bg.cancel]
  /// to ask it to stop.
  static Bg bg(Future<void> Function(CancelToken cancel) fn) => Bg.start(fn);
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
