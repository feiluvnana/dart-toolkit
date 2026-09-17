import 'dart:async';

import '../util/time.dart';
import 'cancellation_token.dart';

/// Builder for configuring and executing retries on asynchronous operations.
///
/// {@category Concurrency}
class RetryBuilder<T> implements Future<T> {
  final FutureOr<T> Function() _action;
  int _maxAttempts = 3;
  Duration _delay = const Duration(milliseconds: 200);
  Duration? _maxDelay;
  double _backoff = 2.0;
  bool _jitter = true;
  bool Function(Object error)? _retryIf;
  void Function(int attempt, Object error, Duration nextDelay)? _listener;
  CancellationToken? _cancelToken;

  RetryBuilder(this._action);

  void _checkNotStarted() {
    if (_future != null) {
      throw StateError('Cannot modify RetryBuilder configuration after execution has started.');
    }
  }

  /// Maximum number of attempts, including the initial try (default: 3).
  RetryBuilder<T> maxAttempts(int count) {
    _checkNotStarted();
    _maxAttempts = count > 0 ? count : 1;
    return this;
  }

  /// Initial delay before the first retry (default: 200ms).
  RetryBuilder<T> delay(Duration duration) {
    _checkNotStarted();
    _delay = duration;
    return this;
  }

  /// Maximum delay cap for exponential backoff.
  RetryBuilder<T> maxDelay(Duration duration) {
    _checkNotStarted();
    _maxDelay = duration;
    return this;
  }

  /// Exponential backoff factor (default: 2.0).
  RetryBuilder<T> backoff(double factor) {
    _checkNotStarted();
    _backoff = factor >= 1.0 ? factor : 1.0;
    return this;
  }

  /// Whether to add randomized jitter to retry delays (default: true).
  RetryBuilder<T> jitter([bool enabled = true]) {
    _checkNotStarted();
    _jitter = enabled;
    return this;
  }

  /// Retries only when [predicate] accepts the thrown error.
  RetryBuilder<T> when(bool Function(Object error) predicate) {
    _checkNotStarted();
    _retryIf = predicate;
    return this;
  }

  /// Attaches a [CancellationToken] that aborts the retry loop.
  ///
  /// Distinct from `Future.cancelWith`, which only completes the outer future
  /// with an error and leaves the retries running.
  RetryBuilder<T> cancelOn(CancellationToken token) {
    _checkNotStarted();
    _cancelToken = token;
    return this;
  }

  /// Callback listener triggered on each retry attempt before waiting for the next delay.
  RetryBuilder<T> listen(void Function(int attempt, Object error, Duration nextDelay) callback) {
    _checkNotStarted();
    _listener = callback;
    return this;
  }

  Future<T>? _future;

  /// Executes the async action according to the retry configuration.
  Future<T> run() => _future ??= _execute();

  Future<T> _execute() async {
    var attemptCount = 0;
    var currentDelay = _delay;

    while (true) {
      _cancelToken?.throwIfCancelled();
      attemptCount++;
      try {
        return await _action();
      } catch (error) {
        _cancelToken?.throwIfCancelled();
        final shouldRetry = attemptCount < _maxAttempts && (_retryIf == null || _retryIf!(error));
        if (!shouldRetry) {
          rethrow;
        }

        var delayToWait = _jitter ? currentDelay.jittered(0.25) : currentDelay;
        if (_maxDelay != null && delayToWait > _maxDelay!) {
          delayToWait = _maxDelay!;
        }
        _listener?.call(attemptCount, error, delayToWait);

        if (delayToWait > Duration.zero) {
          await Future<void>.delayed(delayToWait);
        }

        var nextDelayMs = (currentDelay.inMilliseconds * _backoff).round();
        currentDelay = Duration(milliseconds: nextDelayMs);
        if (_maxDelay != null && currentDelay > _maxDelay!) {
          currentDelay = _maxDelay!;
        }
      }
    }
  }

  // Implements Future<T> so the builder can be awaited directly.

  @override
  Stream<T> asStream() => run().asStream();

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) => run().catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) =>
      run().then(onValue, onError: onError);

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      run().timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) => run().whenComplete(action);
}

/// Shorthand function to retry [action] up to [maxAttempts] times with exponential backoff.
///
/// {@category Concurrency}
Future<T> retry<T>(
  FutureOr<T> Function() action, {
  int maxAttempts = 3,
  Duration delay = const Duration(milliseconds: 200),
  Duration? maxDelay,
  double backoff = 2.0,
  bool jitter = true,
  bool Function(Object error)? when,
  CancellationToken? cancelToken,
}) {
  var builder = RetryBuilder<T>(action).maxAttempts(maxAttempts).delay(delay).backoff(backoff).jitter(jitter);

  if (maxDelay != null) {
    builder = builder.maxDelay(maxDelay);
  }
  if (when != null) {
    builder = builder.when(when);
  }
  if (cancelToken != null) {
    builder = builder.cancelOn(cancelToken);
  }
  return builder.run();
}

/// Extension on closures to construct a [RetryBuilder] fluently.
///
/// {@category Concurrency}
extension FunctionRetryExtensions<T> on FutureOr<T> Function() {
  /// Retries this computation up to [maxAttempts] times with exponential backoff.
  RetryBuilder<T> retry([int maxAttempts = 3]) => RetryBuilder<T>(this).maxAttempts(maxAttempts);
}
