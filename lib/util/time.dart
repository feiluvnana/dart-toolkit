/// # Time & Delays (`util.time.*`)
///
/// Delays, timestamps and duration formatting. Delays are always [Duration];
/// the [DurationInt] extension keeps call sites short (`250.ms`).
library;

import 'dart:async';

// ============================================================================
// TIME & DELAYS (util.time.*)
// ============================================================================

/// Entry point for time helpers, reachable as `util.time`.
///
/// ```dart
/// final clock = util.time.clock();
/// await util.time.wait(250.ms);
/// print(util.time.format(clock.elapsed)); // '00:00'
/// ```
class TimeAccessor {
  /// Creates the accessor. Prefer the shared `util.time` instance.
  const TimeAccessor();

  /// Waits for [duration] without blocking the isolate.
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);

  /// A started [Stopwatch], for measuring elapsed work.
  Stopwatch clock() => Stopwatch()..start();

  /// Formats [duration] as `mm:ss`, or `hh:mm:ss` past an hour.
  String format(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  /// A filename-safe timestamp, `yyyyMMdd_HHmmss`.
  ///
  /// Uses [date], or the current local time.
  String stamp([DateTime? date]) {
    final d = date ?? DateTime.now();
    String pad(int value, [int width = 2]) =>
        value.toString().padLeft(width, '0');
    return '${pad(d.year, 4)}${pad(d.month)}${pad(d.day)}'
        '_${pad(d.hour)}${pad(d.minute)}${pad(d.second)}';
  }

  /// An ISO-8601 UTC timestamp for [date], or now.
  String iso([DateTime? date]) =>
      (date ?? DateTime.now()).toUtc().toIso8601String();

  /// A coarse human description of how long ago [past] was.
  ///
  /// Compares against [relativeTo], or now. Future instants report
  /// `'in the future'`.
  String ago(DateTime past, [DateTime? relativeTo]) {
    final diff = (relativeTo ?? DateTime.now()).difference(past);
    if (diff.isNegative) return 'in the future';
    return switch (diff) {
      Duration(inSeconds: final s) when s < 5 => 'just now',
      Duration(inSeconds: final s) when s < 60 => '${s}s ago',
      Duration(inMinutes: final m) when m < 60 => '${m}m ago',
      Duration(inHours: final h) when h < 24 => '${h}h ago',
      Duration(inDays: final d) when d < 30 => '${d}d ago',
      Duration(inDays: final d) when d < 365 => '${d ~/ 30}mo ago',
      Duration(inDays: final d) => '${d ~/ 365}y ago',
    };
  }

  /// Milliseconds since the Unix epoch for [date], or now.
  int epoch([DateTime? date]) =>
      (date ?? DateTime.now()).millisecondsSinceEpoch;
}
