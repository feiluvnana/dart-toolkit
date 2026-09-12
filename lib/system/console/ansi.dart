/// # ANSI Colours & Styling
///
/// **The extension is the surface; [Ansi] is the mechanism.** `'ok'.green()`
/// is what a script writes, and `Ansi.format('ok', Ansi.green)` reads worse
/// in every way — so [AnsiStringExtension] carries one member per code and
/// [Ansi] carries the codes, the detection and the builders those members are
/// defined over.
///
/// Through 5.5.0 both were sold as the API, and it cost exactly what two
/// spellings always cost: `Ansi.strip` and `String.plain` were one answer
/// under two words, `Ansi.width` and `String.width` likewise, and four codes
/// — `black`, `bgblack`, `bgmagenta`, `bgwhite` — had a constant and no
/// extension member, so `'x'.red()` worked and `'x'.black()` did not, with
/// nothing to say why. The mirror is complete now and a regression test pins
/// it: **every `static const String` code on [Ansi] has a member of the same
/// name on the extension.**
///
/// `String.width` measures what a terminal will actually render, which is
/// what every box in `system.console` lines its columns up with.
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
    return _detect();
  }

  static set enabled(bool value) {
    _overrideEnabled = value;
  }

  /// Resets the override, returning to dynamic environment detection.
  ///
  /// The public door to re-reading the environment. The detection itself is
  /// private — it was `Ansi.detect()` through 5.5.0, a third member for one
  /// boolean and its recomputation.
  static void refresh() {
    _overrideEnabled = null;
  }

  /// Dynamically detects whether the current environment supports ANSI colors.
  static bool _detect() {
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
  static const String brightRed = '\x1B[91m';

  /// Bright green foreground.
  static const String brightGreen = '\x1B[92m';

  /// Bright yellow foreground.
  static const String brightYellow = '\x1B[93m';

  /// Bright blue foreground.
  static const String brightBlue = '\x1B[94m';

  /// Bright magenta foreground.
  static const String brightMagenta = '\x1B[95m';

  /// Bright cyan foreground.
  static const String brightCyan = '\x1B[96m';

  /// Bright white foreground.
  static const String brightWhite = '\x1B[97m';

  // Background Colors
  /// Black background.
  static const String bgBlack = '\x1B[40m';

  /// Red background.
  static const String bgRed = '\x1B[41m';

  /// Green background.
  static const String bgGreen = '\x1B[42m';

  /// Yellow background.
  static const String bgYellow = '\x1B[43m';

  /// Blue background.
  static const String bgBlue = '\x1B[44m';

  /// Magenta background.
  static const String bgMagenta = '\x1B[45m';

  /// Cyan background.
  static const String bgCyan = '\x1B[46m';

  /// White background.
  static const String bgWhite = '\x1B[47m';

  // --------------------------------------------------------------------------
  /// 256-color foreground ANSI sequence for [code] (0-255).
  static String color256(int code) => '\x1B[38;5;${code.clamp(0, 255)}m';

  /// 256-color background ANSI sequence for [code] (0-255).
  static String bgColor256(int code) => '\x1B[48;5;${code.clamp(0, 255)}m';

  /// Truecolor 24-bit RGB foreground ANSI sequence.
  static String rgb(int r, int g, int b) =>
      '\x1B[38;2;${r.clamp(0, 255)};${g.clamp(0, 255)};${b.clamp(0, 255)}m';

  /// Truecolor 24-bit RGB background ANSI sequence.
  static String bgRgb(int r, int g, int b) =>
      '\x1B[48;2;${r.clamp(0, 255)};${g.clamp(0, 255)};${b.clamp(0, 255)}m';

  /// Truecolor from hex string (e.g. `#FF0000` or `FF0000`).
  static String hex(String code) {
    final (r, g, b) = _parseHex(code);
    return rgb(r, g, b);
  }

  /// Truecolor background from hex string (e.g. `#FF0000` or `FF0000`).
  static String bgHex(String code) {
    final (r, g, b) = _parseHex(code);
    return bgRgb(r, g, b);
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
  ///
  /// Private, because `input.plain` is the spelling — see
  /// [AnsiStringExtension.plain]. It was also `Ansi.strip` through 5.5.0, and
  /// `plain` is not short for `strip`: it is a second word for it.
  static String _strip(String input) {
    return input.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }

  /// The number of terminal columns [input] occupies, ANSI codes excluded.
  ///
  /// Private, for the reason [_strip] is: `input.width` is the spelling.
  ///
  /// Counting code units would be wrong in both directions: an emoji is two
  /// code units but two columns, a CJK ideograph is one code unit but two
  /// columns, and a combining accent is one code unit but no width at all.
  /// Every box drawn from this — tables, rules, progress bars — depends on
  /// the count matching what the terminal actually renders.
  static int _width(String input) {
    var columns = 0;
    for (final rune in _strip(input).runes) {
      columns += _runeWidth(rune);
    }
    return columns;
  }

  /// [input] broken into lines no wider than [width] terminal columns.
  ///
  /// Breaks at spaces where it can and inside a word where it cannot, measured
  /// in terminal columns rather than code units, so a wrapped cell of CJK or
  /// emoji
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
      if (Ansi._width(line) <= width) {
        lines.add(line);
        continue;
      }
      var current = '';
      for (final word in line.split(' ')) {
        final candidate = current.isEmpty ? word : '$current $word';
        if (Ansi._width(candidate) <= width) {
          current = candidate;
          continue;
        }
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }
        if (Ansi._width(word) <= width) {
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

/// Applying ANSI styles and colours to a string — **the colour surface**.
///
/// One member per code on [Ansi], with no holes: a regression test asserts
/// that every `static const String` there has a member of the same name here,
/// the same way the `io` / `io.async` mirror is pinned. Adding a colour is two
/// edits and forgetting one fails the build, which is how `black`, `bgblack`,
/// `bgmagenta` and `bgwhite` came to be missing in the first place.
///
/// [plain] and [width] are the only two members with no code behind them, and
/// they are the only spelling of what they do.
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

  /// Formats the string with standard black color.
  String black() => Ansi.format(this, Ansi.black);

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

  /// Sets background color to black.
  String bgBlack() => Ansi.format(this, Ansi.bgBlack);

  /// Sets background color to red.
  String bgRed() => Ansi.format(this, Ansi.bgRed);

  /// Sets background color to green.
  String bgGreen() => Ansi.format(this, Ansi.bgGreen);

  /// Sets background color to yellow.
  String bgYellow() => Ansi.format(this, Ansi.bgYellow);

  /// Sets background color to blue.
  String bgBlue() => Ansi.format(this, Ansi.bgBlue);

  /// Sets background color to magenta.
  String bgMagenta() => Ansi.format(this, Ansi.bgMagenta);

  /// Sets background color to cyan.
  String bgCyan() => Ansi.format(this, Ansi.bgCyan);

  /// Sets background color to white.
  String bgWhite() => Ansi.format(this, Ansi.bgWhite);

  /// Formats the string with 256-color foreground.
  String color256(int code) => Ansi.format(this, Ansi.color256(code));

  /// Formats the string with 256-color background.
  String bgColor256(int code) => Ansi.format(this, Ansi.bgColor256(code));

  /// Formats the string with truecolor 24-bit RGB foreground.
  String rgb(int r, int g, int b) => Ansi.format(this, Ansi.rgb(r, g, b));

  /// Formats the string with truecolor 24-bit RGB background.
  String bgRgb(int r, int g, int b) => Ansi.format(this, Ansi.bgRgb(r, g, b));

  /// Formats the string with hex color foreground (e.g. `#E67E22`).
  String hex(String code) => Ansi.format(this, Ansi.hex(code));

  /// Formats the string with hex color background (e.g. `#1B2631`).
  String bgHex(String code) => Ansi.format(this, Ansi.bgHex(code));

  /// The terminal columns this string occupies, ANSI codes excluded.
  ///
  /// The one spelling of the measurement. Counting code units would be wrong
  /// in both directions: an emoji is two code units but two columns, a CJK
  /// ideograph is one code unit but two, and a combining accent is one code
  /// unit and no width at all.
  int get width => Ansi._width(this);

  /// This string with every ANSI escape code removed.
  ///
  /// The one spelling of the removal.
  String get plain => Ansi._strip(this);
}
