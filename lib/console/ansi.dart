import 'dart:io';

// ============================================================================
// ANSI ESCAPE CODES & STRING STYLING
// ============================================================================

/// Utility class for ANSI escape codes, terminal styling, and color formatting.
class Ansi {
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
  static const String reset = '\x1B[0m';
  static const String bold = '\x1B[1m';
  static const String dim = '\x1B[2m';
  static const String italic = '\x1B[3m';
  static const String underline = '\x1B[4m';
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

  static String format(String text, String code) {
    if (!enabled) return text;
    return '$code$text$reset';
  }

  static String strip(String input) {
    return input.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }

  static int visibleLength(String input) => strip(input).length;
  static int len(String input) => visibleLength(input);
}

extension AnsiStringExtension on String {
  String bold() => Ansi.format(this, Ansi.bold);
  String dim() => Ansi.format(this, Ansi.dim);
  String italic() => Ansi.format(this, Ansi.italic);
  String underline() => Ansi.format(this, Ansi.underline);
  String inverse() => Ansi.format(this, Ansi.inverse);

  String red() => Ansi.format(this, Ansi.red);
  String green() => Ansi.format(this, Ansi.green);
  String yellow() => Ansi.format(this, Ansi.yellow);
  String blue() => Ansi.format(this, Ansi.blue);
  String magenta() => Ansi.format(this, Ansi.magenta);
  String cyan() => Ansi.format(this, Ansi.cyan);
  String white() => Ansi.format(this, Ansi.white);
  String gray() => Ansi.format(this, Ansi.gray);

  String brightRed() => Ansi.format(this, Ansi.brightRed);
  String brightGreen() => Ansi.format(this, Ansi.brightGreen);
  String brightYellow() => Ansi.format(this, Ansi.brightYellow);
  String brightBlue() => Ansi.format(this, Ansi.brightBlue);
  String brightMagenta() => Ansi.format(this, Ansi.brightMagenta);
  String brightCyan() => Ansi.format(this, Ansi.brightCyan);
  String brightWhite() => Ansi.format(this, Ansi.brightWhite);

  String bgRed() => Ansi.format(this, Ansi.bgRed);
  String bgGreen() => Ansi.format(this, Ansi.bgGreen);
  String bgYellow() => Ansi.format(this, Ansi.bgYellow);
  String bgBlue() => Ansi.format(this, Ansi.bgBlue);
  String bgCyan() => Ansi.format(this, Ansi.bgCyan);

  int get visibleLength => Ansi.visibleLength(this);
  int get len => visibleLength;
  String get stripAnsi => Ansi.strip(this);
}
