/// # Byte Size Formatting & Parsing (`util.size.*`)
///
/// Single source of truth for human-readable byte sizes. Used by the console
/// progress bar and available directly as `util.size.format` / `util.size.parse`.
library;

import 'dart:math' as math;

/// Formats and parses human-readable byte sizes.
///
/// Reachable as `util.size`:
///
/// ```dart
/// util.size.format(5 * 1024 * 1024); // '5.0 MB'
/// util.size.parse('2.5 MB');         // 2621440
/// ```
class SizeAccessor {
  /// Creates the accessor. Prefer the shared `util.size` instance.
  const SizeAccessor();

  static const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /// Renders [bytes] as a human-readable string, e.g. `'1.0 KB'`.
  ///
  /// [decimals] controls the fraction digits. Zero and negative inputs render
  /// as `'0 B'`.
  String format(int bytes, {int decimals = 1}) {
    if (bytes <= 0) return '0 B';
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(
      0,
      _units.length - 1,
    );
    final value = bytes / math.pow(1024, i);
    return '${value.toStringAsFixed(decimals)} ${_units[i]}';
  }

  /// Parses a human-readable size such as `'10 KB'` or `'2.5MB'` into bytes.
  ///
  /// Returns `0` when [text] cannot be parsed. Both `KB` and `K` style units
  /// are accepted, and a bare number is treated as bytes.
  int parse(String text) {
    final match = RegExp(r'^([\d.]+)\s*([A-Za-z]+)?$').firstMatch(text.trim());
    if (match == null) return 0;
    final value = double.tryParse(match.group(1)!) ?? 0;
    final unit = (match.group(2) ?? 'B').toUpperCase();
    const scales = <String, int>{
      'B': 1,
      'K': 1024,
      'KB': 1024,
      'M': 1024 * 1024,
      'MB': 1024 * 1024,
      'G': 1024 * 1024 * 1024,
      'GB': 1024 * 1024 * 1024,
      'T': 1024 * 1024 * 1024 * 1024,
      'TB': 1024 * 1024 * 1024 * 1024,
    };
    return (value * (scales[unit] ?? 1)).round();
  }
}
