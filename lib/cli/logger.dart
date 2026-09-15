import 'dart:io';

import 'ansi.dart';

/// Helper class for structured and colored terminal logging.
class Logger {
  /// Logs a progress step badge: `[current/total] message`.
  static void step(int current, int total, String message) {
    stdout.writeln('[$current/$total] $message'.cyan.bold);
  }

  /// Logs a success message: `  ✓ message`.
  static void ok(String message) {
    stdout.writeln('  ✓ $message'.green);
  }

  /// Logs an informational message: `  ℹ message`.
  static void info(String message) {
    stdout.writeln('  ℹ $message'.cyan);
  }

  /// Logs a warning message: `  ⚠ message`.
  static void warn(String message) {
    stdout.writeln('  ⚠ $message'.yellow);
  }

  /// Logs an error message to [stderr]: `  ✖ message`.
  static void error(String message) {
    stderr.writeln('  ✖ $message'.red);
  }
}
