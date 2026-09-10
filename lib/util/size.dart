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
    var i = (math.log(bytes) / math.log(1024)).floor().clamp(
      0,
      _units.length - 1,
    );
    var value = bytes / math.pow(1024, i);
    // Rounding can push the value up to a full 1024 of its unit — 1048575
    // bytes is '1024.0 KB' before this, where '1.0 MB' is what it means.
    if (i < _units.length - 1 &&
        double.parse(value.toStringAsFixed(decimals)) >= 1024) {
      i++;
      value = bytes / math.pow(1024, i);
    }
    return '${value.toStringAsFixed(decimals)} ${_units[i]}';
  }

  /// Parses a human-readable size such as `'10 KB'` or `'2.5MB'` into bytes.
  ///
  /// Returns `0` when [text] cannot be parsed, including when it carries a
  /// unit this does not know — reading `'10 XB'` as ten bytes would be a
  /// wrong answer dressed as a right one. Both `KB` and `K` style units are
  /// accepted, and a bare number is treated as bytes.
  ///
  /// Every unit [format] writes reads back, so `parse(format(n))` is `n`
  /// rounded to the digits it printed.
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
      // Petabytes are here because [format] can write them: a table that
      // stopped at TB made `parse(format(n))` answer 0 for a large enough n.
      'P': 1024 * 1024 * 1024 * 1024 * 1024,
      'PB': 1024 * 1024 * 1024 * 1024 * 1024,
    };
    final scale = scales[unit];
    if (scale == null) return 0;
    return (value * scale).round();
  }
}
