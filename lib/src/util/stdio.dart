import 'dart:convert';
import 'dart:io';

/// Injectable standard I/O seam for CLI components (Logger, Console, Prompt).
///
/// {@category CLI}
class ConsoleIo {
  static StringSink? stdoutOverride;
  static StringSink? stderrOverride;

  /// Replaces standard input. Return `null` to signal end of input, which lets
  /// tests and non-interactive runs exercise the EOF path of [Prompt].
  static String? Function()? stdinLineReader;

  /// The active standard output sink.
  static StringSink get out => stdoutOverride ?? stdout;

  /// The active standard error sink.
  static StringSink get err => stderrOverride ?? stderr;

  /// Whether the *active* output sink is an interactive terminal.
  ///
  /// Redirecting [stdoutOverride] must also redirect the decision about what to
  /// render, so every cursor-control path gates on this rather than on
  /// `stdout.hasTerminal` directly.
  static bool get isTerminal {
    if (stdoutOverride != null) return false;
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

  /// Reads a line from standard input or mock input provider.
  static String? readLine({Encoding encoding = utf8}) {
    if (stdinLineReader != null) {
      return stdinLineReader!();
    }
    return stdin.readLineSync(encoding: encoding);
  }

  /// Resets all custom I/O overrides.
  static void reset() {
    stdoutOverride = null;
    stderrOverride = null;
    stdinLineReader = null;
  }
}
