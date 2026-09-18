part of '../../async.dart';

/// Runs [action] up to [attempts] times, waiting [delay] × [backoff]ⁿ between tries.
///
/// [delay] is jittered by ±25 % unless [jitter] is false, and never exceeds [maxDelay].
/// [when] limits which errors are retried; anything thrown is retried by default,
/// `Error`s included. [onRetry] fires before each wait. [cancelToken] aborts the loop
/// with a [CancelledException], unlike `Future.cancelWith`, which leaves it running.
///
/// ```dart
/// final data = await retry(fetchData, attempts: 3, delay: 200.ms);
/// ```
///
/// {@category Concurrency}
Future<T> retry<T>(
  FutureOr<T> Function() action, {
  int attempts = 3,
  Duration delay = const Duration(milliseconds: 200),
  Duration? maxDelay,
  double backoff = 2.0,
  bool jitter = true,
  bool Function(Object error)? when,
  void Function(int attempt, Object error, Duration nextDelay)? onRetry,
  CancelToken? cancelToken,
}) async {
  final maxAttempts = attempts > 0 ? attempts : 1;
  final factor = backoff >= 1.0 ? backoff : 1.0;
  var attempt = 0;
  var current = delay;

  while (true) {
    cancelToken?.throwIfCancelled();
    attempt++;
    try {
      return await action();
    } catch (error) {
      cancelToken?.throwIfCancelled();
      if (attempt >= maxAttempts || !(when?.call(error) ?? true)) rethrow;

      var wait = jitter ? current.jittered(0.25) : current;
      if (maxDelay != null && wait > maxDelay) wait = maxDelay;
      onRetry?.call(attempt, error, wait);
      if (wait > Duration.zero) await Future<void>.delayed(wait);

      current = Duration(milliseconds: (current.inMilliseconds * factor).round());
      if (maxDelay != null && current > maxDelay) current = maxDelay;
    }
  }
}
