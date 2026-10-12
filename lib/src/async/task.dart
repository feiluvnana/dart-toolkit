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
    final errors = ReceivePort();
    final exits = ReceivePort();
    Isolate? worker;
    void shut() {
      main.close();
      errors.close();
      exits.close();
    }

    try {
      worker = await Isolate.spawn(
        _entry<T>,
        [main.sendPort, fn],
        debugName: 'task',
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
    } on ArgumentError {
      shut();
      throw ArgumentError.value(
        fn,
        'fn',
        'needs a top-level or static function, or a closure over sendable values (rule 52)',
      );
    } catch (e) {
      shut();
      rethrow;
    }
    try {
      final waiting = Future.any([
        main.first.then((v) => _Outcome.result(v)),
        errors.first.then((v) => _Outcome.remoteError(v)),
        exits.first.then((_) => _Outcome.exited()),
      ]);
      final outcome = timeout == null ? await waiting : await waiting.timeout(timeout);
      if (outcome is _Result) {
        final result = outcome.value;
        if (result is _Fail) {
          if (result.error is Error) Error.throwWithStackTrace(result.error!, result.stack);
          throw result.error ?? StateError('Task failed without an error');
        }
        return (result as _Ok<T>).value;
      }
      if (outcome is _RemoteError) {
        // An uncaught async error in the isolate: only its message and stack
        // cross, so they travel as a StateError carrying both.
        final parts = (outcome.value as List).map((e) => '$e').toList();
        final stack = parts.length > 1 ? StackTrace.fromString(parts[1]) : StackTrace.empty;
        Error.throwWithStackTrace(StateError('Task failed in its isolate: ${parts[0]}'), stack);
      }
      // The isolate exited without answering (its result could not cross, or it
      // died): never hang on a missing answer.
      throw StateError('Task isolate exited without answering');
    } on TimeoutException {
      worker.kill(priority: Isolate.immediate);
      throw TimeoutException('Task timed out${timeout == null ? '' : ' after $timeout'}', timeout);
    } finally {
      worker.kill(priority: Isolate.immediate);
      shut();
    }
  }
}

/// Which port answered a task isolate first.
sealed class _Outcome {
  const _Outcome();
  factory _Outcome.result(Object? value) = _Result;
  factory _Outcome.remoteError(Object? value) = _RemoteError;
  factory _Outcome.exited() = _Exited;
}

final class _Result extends _Outcome {
  final Object? value;
  const _Result(this.value);
}

final class _RemoteError extends _Outcome {
  final Object? value;
  const _RemoteError(this.value);
}

final class _Exited extends _Outcome {
  const _Exited();
}

final class _Ok<T> {
  final T value;
  _Ok(this.value);
}

final class _Fail {
  final Object? error;
  final StackTrace stack;
  _Fail(this.error, [StackTrace? stack]) : stack = stack ?? StackTrace.empty;
}

void _entry<T>(List<Object?> args) {
  final port = args[0] as SendPort;
  final fn = args[1] as FutureOr<T> Function();
  Future.sync(fn).then(
    (v) {
      try {
        port.send(_Ok<T>(v));
      } catch (_) {
        // Unsendable across isolates (a ReceivePort, a closure over one):
        // say so instead of hanging on a missing answer.
        port.send(_Fail(StateError('Task result cannot be sent across isolates')));
      }
    },
    onError: (Object e, StackTrace st) {
      try {
        port.send(_Fail(e, st));
      } catch (_) {
        port.send(_Fail('$e'));
      }
    },
  );
}
