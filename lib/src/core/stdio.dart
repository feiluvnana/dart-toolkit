part of '../../core.dart';

/// The process's standard I/O, injectable: every console write and read goes through it.
///
/// {@category CLI}
class Io {
  static StringSink? _out;
  static StringSink? _err;

  /// Replaces standard input. Return `null` to signal end of input, which lets
  /// tests and non-interactive runs exercise the EOF path of [Prompt].
  static String? Function()? input;

  /// The active standard output sink. Assign to redirect it; assign `null` to restore.
  static StringSink get out => _out ?? _stdout;
  static set out(StringSink? sink) => _out = sink;

  /// The active standard error sink. Assign to redirect it; assign `null` to restore.
  static StringSink get err => _err ?? _stderr;
  static set err(StringSink? sink) => _err = sink;

  /// The process sinks with a closed pipe made harmless: `app --help | head` ends the
  /// reader early, and without this the write that follows is an unhandled `Broken pipe`.
  static final IOSink _stdout = _quiet(stdout);
  static final IOSink _stderr = _quiet(stderr);

  static IOSink _quiet(IOSink sink) {
    sink.done.catchError((_) {});
    return sink;
  }

  /// Whether output is going somewhere other than the process's own stdout.
  static bool get isRedirected => _out != null;

  /// Whether the *active* output sink is an interactive terminal.
  ///
  /// Redirecting [out] must also redirect the decision about what to render, so
  /// every cursor-control path gates on this rather than on `stdout.hasTerminal`.
  static bool get isTerminal {
    if (isRedirected) return false;
    try {
      return stdout.hasTerminal;
    } catch (_) {
      return false;
    }
  }

  /// The width of the active terminal, or `null` when there is no terminal.
  static int? get columns {
    if (!isTerminal) return null;
    try {
      return stdout.terminalColumns;
    } catch (_) {
      return null;
    }
  }

  /// Reads a line from standard input or the [input] override.
  static String? readLine({Encoding encoding = utf8}) =>
      input != null ? input!() : stdin.readLineSync(encoding: encoding);

  /// Resets all custom I/O overrides.
  static void reset() {
    _out = null;
    _err = null;
    input = null;
  }

  /// Whether ANSI styling is enabled.
  ///
  /// Resolution order: an explicit assignment here, then `NO_COLOR`, then the active sink —
  /// redirecting [out] disables styling so captured output is plain. Assign `null` to
  /// restore the automatic answer.
  ///
  /// This lives beside [out], [isTerminal] and [width] because it is the same question they
  /// answer: what the active sink can render.
  static bool get color {
    if (_color != null) return _color!;
    if (isRedirected) return false;
    if (Env.has('NO_COLOR')) return false;
    return _ansiTerminal;
  }

  static set color(bool? value) => _color = value;

  static bool? _color;

  /// Whether the process's stdout takes escapes: a native call, asked once.
  static final bool _ansiTerminal = () {
    try {
      return stdout.supportsAnsiEscapes;
    } catch (_) {
      return false;
    }
  }();

  /// [text] without ANSI escape sequences.
  static String stripAnsi(String text) => text.replaceAll(_ansiEscape, '');

  /// The terminal columns [text] occupies: escapes zero, East Asian wide characters two.
  static int width(String text) {
    var w = 0;
    for (final rune in stripAnsi(text).runes) {
      w += _charVisualWidth(rune);
    }
    return w;
  }

  /// [text] cut to [maxWidth] columns with an ellipsis when it does not fit.
  static String truncate(String text, int maxWidth) {
    if (maxWidth <= 0) return '';
    if (width(text) <= maxWidth) return text;
    const ellipsis = '...';
    if (maxWidth <= ellipsis.length) return '.' * maxWidth;
    final target = maxWidth - ellipsis.length;
    final buffer = StringBuffer();
    var w = 0;
    for (final rune in stripAnsi(text).runes) {
      final cw = _charVisualWidth(rune);
      if (w + cw > target) break;
      buffer.writeCharCode(rune);
      w += cw;
    }
    return '$buffer$ellipsis';
  }
}

// ---- text measurement: here so that `cli` and `collection` share it

int _charVisualWidth(int rune) {
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  // Combining characters / zero width
  if (rune >= 0x0300 && rune <= 0x036f) return 0;
  if (rune >= 0x200b && rune <= 0x200f) return 0;
  if (rune >= 0xfe00 && rune <= 0xfe0f) return 0;

  // East Asian Wide / Fullwidth / Emoji. Dingbats (✓ ✖ ⚠, U+2600–27BF) are one column.
  if ((rune >= 0x1100 && rune <= 0x115f) ||
      rune == 0x2329 ||
      rune == 0x232a ||
      (rune >= 0x2e80 && rune <= 0x303e) ||
      (rune >= 0x3040 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe10 && rune <= 0xfe19) ||
      (rune >= 0xfe30 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x1f300 && rune <= 0x1faff) ||
      (rune >= 0x20000 && rune <= 0x2fffd) ||
      (rune >= 0x30000 && rune <= 0x3fffd)) {
    return 2;
  }
  return 1;
}

final _ansiEscape = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
