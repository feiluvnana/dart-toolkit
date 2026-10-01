part of '../../core.dart';

/// The process's standard I/O, injectable: every console write and read goes through it.
///
/// {@category CLI}
class Io {
  static StringSink? _out;
  static StringSink? _err;

  /// Replaces standard input. Return `null` to signal end of input, which lets
  /// tests and non-interactive runs exercise the end-of-input path of a prompt.
  static String? Function()? input;

  /// The active standard output sink. Assign to redirect it; assign `null` to restore.
  static StringSink get out =>
      _out != null ? (_outTakesColor ? _out! : _Plain(_out!)) : (_outTakesColor ? _stdout : _plainStdout);
  static set out(StringSink? sink) => _out = sink;

  /// The active standard error sink. Assign to redirect it; assign `null` to restore.
  ///
  /// The process's stderr is asked about colour on its own: `app 2>log` keeps colour on the
  /// terminal and writes a log with no escapes in it.
  static StringSink get err =>
      _err != null ? (_errTakesColor ? _err! : _Plain(_err!)) : (_errTakesColor ? _stderr : _plainStderr);
  static set err(StringSink? sink) => _err = sink;

  static bool get _outTakesColor => _color ?? _ansiTerminal;
  static bool get _errTakesColor => _color ?? _ansiStderr;

  static final StringSink _plainStdout = _Plain(_stdout);
  static final StringSink _plainStderr = _Plain(_stderr);

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
  static bool get isTerminal => !isRedirected && _hasTerminal;

  /// Whether stderr is going somewhere other than the process's own stderr.
  static bool get isErrRedirected => _err != null;

  /// Whether the *active* error sink is an interactive terminal.
  static bool get isErrTerminal => !isErrRedirected && _hasErrTerminal;

  /// A native call, asked once: whether stdout is a terminal does not change while it runs,
  /// and asking per call was most of the cost of a progress tick.
  static final bool _hasTerminal = () {
    try {
      return stdout.hasTerminal;
    } catch (_) {
      return false;
    }
  }();

  static final bool _hasErrTerminal = () {
    try {
      return stderr.hasTerminal;
    } catch (_) {
      return false;
    }
  }();

  /// The width of the active terminal, or `null` when there is no terminal.
  static int? get columns {
    if (!isTerminal) return null;
    try {
      return stdout.terminalColumns;
    } catch (_) {
      return null;
    }
  }

  /// Reads a line from standard input or the [input] override; `null` at end of input.
  ///
  /// The read blocks a helper isolate, never this one, so a signal handler — `Cli.run`'s
  /// ^C — still runs while a prompt waits. Nothing is left listening afterwards, so a script
  /// that asks one question still ends when `main` does.
  static Future<String?> readLine({Encoding encoding = utf8}) async {
    if (input case final scripted?) return scripted();
    return Isolate.run(() => stdin.readLineSync(encoding: encoding));
  }

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

  /// Whether an explicit colour override was set via [color], or `null` if none.
  static bool? get colorOverride => _color;

  static bool? _color;

  /// Whether the process's stdout takes escapes: a native call, asked once.
  static final bool _ansiTerminal = () {
    try {
      return stdout.supportsAnsiEscapes && !Env.has('NO_COLOR');
    } catch (_) {
      return false;
    }
  }();

  /// The same question of stderr, which is often somewhere else.
  static final bool _ansiStderr = () {
    try {
      return stderr.supportsAnsiEscapes && !Env.has('NO_COLOR');
    } catch (_) {
      return false;
    }
  }();

  /// [text] without ANSI escape sequences.
  static String stripAnsi(String text) => text.contains('\x1b') ? text.replaceAll(_ansiEscape, '') : text;

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

/// Not API: how `cli`'s live region lets another module write above it.
///
/// `process` echoes a child's output and cannot import `cli`, which owns the bottom rows
/// of the terminal while a spinner or a board is drawn. `cli` sets [above] while something
/// is live and clears it when nothing is; a writer that finds it set hands its write over,
/// and the renderer is cleared, the write lands where it stood, and the renderer is drawn
/// again below it.
///
/// {@category CLI}
final class IoBridge {
  IoBridge._();

  /// Runs a durable write above the live region, or `null` when nothing is live.
  static void Function(void Function() write)? above;

  /// Runs [action] with the live region wiped, repainting when the future completes.
  static Future<T> Function<T>(Future<T> Function() action)? suspend;

  /// The console theme's border glyphs, for `collection`'s `Table.show`; set once `cli` draws.
  static String Function()? border;
}

/// A sink that drops escapes on the way through: stderr when it is not a terminal.
final class _Plain implements StringSink {
  final StringSink _sink;

  _Plain(this._sink);

  @override
  void write(Object? object) => _sink.write(Io.stripAnsi('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _sink.writeln(Io.stripAnsi('$object'));
}

// ---- text measurement: here so that `cli` and `collection` share it

int _charVisualWidth(int rune) {
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  if (rune < 0x7f) return 1;
  // Combining characters / zero width
  if (rune >= 0x0300 && rune <= 0x036f) return 0;
  if (rune >= 0x200b && rune <= 0x200f) return 0;
  if (rune == 0x200d) return 0;
  if (rune >= 0xfe00 && rune <= 0xfe0f) return 0;
  if (rune >= 0x1f3fb && rune <= 0x1f3ff) return 0;

  // East Asian Wide / Fullwidth / Emoji. Dingbats (✓ ✖ ⚠, U+2600–27BF) are mostly one column,
  // but ✅, ❌, ☕, ⚡ are Wide (2 columns).
  if (rune == 0x2615 ||
      rune == 0x26a1 ||
      rune == 0x2705 ||
      rune == 0x274c ||
      (rune >= 0x1100 && rune <= 0x115f) ||
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
