part of '../core.dart';

/// How to try again: [times] more tries after the first, waiting [backoff] before the first
/// retry and twice as long before each next one, at most [max], each wait ±25 % jitter.
///
/// [when] picks the errors worth another try. By default everything is, except what would fail
/// the same way again: an [Error] (a bug), a [FormatException], a [MissingException], a
/// [CancelledException], and a command that cannot run. An error an inner retry already gave up
/// on is never tried again by an outer one: the innermost policy wins.
///
/// Every retry is a [Warned] with a [RetryWarning] on the work it serves.
///
/// ```dart
/// final data = await Retry(3).run(() => flaky());
/// await urls.parallelize(fetch, retry: Retry(2, backoff: 1.s));
/// ```
///
/// {@category Concurrency}
final class Retry {
  /// Tries after the first.
  final int times;

  /// The wait before the first retry.
  final Duration backoff;

  /// The longest wait, or `null` for no cap.
  final Duration? max;

  /// Which errors are worth another try; `null` for the default.
  final bool Function(Object error)? when;

  const Retry(this.times, {this.backoff = const Duration(milliseconds: 200), this.max, this.when})
    : assert(times >= 0, 'Invalid times, expected at least 0');

  /// Never again.
  static const none = Retry(0);

  /// What every network request does unless told otherwise: two more tries.
  static const network = Retry(2);

  /// [body], tried as this policy says, as a [Task]: each retry a [Warned] on it.
  Task<T> run<T>(FutureOr<T> Function() body, {String label = 'retry'}) {
    _check();
    return TaskInternals.start(label, label, (work) => attempt(body));
  }

  /// [body], tried as this policy says, in the work around the caller: each retry a
  /// [Warned] there. Not a task: for a library's own loop inside its task.
  Future<T> attempt<T>(FutureOr<T> Function() body, {void Function(RetryWarning warning)? onRetry}) async {
    _check();
    final frame = _RetryFrame.inside();
    var tries = 0;
    while (true) {
      Cancel.check();
      tries++;
      try {
        return await frame.run(body);
      } catch (error) {
        Cancel.check();
        if (tries > times || !_worth(error, frame)) {
          if (tries > 1) frame.gaveUp(error);
          rethrow;
        }
        final pause = _pause(tries);
        final warning = RetryWarning(tries, times, pause, error);
        onRetry != null ? onRetry(warning) : TaskInternals.warn(warning);
        if (pause > Duration.zero) await pause.delay();
      }
    }
  }

  /// The wait before retry number [retry] (from 1): [backoff] doubled each time, jittered, at
  /// most [max].
  Duration _pause(int retry) {
    var wait = backoff * (1 << (retry - 1).clamp(0, 30));
    if (max != null && wait > max!) wait = max!;
    wait = wait.jittered();
    return max != null && wait > max! ? max! : wait;
  }

  /// Whether [error], met in [frame], is worth another try under this policy.
  bool _worth(Object error, _RetryFrame frame) =>
      !frame.gaveUpInside(error) && (when?.call(error) ?? !_permanent(error));

  void _check() {
    if (times < 0) throw ArgumentError.value(times, 'times', 'Invalid times, expected at least 0');
  }

  @override
  bool operator ==(Object other) =>
      other is Retry && other.times == times && other.backoff == backoff && other.max == max && other.when == when;

  @override
  int get hashCode => Object.hash(times, backoff, max, when);

  @override
  String toString() => 'Retry($times)';
}

const _retryKey = #dartToolkitRetry;

/// One retry loop, inside the loops around it: an error a loop inside this one gave up on is
/// not tried again here, while the same error met elsewhere still is.
final class _RetryFrame {
  final _RetryFrame? _outer;

  _RetryFrame.inside() : _outer = Zone.current[_retryKey] as _RetryFrame?;

  /// The loop that gave up on each error.
  static final _givenUp = Expando<_RetryFrame>('retried');

  R run<R>(R Function() body) => runZoned(body, zoneValues: {_retryKey: this});

  void gaveUp(Object error) {
    if (_markable(error)) _givenUp[error] = this;
  }

  bool gaveUpInside(Object error) {
    if (!_markable(error)) return false;
    for (var frame = _givenUp[error]; frame != null; frame = frame._outer) {
      if (identical(frame._outer, this)) return true;
    }
    return false;
  }

  static bool _markable(Object error) => error is! num && error is! String && error is! bool && error is! Record;
}

/// What a retry never repeats unasked: it would fail the same way again.
bool _permanent(Object error) =>
    error is Error ||
    error is FormatException ||
    error is MissingException ||
    error is CancelledException ||
    error is BatchException ||
    ProcessBridge.cannotRun(error);
