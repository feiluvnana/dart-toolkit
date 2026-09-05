import 'dart:async';
import 'dart:io' as io;

// ============================================================================
// TIME & DELAYS SUBSYSTEM (time.* / Time)
// ============================================================================

/// Top-level time, delay, and timestamp utility accessor.
///
/// Provides strictly 1-word methods for delays, timestamps, and relative durations:
/// ```dart
/// // Ergonomic delay
/// await time.wait(250); // 250 milliseconds
/// await time.wait(Duration(seconds: 1));
///
/// // Filename safe timestamp: "20260905_205012"
/// final fileStamp = time.stamp();
///
/// // Relative elapsed time: "2m ago"
/// final elapsed = time.ago(createdAt);
/// Time and duration manager providing delays, formatting, and stopwatch timers.
class TimeAccessor {
  /// Creates a [TimeAccessor].
  const TimeAccessor();

  /// Asynchronously waits for [durationOrMs] (1-word).
  ///
  /// Accepts a [Duration] or an integer number of milliseconds:
  /// ```dart
  /// await time.wait(500); // Wait 500ms
  /// await time.wait(const Duration(seconds: 2));
  /// ```
  Future<void> wait(Object durationOrMs) {
    if (durationOrMs is Duration) {
      return Future.delayed(durationOrMs);
    } else if (durationOrMs is num) {
      return Future.delayed(Duration(milliseconds: durationOrMs.toInt()));
    }
    return Future.value();
  }

  /// Formats a [date] (defaults to `DateTime.now()`) as a filename-safe timestamp string (`YYYYMMDD_HHMMSS`) (1-word).
  String stamp([DateTime? date]) {
    final d = date ?? DateTime.now();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    final h = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    final sec = d.second.toString().padLeft(2, '0');
    return '$y$m${day}_$h$min$sec';
  }

  /// Returns an ISO-8601 UTC string for [date] (defaults to `DateTime.now()`) (1-word).
  String iso([DateTime? date]) {
    return (date ?? DateTime.now()).toUtc().toIso8601String();
  }

  /// Returns a human-readable relative time string from [past] (e.g. `"just now"`, `"15s ago"`, `"2m ago"`, `"3h ago"`, `"5d ago"`) (1-word).
  String ago(DateTime past, [DateTime? relativeTo]) {
    final now = relativeTo ?? DateTime.now();
    final diff = now.difference(past);

    if (diff.isNegative) return 'in the future';
    final seconds = diff.inSeconds;
    if (seconds < 5) return 'just now';
    if (seconds < 60) return '${seconds}s ago';
    final minutes = diff.inMinutes;
    if (minutes < 60) return '${minutes}m ago';
    final hours = diff.inHours;
    if (hours < 24) return '${hours}h ago';
    final days = diff.inDays;
    if (days < 30) return '${days}d ago';
    if (days < 365) return '${(days / 30).floor()}mo ago';
    return '${(days / 365).floor()}y ago';
  }

  /// Returns the current [DateTime] (1-word).
  DateTime now() => DateTime.now();

  /// Starts and returns a new [Stopwatch] benchmark timer (1-word).
  Stopwatch clock() => Stopwatch()..start();

  /// Returns unix epoch milliseconds for [date] (defaults to `DateTime.now()`) (1-word).
  int epoch([DateTime? date]) =>
      (date ?? DateTime.now()).millisecondsSinceEpoch;

  /// Synchronously blocks the current thread for [milliseconds] (1-word).
  void sleep(int milliseconds) {
    io.sleep(Duration(milliseconds: milliseconds));
  }
}
