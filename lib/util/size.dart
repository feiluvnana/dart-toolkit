/// # Byte sizes
///
/// Single source of truth for human-readable byte sizes: [formatBytes] writes
/// one, [parseBytes] reads one back. Used by the console progress bar.
///
/// **Binary units, spelled as binary units.** The arithmetic here has always
/// been 1024-based and the labels said `KB`, `MB`, `GB`, so a terabyte of disk
/// formatted as `'931.3 GB'` and `parseBytes('5MB')` answered 5,242,880 — five
/// *mebibytes* under a name that means five million. The arithmetic stayed and
/// the labels were fixed: [formatBytes] writes `KiB`/`MiB`/`GiB`, and
/// [parseBytes] accepts both families, giving each the scale its name carries.
/// {@category Utilities}
library;

import 'dart:math' as math;

const List<String> _units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];

// Petabytes are here because [formatBytes] can write them: a table that
// stopped at TB made `parseBytes(formatBytes(n))` answer 0 for a large enough n.
const Map<String, num> _scales = <String, num>{
  'B': 1,
  // Binary, 1024-based: the units [formatBytes] writes, plus the bare letter,
  // which is how a command line has always spelled the binary one.
  'K': 1024,
  'KIB': 1024,
  'M': 1024 * 1024,
  'MIB': 1024 * 1024,
  'G': 1024 * 1024 * 1024,
  'GIB': 1024 * 1024 * 1024,
  'T': 1024 * 1024 * 1024 * 1024,
  'TIB': 1024 * 1024 * 1024 * 1024,
  'P': 1024 * 1024 * 1024 * 1024 * 1024,
  'PIB': 1024 * 1024 * 1024 * 1024 * 1024,
  // Decimal, 1000-based: what KB and MB mean, and what a disk is sold as.
  'KB': 1000,
  'MB': 1000 * 1000,
  'GB': 1000 * 1000 * 1000,
  'TB': 1000 * 1000 * 1000 * 1000,
  'PB': 1000 * 1000 * 1000 * 1000 * 1000,
};

final RegExp _sizePattern = RegExp(r'^(-?[\d.]+)\s*([A-Za-z]+)?$');

String _formatBytes(num bytes, {int decimals = 1}) {
  if (bytes == 0) return '0 B';
  final sign = bytes < 0 ? '-' : '';
  final magnitude = bytes.abs().floor();
  if (magnitude == 0) return '0 B';
  if (magnitude < 1024) return '$sign$magnitude B';

  var i = (math.log(magnitude) / math.log(1024)).floor().clamp(
    1,
    _units.length - 1,
  );
  var value = magnitude / math.pow(1024, i);
  // Rounding can push the value up to a full 1024 of its unit — 1048575 bytes
  // is '1024.0 KiB' before this, where '1.0 MiB' is what it means.
  if (i < _units.length - 1 &&
      double.parse(value.toStringAsFixed(decimals)) >= 1024) {
    i++;
    value = magnitude / math.pow(1024, i);
  }
  return '$sign${value.toStringAsFixed(decimals)} ${_units[i]}';
}

int? _parseBytes(String text) {
  final match = _sizePattern.firstMatch(text.trim());
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!);
  if (value == null) return null;
  final scale = _scales[(match.group(2) ?? 'B').toUpperCase()];
  return scale == null ? null : (value * scale).round();
}

/// Byte-size formatting and unit arithmetic on [num].
extension NumSizeExtension on num {
  /// Formats this number of bytes as a human-readable string (e.g. `'1.5 MiB'`).
  String formatBytes({int decimals = 1}) =>
      _formatBytes(this, decimals: decimals);

  /// Number of bytes (self).
  num get bytes => this;

  /// Kibibytes in bytes (1024).
  num get kb => this * 1024;

  /// Mebibytes in bytes (1024 * 1024).
  num get mb => this * 1024 * 1024;

  /// Gibibytes in bytes (1024 * 1024 * 1024).
  num get gb => this * 1024 * 1024 * 1024;
}

/// A written byte size, read back as a number.
///
/// The same family as `.url`, `.path`, `.date` and `.duration`: *this string,
/// read as something*.
extension StringSizeExtension on String {
  /// This size read as a number of bytes, or `null` when it is not one.
  ///
  /// ```dart
  /// '10 KiB'.bytes;   // 10240
  /// '10 KB'.bytes;    // 10000
  /// '10 K'.bytes;     // 10240 — bare letters are binary
  /// '512'.bytes;      // 512   — a bare number is bytes
  /// '10 XB'.bytes;    // null
  /// ```
  ///
  /// Both families are accepted and each means what it says: `KiB`/`MiB` and
  /// the bare `K`/`M` are 1024-based, `KB`/`MB` are 1000-based. Every unit
  /// [NumSizeExtension.formatBytes] writes reads back. A unit this does not
  /// know is `null`, because reading `'10 XB'` as ten bytes would be a wrong
  /// answer dressed as a right one.
  int? get bytes => _parseBytes(this);
}
