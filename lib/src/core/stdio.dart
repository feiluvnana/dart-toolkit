part of '../../core.dart';

/// The process's standard I/O, injectable: every console write and read goes through it.
///
/// {@category CLI}
abstract final class Io {
  static StringSink? _out;
  static StringSink? _err;

  /// Replaces standard input; returning `null` is end of input.
  static String? Function()? input;

  /// The active standard output sink. Assign to redirect it; assign `null` to restore.
  static StringSink get out =>
      _out != null ? (_outTakesColor ? _out! : _Plain(_out!)) : (_outTakesColor ? _stdout : _plainStdout);
  static set out(StringSink? sink) => _out = sink;

  /// The active standard error sink. Assign to redirect it; assign `null` to restore.
  ///
  /// Colour is decided for stderr on its own, so `app 2>log` writes a log with no escapes.
  static StringSink get err =>
      _err != null ? (_errTakesColor ? _err! : _Plain(_err!)) : (_errTakesColor ? _stderr : _plainStderr);
  static set err(StringSink? sink) => _err = sink;

  static bool get _outTakesColor => _color ?? _ansiTerminal;
  static bool get _errTakesColor => _color ?? _ansiStderr;

  static final StringSink _plainStdout = _Plain(_stdout);
  static final StringSink _plainStderr = _Plain(_stderr);

  /// The process sinks with a closed pipe made harmless: `app --help | head` would otherwise end
  /// in an unhandled `Broken pipe`.
  static final IOSink _stdout = _quiet(stdout);
  static final IOSink _stderr = _quiet(stderr);

  static IOSink _quiet(IOSink sink) => sink..done.catchError((_) {});

  static bool _ask(bool Function() native) {
    try {
      return native();
    } catch (_) {
      return false;
    }
  }

  /// Whether output is going somewhere other than the process's own stdout.
  static bool get isRedirected => _out != null;

  /// Whether the *active* output sink is an interactive terminal; cursor control gates on this,
  /// not `stdout.hasTerminal`, so redirecting [out] redirects the decision too.
  static bool get isTerminal => !isRedirected && _hasTerminal;

  /// Whether stderr is going somewhere other than the process's own stderr.
  static bool get isErrRedirected => _err != null;

  /// Whether the *active* error sink is an interactive terminal.
  static bool get isErrTerminal => !isErrRedirected && _hasErrTerminal;

  // Native calls, asked once: per call they were most of the cost of a progress tick.
  static final _hasTerminal = _ask(() => stdout.hasTerminal);
  static final _hasErrTerminal = _ask(() => stderr.hasTerminal);
  static final _ansiTerminal = _ask(() => stdout.supportsAnsiEscapes && !Env.has('NO_COLOR'));
  static final _ansiStderr = _ask(() => stderr.supportsAnsiEscapes && !Env.has('NO_COLOR'));

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
  /// The read blocks a helper isolate, so `Cli.run`'s ^C handler still runs while a prompt waits,
  /// and nothing is left listening on stdin afterwards.
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

  /// Whether ANSI styling is enabled: an assignment here, else off when [out] is redirected or
  /// `NO_COLOR` is set, else whether the terminal takes escapes. Assign `null` to restore.
  static bool get color => _color ?? (!isRedirected && !Env.has('NO_COLOR') && _ansiTerminal);

  static set color(bool? value) => _color = value;

  /// The value assigned to [color], or `null`.
  static bool? get colorOverride => _color;

  static bool? _color;

  /// [text] without ANSI escape sequences.
  static String stripAnsi(String text) => text.contains('\x1b') ? text.replaceAll(_ansiEscape, '') : text;

  /// The terminal columns [text] occupies: escapes zero, East Asian wide characters two.
  static int width(String text) {
    // Printable ASCII is one column each, and holds no escape: the common case skips both scans.
    var ascii = true;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit < 0x20 || unit > 0x7e) {
        ascii = false;
        break;
      }
    }
    if (ascii) return text.length;
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

/// Not API: how a module that cannot import `cli` (e.g. `process` echoing a child) writes above
/// `cli`'s live region. `cli` sets [above] while something is live.
///
/// {@category CLI}
final class IoBridge {
  IoBridge._();

  /// Runs a durable write above the live region, or `null` when nothing is live.
  static void Function(void Function() write)? above;

  /// Runs [action] with the live region wiped, repainting when the future completes.
  static Future<T> Function<T>(Future<T> Function() action)? suspend;

  /// The console theme's border glyphs, for `collection`'s `Table.show`; set once `cli` draws.
  static Border Function()? border;

  /// Synchronous terminal restores (a TUI's raw mode and alternate screen) that `cli` runs
  /// before it ends the process, since `exit` skips every `finally`.
  static final Set<void Function()> restores = {};
}

/// A sink that drops escapes on the way through.
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
  // Combining and zero-width.
  if (rune >= 0x0300 && rune <= 0x036f) return 0;
  if (rune >= 0x200b && rune <= 0x200f) return 0;
  if (rune == 0x200d) return 0;
  if (rune >= 0xfe00 && rune <= 0xfe0f) return 0;
  if (rune >= 0x1f3fb && rune <= 0x1f3ff) return 0;

  // East Asian Wide/Fullwidth and emoji; of the dingbats only ☕ ⚡ ✅ ❌ are wide.
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
