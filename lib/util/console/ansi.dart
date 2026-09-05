import 'dart:io';

// ============================================================================
// ANSI ESCAPE CODES & STRING STYLING
// ============================================================================

/// Utility class for ANSI escape sequences, color formatting, and visibility calculation.
class Ansi {
  /// Whether ANSI styling is enabled. Automatically disabled if `NO_COLOR` is set or stdout lacks a terminal.
  static bool enabled = _detectSupport();

  static bool _detectSupport() {
    try {
      final noColor = Platform.environment['NO_COLOR'];
      if (noColor != null && noColor.isNotEmpty) return false;
      return stdout.hasTerminal;
    } catch (_) {
      return false;
    }
  }

  // Styles
  /// Reset all styling and colors.
  static const String reset = '\x1B[0m';

  /// Bold text style.
  static const String bold = '\x1B[1m';

  /// Dim / low-intensity text style.
  static const String dim = '\x1B[2m';

  /// Italic text style.
  static const String italic = '\x1B[3m';

  /// Underlined text style.
  static const String underline = '\x1B[4m';

  /// Inverted foreground and background colors.
  static const String inverse = '\x1B[7m';

  // Foreground Colors
  static const String black = '\x1B[30m';
  static const String red = '\x1B[31m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String blue = '\x1B[34m';
  static const String magenta = '\x1B[35m';
  static const String cyan = '\x1B[36m';
  static const String white = '\x1B[37m';
  static const String gray = '\x1B[90m';

  // Bright Foreground Colors
  static const String brightRed = '\x1B[91m';
  static const String brightGreen = '\x1B[92m';
  static const String brightYellow = '\x1B[93m';
  static const String brightBlue = '\x1B[94m';
  static const String brightMagenta = '\x1B[95m';
  static const String brightCyan = '\x1B[96m';
  static const String brightWhite = '\x1B[97m';

  // Background Colors
  static const String bgBlack = '\x1B[40m';
  static const String bgRed = '\x1B[41m';
  static const String bgGreen = '\x1B[42m';
  static const String bgYellow = '\x1B[43m';
  static const String bgBlue = '\x1B[44m';
  static const String bgMagenta = '\x1B[45m';
  static const String bgCyan = '\x1B[46m';
  static const String bgWhite = '\x1B[47m';

  /// Wraps [text] with ANSI [code] and resets it if [enabled] is true.
  static String format(String text, String code) {
    if (!enabled) return text;
    return '$code$text$reset';
  }

  /// Removes all ANSI escape codes from [input].
  static String strip(String input) {
    return input.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }

  /// Calculates the visible printable character length of [input], ignoring ANSI escape sequences.
  static int visibleLength(String input) => strip(input).length;
}

/// Convenience extensions for applying ANSI styles and colors directly to strings.
extension AnsiStringExtension on String {
  /// Formats the string with bold styling.
  String bold() => Ansi.format(this, Ansi.bold);

  /// Formats the string with dim / reduced opacity styling.
  String dim() => Ansi.format(this, Ansi.dim);

  /// Formats the string with italic styling.
  String italic() => Ansi.format(this, Ansi.italic);

  /// Formats the string with underline styling.
  String underline() => Ansi.format(this, Ansi.underline);

  /// Formats the string with inverted foreground/background styling.
  String inverse() => Ansi.format(this, Ansi.inverse);

  /// Formats the string with standard red color.
  String red() => Ansi.format(this, Ansi.red);

  /// Formats the string with standard green color.
  String green() => Ansi.format(this, Ansi.green);

  /// Formats the string with standard yellow color.
  String yellow() => Ansi.format(this, Ansi.yellow);

  /// Formats the string with standard blue color.
  String blue() => Ansi.format(this, Ansi.blue);

  /// Formats the string with standard magenta color.
  String magenta() => Ansi.format(this, Ansi.magenta);

  /// Formats the string with standard cyan color.
  String cyan() => Ansi.format(this, Ansi.cyan);

  /// Formats the string with standard white color.
  String white() => Ansi.format(this, Ansi.white);

  /// Formats the string with gray color.
  String gray() => Ansi.format(this, Ansi.gray);

  /// Formats the string with high-intensity bright red color.
  String brightRed() => Ansi.format(this, Ansi.brightRed);

  /// Formats the string with high-intensity bright green color.
  String brightGreen() => Ansi.format(this, Ansi.brightGreen);

  /// Formats the string with high-intensity bright yellow color.
  String brightYellow() => Ansi.format(this, Ansi.brightYellow);

  /// Formats the string with high-intensity bright blue color.
  String brightBlue() => Ansi.format(this, Ansi.brightBlue);

  /// Formats the string with high-intensity bright magenta color.
  String brightMagenta() => Ansi.format(this, Ansi.brightMagenta);

  /// Formats the string with high-intensity bright cyan color.
  String brightCyan() => Ansi.format(this, Ansi.brightCyan);

  /// Formats the string with high-intensity bright white color.
  String brightWhite() => Ansi.format(this, Ansi.brightWhite);

  /// Sets background color to red.
  String bgRed() => Ansi.format(this, Ansi.bgRed);

  /// Sets background color to green.
  String bgGreen() => Ansi.format(this, Ansi.bgGreen);

  /// Sets background color to yellow.
  String bgYellow() => Ansi.format(this, Ansi.bgYellow);

  /// Sets background color to blue.
  String bgBlue() => Ansi.format(this, Ansi.bgBlue);

  /// Sets background color to cyan.
  String bgCyan() => Ansi.format(this, Ansi.bgCyan);

  /// Returns the printable visible length of the string, excluding ANSI codes.
  int get visibleLength => Ansi.visibleLength(this);

  /// Returns a clean copy of the string with all ANSI escape codes stripped.
  String get stripAnsi => Ansi.strip(this);
}
