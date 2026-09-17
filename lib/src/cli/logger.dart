import 'ansi.dart';
import '../util/stdio.dart';

/// Severity levels for [Logger], ordered from most to least verbose.
///
/// {@category CLI}
enum LogLevel {
  /// Everything, including [Logger.debug].
  debug,

  /// Informational messages and above (the default).
  info,

  /// Warnings and errors only.
  warn,

  /// Errors only.
  error,

  /// Suppresses all output.
  silent,
}

/// Helper class for structured and colored terminal logging.
///
/// Output is filtered by [level] and written through [ConsoleIo], so it can be
/// silenced, redirected, or captured in tests without touching call sites.
///
/// {@category CLI}
class Logger {
  /// The minimum severity that is emitted. Defaults to [LogLevel.info].
  static LogLevel level = LogLevel.info;

  /// Whether [level] currently permits [candidate] to be written.
  static bool enabled(LogLevel candidate) => candidate.index >= level.index && level != LogLevel.silent;

  /// Runs [action] with logging suppressed, restoring the previous [level] afterwards.
  static T silenced<T>(T Function() action) {
    final previous = level;
    level = LogLevel.silent;
    try {
      return action();
    } finally {
      level = previous;
    }
  }

  /// Logs a progress step badge: `[current/total] message`.
  static void step(int current, int total, String message) {
    if (!enabled(LogLevel.info)) return;
    ConsoleIo.out.writeln('[$current/$total] $message'.cyan.bold);
  }

  /// Logs a verbose diagnostic message: `  · message`.
  static void debug(String message) {
    if (!enabled(LogLevel.debug)) return;
    ConsoleIo.out.writeln('  · $message'.dim);
  }

  /// Logs a success message: `  ✓ message`.
  static void ok(String message) {
    if (!enabled(LogLevel.info)) return;
    ConsoleIo.out.writeln('  ✓ $message'.green);
  }

  /// Logs an informational message: `  ℹ message`.
  static void info(String message) {
    if (!enabled(LogLevel.info)) return;
    ConsoleIo.out.writeln('  ℹ $message'.cyan);
  }

  /// Logs a warning message: `  ⚠ message`.
  static void warn(String message) {
    if (!enabled(LogLevel.warn)) return;
    ConsoleIo.out.writeln('  ⚠ $message'.yellow);
  }

  /// Logs an error message to standard error: `  ✖ message`.
  static void error(String message) {
    if (!enabled(LogLevel.error)) return;
    ConsoleIo.err.writeln('  ✖ $message'.red);
  }
}
