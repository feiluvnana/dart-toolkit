part of '../../core.dart';

/// Injectable standard I/O seam for CLI components (Logger, Console, Prompt).
///
/// {@category CLI}
class ConsoleIo {
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
}
