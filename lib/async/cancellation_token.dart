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
