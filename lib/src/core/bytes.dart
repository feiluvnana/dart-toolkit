part of '../../core.dart';

/// A byte count as people read it.
///
/// {@category Utilities}
extension NumBytesExtensions on num {
  /// This many bytes in binary units, one decimal: `512 B`, `1.5 KB`, `20.0 MB`, `3.2 GB`;
  /// a rate reads the same: `'${speed.humanBytes}/s'`.
  String get humanBytes {
    if (round() < 1024) return '${round()} B';
    var value = this / 1024;
    // The unit is picked on the rounded figure, so 1048575 is `1.0 MB`, not `1024.0 KB`.
    for (final unit in const ['KB', 'MB']) {
      if (value < 1023.95) return '${value.toStringAsFixed(1)} $unit';
      value /= 1024;
    }
    return '${value.toStringAsFixed(1)} GB';
  }
}
