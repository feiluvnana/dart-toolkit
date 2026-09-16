import 'dart:async';

import '../util/time.dart';

/// Builder for configuring and executing retries on asynchronous operations.
class RetryBuilder<T> implements Future<T> {
  final FutureOr<T> Function() _action;
  int _attempts = 3;
  Duration _delay = const Duration(milliseconds: 200);
  double _backoff = 2.0;
  bool _jitter = true;
  bool Function(Object error)? _retryIf;
  void Function(int attempt, Object error, Duration nextDelay)? _listener;

  RetryBuilder(this._action);

  /// Maximum number of attempts including the initial try (default: 3).
  RetryBuilder<T> attempts(int count) {
    _attempts = count > 0 ? count : 1;
    return this;
  }

  /// Initial delay before the first retry (default: 200ms).
  RetryBuilder<T> delay(Duration duration) {
    _delay = duration;
    return this;
  }

  /// Exponential backoff factor (default: 2.0).
  RetryBuilder<T> backoff(double factor) {
    _backoff = factor >= 1.0 ? factor : 1.0;
    return this;
  }

  /// Whether to add randomized jitter to retry delays (default: true).
  RetryBuilder<T> jitter([bool enabled = true]) {
    _jitter = enabled;
    return this;
  }

  /// Conditional filter specifying whether [error] should trigger a retry.
  RetryBuilder<T> when(bool Function(Object error) predicate) {
    _retryIf = predicate;
    return this;
  }

  /// Callback listener triggered on each retry attempt before waiting for the next delay.
  RetryBuilder<T> listen(void Function(int attempt, Object error, Duration nextDelay) callback) {
    _listener = callback;
    return this;
  }

  /// Executes the async action according to the retry configuration.
  Future<T> run() async {
    var attemptCount = 0;
    var currentDelay = _delay;

    while (true) {
      attemptCount++;
      try {
        return await _action();
      } catch (error) {
        final shouldRetry = attemptCount < _attempts && (_retryIf == null || _retryIf!(error));
        if (!shouldRetry) {
          rethrow;
        }

        final delayToWait = _jitter ? currentDelay.jittered(0.25) : currentDelay;
        _listener?.call(attemptCount, error, delayToWait);

        if (delayToWait > .zero) {
          await Future<void>.delayed(delayToWait);
        }

        currentDelay = Duration(milliseconds: (currentDelay.inMilliseconds * _backoff).round());
      }
    }
  }

  // Future<T> implementation allowing direct `await` on the builder:

  @override
  Stream<T> asStream() => run().asStream();

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) =>
      run().catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) =>
      run().then(onValue, onError: onError);

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      run().timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) =>
      run().whenComplete(action);
}

/// Convenience retry extensions on async functions and closures.
extension RetryFunctionExtension<T> on FutureOr<T> Function() {
  /// Wraps this async function in a fluent [RetryBuilder].
  RetryBuilder<T> retry() => RetryBuilder<T>(this);
}
