part of '../../core.dart';

/// A byte count as people read it.
///
/// {@category Utilities}
extension IntBytesExtensions on int {
  /// This many bytes in binary units, one decimal: `512 B`, `1.5 KB`, `20.0 MB`, `3.2 GB`.
  String get humanBytes {
    if (this < 1024) return '$this B';
    var value = this / 1024;
    for (final unit in const ['KB', 'MB']) {
      if (value < 1024) return '${value.toStringAsFixed(1)} $unit';
      value /= 1024;
    }
    return '${value.toStringAsFixed(1)} GB';
  }
}
