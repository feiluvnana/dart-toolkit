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

/// Functional extensions on [Duration].
///
/// {@category Utilities}
extension DurationExtensions on Duration {
  /// A human-readable form: `125ms`, `45s`, `2m 15s`, `1h 5m 2s`.
  String get humanized {
    if (inMilliseconds < 1000) {
      return '${inMilliseconds}ms';
    }
    final hours = inHours;
    final minutes = inMinutes % 60;
    final seconds = inSeconds % 60;

    final parts = <String>[];
    if (hours > 0) parts.add('${hours}h');
    if (minutes > 0) parts.add('${minutes}m');
    if (seconds > 0 || parts.isEmpty) parts.add('${seconds}s');

    return parts.join(' ');
  }

  /// Randomizes this duration within `[1 - factor, 1 + factor]` range.
  Duration jittered([double factor = 0.25, Random? random]) {
    final rand = random ?? _random;
    final clampedFactor = factor.clamp(0.0, 1.0);
    final variance = (rand.nextDouble() * 2 - 1) * clampedFactor;
    return Duration(microseconds: max(0, (inMicroseconds * (1 + variance)).round()));
  }

  /// Waits this long, or throws [CancelledException] as soon as the enclosing
  /// [Cancel.scope] is cancelled — a wait is where a loop spends its time, so it is where
  /// it must stop.
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
