part of '../../cli.dart';

/// ANSI terminal styling extensions on [String].
///
/// {@category CLI}
extension StringAnsiExtensions on String {
  /// Wraps this string in SGR [code], reopening it after any nested reset so that
  /// styles compose: `('a'.red + 'b').bold` leaves `b` bold.
  String _wrap(String code) {
    if (!Io.color) return this;
    final reopened = replaceAll('\x1B[0m', '\x1B[0m\x1B[${code}m');
    return '\x1B[${code}m$reopened\x1B[0m';
  }

  String get red => _wrap('31');
  String get green => _wrap('32');
  String get yellow => _wrap('33');
  String get blue => _wrap('34');
  String get magenta => _wrap('35');
  String get cyan => _wrap('36');
  String get grey => _wrap('90');
  String get bold => _wrap('1');
  String get dim => _wrap('2');
  String get italic => _wrap('3');
  String get underline => _wrap('4');

  /// Returns this string with all ANSI escape codes stripped.
  String get stripped => Io.stripAnsi(this);
}
