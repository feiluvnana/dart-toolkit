import 'ansi.dart';
import 'stdio.dart';

/// Helper class for structured and colored terminal logging.
///
/// {@category CLI}
class Logger {
  /// Logs a progress step badge: `[current/total] message`.
  static void step(int current, int total, String message) {
    ConsoleIo.out.writeln('[$current/$total] $message'.cyan.bold);
  }

  /// Logs a success message: `  ✓ message`.
  static void ok(String message) {
    ConsoleIo.out.writeln('  ✓ $message'.green);
  }

  /// Logs an informational message: `  ℹ message`.
  static void info(String message) {
    ConsoleIo.out.writeln('  ℹ $message'.cyan);
  }

  /// Logs a warning message: `  ⚠ message`.
  static void warn(String message) {
    ConsoleIo.out.writeln('  ⚠ $message'.yellow);
  }

  /// Logs an error message to standard error: `  ✖ message`.
  static void error(String message) {
    ConsoleIo.err.writeln('  ✖ $message'.red);
  }
}
