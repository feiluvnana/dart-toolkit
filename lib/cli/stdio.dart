import 'dart:convert';
import 'dart:io';

/// Injectable standard I/O seam for CLI components (Logger, Console, Prompt).
///
/// {@category CLI}
class ConsoleIo {
  static StringSink? stdoutOverride;
  static StringSink? stderrOverride;
  static String Function()? stdinLineReader;

  /// The active standard output sink.
  static StringSink get out => stdoutOverride ?? stdout;

  /// The active standard error sink.
  static StringSink get err => stderrOverride ?? stderr;

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
