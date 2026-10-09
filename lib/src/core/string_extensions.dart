part of '../core.dart';

/// Text read as a typed value.
///
/// {@category Utilities}
extension StringExtensions on String {
  /// This text read as [T], as every typed reading reads a value (`doc.to<T>`, `row.get<T>`,
  /// `Env.get<T>`): `int`, `double`, `num` (`'1,200'`, `'42.0'`, a size `'1.5 GB'` in bytes),
  /// `bool` (`yes`, `true`, `1`), `Duration` (`'90s'`, `'1h 30m'`, `'3:45'`, `'PT4M13S'`),
  /// `DateTime` (ISO 8601, RFC 1123/822 as headers and feeds write it, or [format] such as
  /// `'dd.MM.yyyy'` or `'MMM dd, yyyy'`), `Uri` or `String`. [decimal] is the decimal mark (`','`
  /// for `'1.234,5'`).
  ///
  /// Blank text is absence: [or], `null` for a nullable [T], else a [MissingException]. Text that
  /// is there but does not read as [T] is a [FormatException] naming it, which [or] does not
  /// answer.
  ///
  /// ```dart
  /// '42'.to<int>();
  /// Option.by('wait', (s) => s.to<Duration>(), 'How long to wait');
  /// ```
  T to<T>({T? or, String? format, String? decimal}) {
    if (trim().isEmpty) {
      if (or != null) return or;
      if (null is T) return null as T;
      throw MissingException('$T', where: 'blank text');
    }
    final value = CoerceBridge.coerce<T>(this, format: format, decimal: decimal ?? '.');
    if (value != null) return value;
    throw FormatException('Invalid $T: "$this"');
  }
}

/// Natural order, for `sort`: numbers compare by value, case is ignored, and a `/` separates
/// segments compared one by one, so `a2` comes before `a10` and `a/2.txt` before `a/10.txt`.
/// Ties fall back to plain order, so the result never depends on the input order.
///
/// ```dart
/// names.sort(compareNatural);
/// ```
///
/// {@category Utilities}
int compareNatural(String a, String b) => switch (_naturalKey(a).compareTo(_naturalKey(b))) {
  0 => a.compareTo(b),
  final c => c,
};

/// [s] as a key whose plain order is natural order: lower-cased; each `/` (and `\\` on Windows)
/// made `\u0000`, below every other character, so segments compare one by one and `a` sorts
/// before `a/b`; each run of digits written as `0`, its length without leading zeros, then those
/// digits, so longer numbers sort later and `01` keys as `1`. The `0` keeps a number where a
/// digit sorts against any other character.
String _naturalKey(String s) {
  final lower = s.toLowerCase();
  final windows = Platform.isWindows;
  final n = lower.length;
  // A run of k digits keys as at most k + 2 units, and runs sit apart: twice the length is room.
  final out = Uint16List(n * 2 + 2);
  var o = 0;
  for (var i = 0; i < n;) {
    final c = lower.codeUnitAt(i);
    if (!_digit(c)) {
      out[o++] = c == 0x2f || (windows && c == 0x5c) ? 0 : c;
      i++;
      continue;
    }
    while (i + 1 < n && lower.codeUnitAt(i) == 0x30 && _digit(lower.codeUnitAt(i + 1))) {
      i++;
    }
    var end = i;
    while (end < n && _digit(lower.codeUnitAt(end))) {
      end++;
    }
    out[o++] = 0x30;
    out[o++] = end - i;
    while (i < end) {
      out[o++] = lower.codeUnitAt(i++);
    }
  }
  return String.fromCharCodes(out, 0, o);
}

bool _digit(int c) => c >= 0x30 && c <= 0x39;
