import 'dart:async';

/// Signals cancellation to cooperating asynchronous operations.
///
/// {@category Concurrency}
class CancelToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = {};
  Object? _reason;

  CancelToken();

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// The reason provided for cancellation, if any.
  Object? get reason => _reason;

  /// Requests cancellation of operations listening to this token.
  void cancel([Object? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    for (final listener in _listeners.toList()) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }

  /// Registers [listener] to run when cancellation is requested.
  ///
  /// Returns a function that unregisters it. Call it when the work finishes on its
  /// own — a long-lived token otherwise retains every listener ever registered.
  void Function() onCancel(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Throws a [CancelledException] if cancellation has already been requested.
  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancelledException(_reason?.toString() ?? 'Operation was cancelled.');
    }
  }
}

/// Exception thrown when an asynchronous operation is aborted via a [CancelToken].
///
/// {@category Concurrency}
class CancelledException implements Exception {
  final String message;

  const CancelledException([this.message = 'Operation was cancelled.']);

  @override
  String toString() => 'CancelledException: $message';
}

/// Cancellation for any [Stream].
///
/// Composes at the use site; pass `cancelToken:` to the operation itself when it
/// must also stop doing queued work.
///
/// {@category Concurrency}
extension StreamCancelExtensions<T> on Stream<T> {
  /// Stops this stream when [token] is cancelled.
  ///
  /// [throwOnCancel] surfaces a [CancelledException] instead of closing silently.
  Stream<T> cancelWith(CancelToken token, {bool throwOnCancel = false}) {
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    void Function()? unregister;

    void finish() {
      if (controller.isClosed) return;
      if (throwOnCancel) {
        controller.addError(CancelledException(token.reason?.toString() ?? 'Operation was cancelled.'));
      }
      subscription?.cancel();
      subscription = null;
      controller.close();
    }

    controller = StreamController<T>(
      onListen: () {
        if (token.isCancelled) {
          finish();
          return;
        }
        unregister = token.onCancel(finish);
        subscription = listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            unregister?.call();
            if (!controller.isClosed) controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        unregister?.call();
        final sub = subscription;
        subscription = null;
        await sub?.cancel();
      },
    );

    return controller.stream;
  }
}

/// Cancellation for any [Future].
///
/// {@category Concurrency}
extension FutureCancelExtensions<T> on Future<T> {
  /// Completes with a [CancelledException] as soon as [token] is cancelled.
  ///
  /// The underlying work is not interrupted.
  Future<T> cancelWith(CancelToken token) {
    if (token.isCancelled) {
      return Future<T>.error(CancelledException(token.reason?.toString() ?? 'Operation was cancelled.'));
    }
    final completer = Completer<T>();
    final unregister = token.onCancel(() {
      if (!completer.isCompleted) {
        completer.completeError(CancelledException(token.reason?.toString() ?? 'Operation was cancelled.'));
      }
    });
    then(
      (value) {
        unregister();
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        unregister();
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }
}
