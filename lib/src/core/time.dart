part of '../../core.dart';

/// Short duration extensions on [int].
///
/// {@category Utilities}
extension IntDurationExtensions on int {
  /// This many milliseconds.
  Duration get ms => Duration(milliseconds: this);

  /// This many seconds.
  Duration get s => Duration(seconds: this);

  /// This many minutes.
  Duration get m => Duration(minutes: this);

  /// This many hours.
  Duration get h => Duration(hours: this);

  /// This many days.
  Duration get d => Duration(days: this);
}

final _random = Random();

/// Formatting, jitter and cancellable waits on [Duration].
///
/// {@category Utilities}
extension DurationExtensions on Duration {
  /// A human-readable form: `125ms`, `45s`, `2m 15s`, `1h 5m 2s`.
  String get humanized {
    if (isNegative) return '-${(-this).humanized}';
    if (inMilliseconds < 1000) return '${inMilliseconds}ms';
    final hours = inHours, minutes = inMinutes % 60, seconds = inSeconds % 60;
    return [
      if (hours > 0) '${hours}h',
      if (minutes > 0) '${minutes}m',
      if (seconds > 0 || (hours == 0 && minutes == 0)) '${seconds}s',
    ].join(' ');
  }

  /// This duration scaled by a random factor in `[1 - factor, 1 + factor]`.
  Duration jittered([double factor = 0.25, Random? random]) {
    final variance = ((random ?? _random).nextDouble() * 2 - 1) * factor.clamp(0.0, 1.0);
    return Duration(microseconds: max(0, (inMicroseconds * (1 + variance)).round()));
  }

  /// Waits this long, or throws [CancelledException] as soon as the enclosing [Cancel.scope] is
  /// cancelled.
  Future<void> delay() {
    final token = Cancel.token;
    if (token == null) return Future<void>.delayed(this);
    if (token.isCancelled) return Future.error(token._exception);
    final done = Completer<void>();
    final timer = Timer(this, done.complete);
    final unregister = token.onCancel(() {
      timer.cancel();
      if (!done.isCompleted) done.completeError(token._exception);
    });
    return done.future.whenComplete(unregister);
  }
}
