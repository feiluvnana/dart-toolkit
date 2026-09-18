import 'dart:io';

import '../util/env.dart';
import '../util/stdio.dart';

/// Controller for ANSI escape codes and terminal color output.
///
/// Automatically disabled when `NO_COLOR` environment variable is set or when stdout does not support ANSI escapes.
///
/// {@category CLI}
class Ansi {
  static bool? _override;

  /// Global regex pattern for matching ANSI escape sequences.
  static final RegExp escapePattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

  /// Whether ANSI styling is enabled.
  ///
  /// Resolution order: an explicit [enabled] override, then `NO_COLOR`, then the
  /// active sink — redirecting [ConsoleIo.out] disables styling so
  /// captured output is plain, unless an override says otherwise.
  static bool get enabled {
    if (_override != null) return _override!;
    if (ConsoleIo.isRedirected) return false;
    if (Env.has('NO_COLOR')) return false;
    return _terminal;
  }

  /// Whether the process's stdout takes escapes: a native call, asked once.
  static final bool _terminal = () {
    try {
      return stdout.supportsAnsiEscapes;
    } catch (_) {
      return false;
    }
  }();

  /// Manually override ANSI styling state.
  static set enabled(bool? value) {
    _override = value;
  }

  /// Strips all ANSI escape sequences from [text].
  static String strip(String text) => text.replaceAll(escapePattern, '');
}

/// ANSI terminal styling extensions on [String].
///
/// {@category CLI}
extension StringAnsiExtensions on String {
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
