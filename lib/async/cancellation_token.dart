import 'dart:async';

/// A token used to signal cancellation of asynchronous operations.
///
/// Pass a [CancellationToken] to operations like `scrape`, `download`, `downloadAll`,
/// `parallelMap`, and `retry` to gracefully abort in-flight or queued work.
///
/// {@category Concurrency}
class CancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];
  Object? _reason;

  /// Creates a new [CancellationToken].
  CancellationToken();

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// The reason provided for cancellation, if any.
  Object? get reason => _reason;

  /// Requests cancellation of operations listening to this token.
  void cancel([Object? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }

  /// Registers a callback to be invoked when cancellation is requested.
  void onCancel(void Function() listener) {
    if (_isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  /// Throws a [CancellationException] if cancellation has already been requested.
  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancellationException(_reason?.toString() ?? 'Operation was cancelled.');
    }
  }
}

/// Exception thrown when an asynchronous operation is aborted via a [CancellationToken].
///
/// {@category Concurrency}
class CancellationException implements Exception {
  final String message;

  const CancellationException([this.message = 'Operation was cancelled.']);

  @override
  String toString() => 'CancellationException: $message';
}

/// Uniform cancellation composition for any [Stream], so cancellation reads the
/// same everywhere instead of threading a token through each signature.
///
/// Prefer this when composing; pass `cancelToken:` directly to an operation
/// when you want it to abort queued work internally as well.
///
/// ```dart
/// await for (final item in url.scrape<Item>(parse).cancelWith(token)) { ... }
/// ```
///
/// {@category Concurrency}
extension StreamCancelExtensions<T> on Stream<T> {
  /// Stops this stream when [token] is cancelled.
  ///
  /// Set [throwOnCancel] to surface a [CancellationException] instead of
  /// closing the stream silently.
  Stream<T> cancelWith(CancellationToken token, {bool throwOnCancel = false}) {
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;

    void finish() {
      if (controller.isClosed) return;
      if (throwOnCancel) {
        controller.addError(CancellationException(token.reason?.toString() ?? 'Operation was cancelled.'));
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
        token.onCancel(finish);
        subscription = listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            if (!controller.isClosed) controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        final sub = subscription;
        subscription = null;
        await sub?.cancel();
      },
    );

    return controller.stream;
  }
}

/// Uniform cancellation composition for any [Future].
///
/// {@category Concurrency}
extension FutureCancelExtensions<T> on Future<T> {
  /// Completes with a [CancellationException] as soon as [token] is cancelled.
  ///
  /// The underlying work is not interrupted; pass `cancelToken:` to the
  /// operation itself when it must stop doing work.
  Future<T> cancelWith(CancellationToken token) {
    if (token.isCancelled) {
      return Future<T>.error(CancellationException(token.reason?.toString() ?? 'Operation was cancelled.'));
    }
    final completer = Completer<T>();
    token.onCancel(() {
      if (!completer.isCompleted) {
        completer.completeError(CancellationException(token.reason?.toString() ?? 'Operation was cancelled.'));
      }
    });
    then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }
}
