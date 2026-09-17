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

/// A self-numbering sequence of stage banners. Created by [Logger.stages].
///
/// {@category CLI}
class Stages {
  /// How many stages the run has.
  final int total;
  int _current = 0;

  Stages(this.total);

  /// Prints the next stage banner: `[n/total] message`.
  void call(String message) {
    _current++;
    if (!Logger.enabled(LogLevel.info)) return;
    ConsoleIo.out.writeln('[$_current/$total] $message'.cyan.bold);
  }
}

/// Levelled terminal logging, written through [ConsoleIo].
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

  /// A counter over [total] stages, printing `[n/total] message` on each call.
  ///
  /// ```dart
  /// final stage = Logger.stages(3);
  /// stage('Scraping metadata');   // [1/3] Scraping metadata
  /// ```
  static Stages stages(int total) => Stages(total);

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
