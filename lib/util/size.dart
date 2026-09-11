/// # Byte Size Formatting & Parsing (`util.size.*`)
///
/// Single source of truth for human-readable byte sizes. Used by the console
/// progress bar and available directly as `util.size.format` / `util.size.parse`.
///
/// **Binary units, spelled as binary units.** The arithmetic here has always
/// been 1024-based and the labels said `KB`, `MB`, `GB`, so `format` reported
/// a terabyte of disk as `'931.3 GB'` and `parse('5MB')` answered 5,242,880 —
/// five *mebibytes* under a name that means five million. 5.0.0 keeps the
/// arithmetic and fixes the labels: `format` writes `KiB`/`MiB`/`GiB`, and
/// `parse` accepts both families and gives each the scale its name actually
/// carries.
library;

import 'dart:math' as math;

/// Formats and parses human-readable byte sizes.
///
/// Reachable as `util.size`:
///
/// ```dart
/// util.size.format(5 * 1024 * 1024); // '5.0 MiB'
/// util.size.parse('2.5 MiB');        // 2621440
/// util.size.parse('2.5 MB');         // 2500000
/// ```
class SizeAccessor {
  /// Creates the accessor. Prefer the shared `util.size` instance.
  const SizeAccessor();

  static const List<String> _units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];

  /// Renders [bytes] as a human-readable string, e.g. `'1.0 KiB'`.
  ///
  /// [decimals] controls the fraction digits above a kibibyte; a count in
  /// plain bytes has no fraction to show, so `format(1023)` is `'1023 B'` and
  /// not `'1023.0 B'`.
  ///
  /// A negative count keeps its sign — `format(-2048)` is `'-2.0 KiB'` —
  /// because a script that subtracted two sizes in the order it had them
  /// should see which way round they were rather than `'0 B'`.
  ///
  /// [bytes] is a `num` because `collect(.sum(...))` returns one: totalling
  /// the sizes of a directory and printing the total was
  /// `util.size.format(total.toInt())` through 6.2.0, a cast the caller made
  /// only to satisfy this signature. A fractional count is floored, which is
  /// the byte it names.
  String format(num bytes, {int decimals = 1}) {
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
    // Rounding can push the value up to a full 1024 of its unit — 1048575
    // bytes is '1024.0 KiB' before this, where '1.0 MiB' is what it means.
    if (i < _units.length - 1 &&
        double.parse(value.toStringAsFixed(decimals)) >= 1024) {
      i++;
      value = magnitude / math.pow(1024, i);
    }
    return '$sign${value.toStringAsFixed(decimals)} ${_units[i]}';
  }

  /// Parses a human-readable size such as `'10 KiB'` or `'2.5MB'` into bytes.
  ///
  /// Returns `null` when [text] is not a size — including when it carries a
  /// unit this does not know, because reading `'10 XB'` as ten bytes would be
  /// a wrong answer dressed as a right one. Through 4.0.0 this returned `0`
  /// for all three cases, which is a value a caller cannot tell apart from an
  /// empty file; Rule 4 says the honest answer is that there is not one.
  ///
  /// ```dart
  /// util.size.parse('10 KiB');   // 10240
  /// util.size.parse('10 KB');    // 10000
  /// util.size.parse('10 K');     // 10240 — bare letters are binary
  /// util.size.parse('512');      // 512   — a bare number is bytes
  /// util.size.parse('10 XB');    // null
  /// ```
  ///
  /// Both families are accepted and each means what it says: `KiB`/`MiB` and
  /// the bare `K`/`M` are 1024-based, `KB`/`MB` are 1000-based. Every unit
  /// [format] writes reads back, so `parse(format(n))` is `n` rounded to the
  /// digits it printed.
  ///
  /// A negative size parses, matching [format].
  int? parse(String text) {
    final match = RegExp(
      r'^(-?[\d.]+)\s*([A-Za-z]+)?$',
    ).firstMatch(text.trim());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    final scale = _scales[(match.group(2) ?? 'B').toUpperCase()];
    return scale == null ? null : (value * scale).round();
  }

  // Petabytes are here because [format] can write them: a table that stopped
  // at TB made `parse(format(n))` answer 0 for a large enough n.
  static const _scales = <String, num>{
    'B': 1,
    // Binary, 1024-based: the units [format] writes, plus the bare letter,
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
}
