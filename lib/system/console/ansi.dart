/// # ANSI Colours & Styling
///
/// Escape sequences, the detection that decides whether to emit them, and the
/// [AnsiStringExtension] helpers that wrap a string in one. [Ansi.width]
/// measures what a terminal will actually render, which is what every box in
/// `system.console` lines its columns up with.
library;

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
  /// Black foreground.
  static const String black = '\x1B[30m';

  /// Red foreground.
  static const String red = '\x1B[31m';

  /// Green foreground.
  static const String green = '\x1B[32m';

  /// Yellow foreground.
  static const String yellow = '\x1B[33m';

  /// Blue foreground.
  static const String blue = '\x1B[34m';

  /// Magenta foreground.
  static const String magenta = '\x1B[35m';

  /// Cyan foreground.
  static const String cyan = '\x1B[36m';

  /// White foreground.
  static const String white = '\x1B[37m';

  /// Gray foreground.
  static const String gray = '\x1B[90m';

  // Bright Foreground Colors
  /// Bright red foreground.
  static const String brightred = '\x1B[91m';

  /// Bright green foreground.
  static const String brightgreen = '\x1B[92m';

  /// Bright yellow foreground.
  static const String brightyellow = '\x1B[93m';

  /// Bright blue foreground.
  static const String brightblue = '\x1B[94m';

  /// Bright magenta foreground.
  static const String brightmagenta = '\x1B[95m';

  /// Bright cyan foreground.
  static const String brightcyan = '\x1B[96m';

  /// Bright white foreground.
  static const String brightwhite = '\x1B[97m';

  // Background Colors
  /// Black background.
  static const String bgblack = '\x1B[40m';

  /// Red background.
  static const String bgred = '\x1B[41m';

  /// Green background.
  static const String bggreen = '\x1B[42m';

  /// Yellow background.
  static const String bgyellow = '\x1B[43m';

  /// Blue background.
  static const String bgblue = '\x1B[44m';

  /// Magenta background.
  static const String bgmagenta = '\x1B[45m';

  /// Cyan background.
  static const String bgcyan = '\x1B[46m';

  /// White background.
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

  /// The number of terminal columns [input] occupies, ANSI codes excluded.
  ///
  /// Counting code units would be wrong in both directions: an emoji is two
  /// code units but two columns, a CJK ideograph is one code unit but two
  /// columns, and a combining accent is one code unit but no width at all.
  /// Every box drawn from this — tables, rules, progress bars — depends on
  /// the count matching what the terminal actually renders.
  static int width(String input) {
    var columns = 0;
    for (final rune in strip(input).runes) {
      columns += _runeWidth(rune);
    }
    return columns;
  }

  /// [input] broken into lines no wider than [width] terminal columns.
  ///
  /// Breaks at spaces where it can and inside a word where it cannot, measured
  /// by [width] rather than by code units, so a wrapped cell of CJK or emoji
  /// still fits the column it was cut for. Escape codes pass through without
  /// counting, and existing newlines in [input] are kept as breaks.
  ///
  /// ```dart
  /// Ansi.wrap('the quick brown fox', 9);  // ['the quick', 'brown fox']
  /// ```
  static List<String> wrap(String input, int width) {
    if (width <= 0) return [input];
    final lines = <String>[];
    for (final line in input.split('\n')) {
      if (Ansi.width(line) <= width) {
        lines.add(line);
        continue;
      }
      var current = '';
      for (final word in line.split(' ')) {
        final candidate = current.isEmpty ? word : '$current $word';
        if (Ansi.width(candidate) <= width) {
          current = candidate;
          continue;
        }
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }
        if (Ansi.width(word) <= width) {
          current = word;
          continue;
        }
        // A word wider than the column has to be cut somewhere.
        final pieces = _cut(word, width);
        lines.addAll(pieces.take(pieces.length - 1));
        current = pieces.last;
      }
      if (current.isNotEmpty) lines.add(current);
    }
    return lines.isEmpty ? const [''] : lines;
  }

  /// [text] cut into pieces of at most [width] columns, mid-word if need be.
  static List<String> _cut(String text, int width) {
    final pieces = <String>[];
    final buffer = StringBuffer();
    final runes = text.runes.toList();
    var used = 0;
    var i = 0;
    while (i < runes.length) {
      if (runes[i] == 0x1B) {
        // An escape sequence is carried along whole and costs no columns.
        final start = i;
        i++;
        if (i < runes.length && runes[i] == 0x5B) {
          i++;
          while (i < runes.length && (runes[i] < 0x40 || runes[i] > 0x7E)) {
            i++;
          }
          if (i < runes.length) i++;
        }
        buffer.write(String.fromCharCodes(runes.getRange(start, i)));
        continue;
      }
      final columns = _runeWidth(runes[i]);
      if (used + columns > width && used > 0) {
        pieces.add(buffer.toString());
        buffer.clear();
        used = 0;
      }
      buffer.writeCharCode(runes[i]);
      used += columns;
      i++;
    }
    if (buffer.isNotEmpty) pieces.add(buffer.toString());
    return pieces.isEmpty ? const [''] : pieces;
  }

  /// How many columns one code point occupies.
  static int _runeWidth(int rune) {
    // Combining marks and zero-width joiners hang off the previous character.
    if (rune == 0x200B ||
        rune == 0x200C ||
        rune == 0x200D ||
        rune == 0xFEFF ||
        (rune >= 0x0300 && rune <= 0x036F) ||
        (rune >= 0x1AB0 && rune <= 0x1AFF) ||
        (rune >= 0x20D0 && rune <= 0x20FF) ||
        (rune >= 0xFE00 && rune <= 0xFE0F)) {
      return 0;
    }
    return _isWide(rune) ? 2 : 1;
  }

  /// Whether [rune] is East Asian Wide or Fullwidth, or an emoji presentation.
  ///
  /// The ranges follow Unicode's East Asian Width property, kept as a short
  /// table rather than a dependency: these are the blocks scraped pages and
  /// terminal output actually carry.
  static bool _isWide(int rune) =>
      (rune >= 0x1100 && rune <= 0x115F) || // Hangul Jamo
      (rune >= 0x2E80 && rune <= 0x303E) || // CJK radicals, Kangxi
      (rune >= 0x3041 && rune <= 0x33FF) || // Hiragana .. CJK compatibility
      (rune >= 0x3400 && rune <= 0x4DBF) || // CJK extension A
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK unified
      (rune >= 0xA000 && rune <= 0xA4CF) || // Yi
      (rune >= 0xAC00 && rune <= 0xD7A3) || // Hangul syllables
      (rune >= 0xF900 && rune <= 0xFAFF) || // CJK compatibility ideographs
      (rune >= 0xFE10 && rune <= 0xFE19) || // Vertical forms
      (rune >= 0xFE30 && rune <= 0xFE6F) || // CJK compatibility forms
      (rune >= 0xFF00 && rune <= 0xFF60) || // Fullwidth forms
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      (rune >= 0x1F300 && rune <= 0x1F64F) || // Emoji, emoticons
      (rune >= 0x1F900 && rune <= 0x1F9FF) ||
      (rune >= 0x1FA70 && rune <= 0x1FAFF) ||
      (rune >= 0x20000 && rune <= 0x3FFFD); // CJK extensions B+
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
