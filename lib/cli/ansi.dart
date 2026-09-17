import 'dart:io';

/// Controller for ANSI escape codes and terminal color output.
///
/// Automatically disabled when `NO_COLOR` environment variable is set or when stdout does not support ANSI escapes.
///
/// {@category Terminal}
class Ansi {
  static bool? _override;

  /// Global regex pattern for matching ANSI escape sequences.
  static final RegExp escapePattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

  /// Whether ANSI styling is enabled.
  static bool get enabled {
    if (_override != null) return _override!;
    if (Platform.environment.containsKey('NO_COLOR') && Platform.environment['NO_COLOR']!.isNotEmpty) {
      return false;
    }
    try {
      return stdout.supportsAnsiEscapes;
    } catch (_) {
      return false;
    }
  }

  /// Manually override ANSI styling state.
  static set enabled(bool? value) {
    _override = value;
  }

  /// Strips all ANSI escape sequences from [text].
  static String strip(String text) => text.replaceAll(escapePattern, '');
}

/// ANSI terminal styling extensions on [String].
///
/// {@category Terminal}
extension AnsiString on String {
  /// Wraps this string in SGR [code], reopening it after any nested reset so that
  /// styles compose: `('a'.red + 'b').bold` leaves `b` bold.
  String _wrap(String code) {
    if (!Ansi.enabled) return this;
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
  String get stripped => Ansi.strip(this);
}
