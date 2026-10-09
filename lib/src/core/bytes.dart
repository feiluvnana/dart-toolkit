part of '../base.dart';

/// Units on a number: `30.s`, `1.5.h`, `250.ms` for a [Duration], `size.humanBytes` for a size.
///
/// {@category Utilities}
extension NumExtensions on num {
  /// This many milliseconds, to the microsecond: `1.5.ms`.
  Duration get ms => Duration(microseconds: (this * 1000).round());

  /// This many seconds: `30.s`, `0.5.s`.
  Duration get s => Duration(microseconds: (this * 1000000).round());

  /// This many minutes.
  Duration get m => Duration(microseconds: (this * 60000000).round());

  /// This many hours.
  Duration get h => Duration(microseconds: (this * 3600000000).round());

  /// This many days.
  Duration get d => Duration(microseconds: (this * 86400000000).round());

  /// This many bytes in binary units, one decimal: `512 B`, `1.5 KB`, `20.0 MB`, `3.2 GB`, up to PB;
  /// a rate reads the same: `'${speed.humanBytes}/s'`.
  String get humanBytes {
    if (isNaN) return 'NaN B';
    if (isInfinite) return isNegative ? '-Infinity B' : 'Infinity B';
    if (round() < 0) return '-${(-this).humanBytes}';
    if (round() < 1024) return '${round()} B';
    var value = this / 1024;
    // The unit is picked on the rounded figure, so 1048575 is `1.0 MB`, not `1024.0 KB`.
    for (final unit in const ['KB', 'MB', 'GB', 'TB']) {
      if (value < 1023.95) return '${value.toStringAsFixed(1)} $unit';
      value /= 1024;
    }
    return '${value.toStringAsFixed(1)} PB';
  }
}
