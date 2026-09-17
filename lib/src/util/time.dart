import 'dart:math';

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

/// Functional extensions on [Duration].
///
/// {@category Utilities}
extension DurationExtensions on Duration {
  /// A human-readable form: `125ms`, `45s`, `2m 15s`, `1h 5m 2s`.
  String humanize() {
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
    final rand = random ?? Random();
    final clampedFactor = factor.clamp(0.0, 1.0);
    final variance = (rand.nextDouble() * 2 - 1) * clampedFactor;
    final ms = (inMilliseconds * (1 + variance)).round();
    return Duration(milliseconds: max(0, ms));
  }

  /// Asynchronously delays execution for this duration.
  Future<void> delay() => Future<void>.delayed(this);
}
