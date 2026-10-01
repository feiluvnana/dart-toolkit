part of '../../async.dart';

/// Runs [action] up to [attempts] times, waiting [delay] × [backoff]ⁿ between tries.
///
/// [delay] is jittered by ±25 % unless [jitter] is false and capped at [maxDelay]. [when]
/// limits which errors are retried (default: everything, `Error`s included); [onRetry] fires
/// before each wait. The enclosing [Cancel.scope] aborts it, mid-backoff too.
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
}) async {
  final maxAttempts = max(attempts, 1);
  final factor = backoff >= 1.0 ? backoff : 1.0;
  var attempt = 0;
  var current = delay;
  while (true) {
    Cancel.throwIfCancelled();
    attempt++;
    try {
      return await action();
    } catch (error) {
      Cancel.throwIfCancelled();
      if (attempt >= maxAttempts || !(when?.call(error) ?? true)) rethrow;

      var wait = jitter ? current.jittered(0.25) : current;
      if (maxDelay != null && wait > maxDelay) wait = maxDelay;
      onRetry?.call(attempt, error, wait);
      if (wait > Duration.zero) await wait.delay();

      current = Duration(microseconds: (current.inMicroseconds * factor).round());
      if (maxDelay != null && current > maxDelay) current = maxDelay;
    }
  }
}
