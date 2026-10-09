part of '../core.dart';

/// Text read as a typed value.
///
/// {@category Utilities}
extension StringExtensions on String {
  /// This text read as [T], as every typed reading reads a value (`doc.to<T>`, `row.get<T>`,
  /// `Env.get<T>`): `int`, `double`, `num` (`'1,200'`, `'42.0'`, a size `'1.5 GB'` in bytes),
  /// `bool` (`yes`, `true`, `1`), `Duration` (`'90s'`, `'1h 30m'`, `'3:45'`, `'PT4M13S'`),
  /// `DateTime` (ISO 8601, RFC 1123/822 as headers and feeds write it, or [format] such as
  /// `'dd.MM.yyyy'` or `'MMM dd, yyyy'`; a date without a zone is UTC), `Uri` or `String`.
  /// [decimal] is the decimal mark (`','` for `'1.234,5'`).
  ///
  /// Blank text is absence: [or], `null` for a nullable [T], else a [MissingException]. Text that
  /// is there but does not read as [T] is a [FormatException] naming it, which [or] does not
  /// answer; a [T] no reading makes is an [ArgumentError].
  ///
  /// ```dart
  /// '42'.to<int>();
  /// Option.by('wait', (s) => s.to<Duration>(), 'How long to wait');
  /// ```
  T to<T>({T? or, String? format, String? decimal}) => _readText(this, or, format: format, decimal: decimal);
}

/// [text] read as [T], as `to<T>()` and `Env.get<T>` read it; [variable] names the environment
/// variable it came from. Blank or missing text is absence: [or], `null` for an asked-for `?`
/// (untyped still throws), else a [MissingException].
T _readText<T>(String? text, T? or, {String? format, String? decimal, String? variable}) {
  if (text == null || text.trim().isEmpty) {
    if (or != null) return or;
    if (null is T && T != _Unknown && T != dynamic) return null as T;
    throw variable == null
        ? MissingException('$T', where: 'blank text')
        : MissingException('variable $variable', where: 'the environment');
  }
  final value = CoerceBridge.coerce<T>(text, format: format, decimal: decimal ?? '.');
  if (value != null) return value;
  if (!CoerceBridge.reads<T>()) {
    throw ArgumentError(
      'Invalid type $T: expected String, int, double, num, bool, Duration, DateTime, Uri, Path or Secret',
    );
  }
  throw FormatException(variable == null ? 'Invalid $T: "$text"' : 'Invalid variable $variable: "$text", expected $T');
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
int compareNatural(String a, String b) => switch (_compareKeys(a, b)) {
  0 => a.compareTo(b),
  final c => c,
};

final _windows = Platform.isWindows;

/// [a] and [b] compared as their [_naturalKey]s are, without making them: a sort compares each
/// name many times. Text beyond ASCII, whose lower case can change its length, makes the keys.
int _compareKeys(String a, String b) {
  final n = a.length, m = b.length;
  var i = 0, j = 0;
  while (i < n && j < m) {
    final x = a.codeUnitAt(i), y = b.codeUnitAt(j);
    if (x >= 0x80 || y >= 0x80) return _naturalKey(a).compareTo(_naturalKey(b));
    if (_digit(x) && _digit(y)) {
      // A run of digits keys as its length without leading zeros, then those digits.
      while (i + 1 < n && a.codeUnitAt(i) == 0x30 && _digit(a.codeUnitAt(i + 1))) {
        i++;
      }
      while (j + 1 < m && b.codeUnitAt(j) == 0x30 && _digit(b.codeUnitAt(j + 1))) {
        j++;
      }
      var ei = i, ej = j;
      while (ei < n && _digit(a.codeUnitAt(ei))) {
        ei++;
      }
      while (ej < m && _digit(b.codeUnitAt(ej))) {
        ej++;
      }
      if (ei - i != ej - j) return (ei - i) - (ej - j);
      for (; i < ei; i++, j++) {
        final d = a.codeUnitAt(i) - b.codeUnitAt(j);
        if (d != 0) return d;
      }
      continue;
    }
    final d = _keyUnit(x) - _keyUnit(y);
    if (d != 0) return d;
    i++;
    j++;
  }
  return (n - i).sign - (m - j).sign;
}

/// An ASCII unit as [_naturalKey] writes it: lower case, a separator `0`, a digit's run `0`.
int _keyUnit(int c) {
  if (_digit(c)) return 0x30;
  if (c == 0x2f || (_windows && c == 0x5c)) return 0;
  return c >= 0x41 && c <= 0x5a ? c + 0x20 : c;
}

/// [s] as a key whose plain order is natural order: lower-cased; each `/` (and `\\` on Windows)
/// made `\u0000`, below every other character, so segments compare one by one and `a` sorts
/// before `a/b`; each run of digits written as `0`, its length without leading zeros, then those
/// digits, so longer numbers sort later and `01` keys as `1`. The `0` keeps a number where a
/// digit sorts against any other character.
String _naturalKey(String s) {
  final lower = s.toLowerCase();
  final windows = _windows;
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
