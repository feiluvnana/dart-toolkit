import 'dart:io';

// ============================================================================
// ANSI ESCAPE CODES & STRING STYLING
// ============================================================================

/// Utility class for ANSI escape sequences, color formatting, and visibility calculation.
class Ansi {
  static bool? _overrideEnabled;

  /// Whether ANSI styling is enabled.
  ///
  /// Evaluated dynamically:
  /// - `true` if `FORCE_COLOR` is set (and not '0'/'false'),
  /// - `false` if `NO_COLOR` is set and non-empty,
  /// - otherwise falls back to `stdout.hasTerminal`.
  static bool get enabled {
    if (_overrideEnabled != null) return _overrideEnabled!;
    return detect();
  }

  static set enabled(bool value) {
    _overrideEnabled = value;
  }

  /// Resets the override, returning to dynamic environment detection.
  static void refresh() {
    _overrideEnabled = null;
  }

  /// Dynamically detects whether the current environment supports ANSI colors.
  static bool detect() {
    try {
      final env = Platform.environment;
      final forceColor = env['FORCE_COLOR'];
      if (forceColor != null &&
          forceColor.isNotEmpty &&
          forceColor != '0' &&
          forceColor.toLowerCase() != 'false') {
        return true;
      }
      final noColor = env['NO_COLOR'];
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
  static const String brightred = '\x1B[91m';
  static const String brightgreen = '\x1B[92m';
  static const String brightyellow = '\x1B[93m';
  static const String brightblue = '\x1B[94m';
  static const String brightmagenta = '\x1B[95m';
  static const String brightcyan = '\x1B[96m';
  static const String brightwhite = '\x1B[97m';

  // Background Colors
  static const String bgblack = '\x1B[40m';
  static const String bgred = '\x1B[41m';
  static const String bggreen = '\x1B[42m';
  static const String bgyellow = '\x1B[43m';
  static const String bgblue = '\x1B[44m';
  static const String bgmagenta = '\x1B[45m';
  static const String bgcyan = '\x1B[46m';
  static const String bgwhite = '\x1B[47m';

  /// 256-color foreground ANSI sequence for [code] (0-255).
  static String color256(int code) => '\x1B[38;5;${code.clamp(0, 255)}m';

  /// 256-color background ANSI sequence for [code] (0-255).
  static String bgcolor256(int code) => '\x1B[48;5;${code.clamp(0, 255)}m';

  /// Truecolor 24-bit RGB foreground ANSI sequence.
  static String rgb(int r, int g, int b) =>
      '\x1B[38;2;${r.clamp(0, 255)};${g.clamp(0, 255)};${b.clamp(0, 255)}m';

  /// Truecolor 24-bit RGB background ANSI sequence.
  static String bgrgb(int r, int g, int b) =>
      '\x1B[48;2;${r.clamp(0, 255)};${g.clamp(0, 255)};${b.clamp(0, 255)}m';

  /// Truecolor from hex string (e.g. `#FF0000` or `FF0000`).
  static String hex(String code) {
    final (r, g, b) = _parseHex(code);
    return rgb(r, g, b);
  }

  /// Truecolor background from hex string (e.g. `#FF0000` or `FF0000`).
  static String bghex(String code) {
    final (r, g, b) = _parseHex(code);
    return bgrgb(r, g, b);
  }

  static (int, int, int) _parseHex(String code) {
    var clean = code.replaceAll('#', '').trim();
    if (clean.length == 3) {
      clean = clean.split('').map((c) => '$c$c').join();
    }
    final val = int.tryParse(clean, radix: 16) ?? 0;
    return ((val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF);
  }

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
  static int width(String input) => strip(input).length;
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
  String brightred() => Ansi.format(this, Ansi.brightred);

  /// Formats the string with high-intensity bright green color.
  String brightgreen() => Ansi.format(this, Ansi.brightgreen);

  /// Formats the string with high-intensity bright yellow color.
  String brightyellow() => Ansi.format(this, Ansi.brightyellow);

  /// Formats the string with high-intensity bright blue color.
  String brightblue() => Ansi.format(this, Ansi.brightblue);

  /// Formats the string with high-intensity bright magenta color.
  String brightmagenta() => Ansi.format(this, Ansi.brightmagenta);

  /// Formats the string with high-intensity bright cyan color.
  String brightcyan() => Ansi.format(this, Ansi.brightcyan);

  /// Formats the string with high-intensity bright white color.
  String brightwhite() => Ansi.format(this, Ansi.brightwhite);

  /// Sets background color to red.
  String bgred() => Ansi.format(this, Ansi.bgred);

  /// Sets background color to green.
  String bggreen() => Ansi.format(this, Ansi.bggreen);

  /// Sets background color to yellow.
  String bgyellow() => Ansi.format(this, Ansi.bgyellow);

  /// Sets background color to blue.
  String bgblue() => Ansi.format(this, Ansi.bgblue);

  /// Sets background color to cyan.
  String bgcyan() => Ansi.format(this, Ansi.bgcyan);

  /// Formats the string with 256-color foreground.
  String color256(int code) => Ansi.format(this, Ansi.color256(code));

  /// Formats the string with 256-color background.
  String bgcolor256(int code) => Ansi.format(this, Ansi.bgcolor256(code));

  /// Formats the string with truecolor 24-bit RGB foreground.
  String rgb(int r, int g, int b) => Ansi.format(this, Ansi.rgb(r, g, b));

  /// Formats the string with truecolor 24-bit RGB background.
  String bgrgb(int r, int g, int b) => Ansi.format(this, Ansi.bgrgb(r, g, b));

  /// Formats the string with hex color foreground (e.g. `#E67E22`).
  String hex(String code) => Ansi.format(this, Ansi.hex(code));

  /// Formats the string with hex color background (e.g. `#1B2631`).
  String bghex(String code) => Ansi.format(this, Ansi.bghex(code));

  /// Returns the printable visible length of the string, excluding ANSI codes.
  int get width => Ansi.width(this);

  /// Returns a clean copy of the string with all ANSI escape codes stripped.
  String get plain => Ansi.strip(this);
}
