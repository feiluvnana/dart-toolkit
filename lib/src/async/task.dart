import 'dart:async';
import 'dart:isolate';

/// One-shot background work, always on an isolate.
///
/// ```dart
/// final answer = await Task.run(() => 40 + 2);
/// ```
///
/// The function runs on a background isolate, so a CPU-bound job never blocks
/// the event loop (timers still fire). It is copied to the isolate, so it
/// must be a top-level or static function, or a closure over sendable values
/// only (rule 52); anything else throws an [ArgumentError].
abstract final class Task {
  /// Runs [fn] and answers its value.
  ///
  /// A [timeout] bounds the wait *and* stops the work: on the caller the wait
  /// is abandoned, and the isolate is killed so nothing keeps running (a
  /// [TimeoutException] is thrown).
  static Future<T> run<T>(FutureOr<T> Function() fn, {Duration? timeout}) => _runIsolate(fn, timeout: timeout);

  static Future<T> _runIsolate<T>(FutureOr<T> Function() fn, {Duration? timeout}) async {
    final main = ReceivePort();
    Isolate? worker;
    try {
      try {
        worker = await Isolate.spawn(_entry<T>, [main.sendPort, fn], debugName: 'task');
      } on ArgumentError {
        main.close();
        throw ArgumentError.value(
          fn,
          'fn',
          'needs a top-level or static function, or a closure over sendable values (rule 52)',
        );
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
