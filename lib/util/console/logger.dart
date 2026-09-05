import 'dart:async';
import 'dart:io';

import 'ansi.dart';
import 'writer.dart';

// ============================================================================
// CONSOLE LOGGER (STATUS LOGGERS & VISUAL FEEDBACK)
// ============================================================================

/// Severity level for console logging.
enum LogLevel {
  /// Silence all output.
  none,

  /// Show only error / fail messages.
  error,

  /// Show errors and warnings.
  warn,

  /// Show info, ok, warn, and error messages.
  info,

  /// Show all messages including debug.
  debug,
}

/// Dedicated console status and event logger for CLI applications.
class ConsoleLogger {
  /// Current active log level filter.
  LogLevel level = LogLevel.debug;

  /// Prints an informational message prefixed with a blue notice symbol `ℹ`.
  void info(String message) {
    if (level.index < LogLevel.info.index) return;
    stdout.writeln('${'ℹ'.brightBlue()} $message');
  }

  /// Prints a success message prefixed with a green checkmark `✔`.
  void ok(String message) {
    if (level.index < LogLevel.info.index) return;
    stdout.writeln('${'✔'.brightGreen()} $message');
  }

  /// Prints a warning message prefixed with a yellow warning symbol `⚠`.
  void warn(String message) {
    if (level.index < LogLevel.warn.index) return;
    stdout.writeln('${'⚠'.brightYellow()} $message');
  }

  /// Prints an error message prefixed with a red error cross `✖` and optional stack trace.
  void error(String message, [Object? exception, StackTrace? stack]) {
    if (level.index < LogLevel.error.index) return;
    stderr.writeln('${'✖'.brightRed()} $message');
    if (exception != null) stderr.writeln('  ${exception.toString().red()}');
    if (stack != null) stderr.writeln(stack.toString().dim());
  }

  /// Prints a workflow step header in `[step/total]` format.
  void step(int step, int total, String message) {
    if (level.index < LogLevel.info.index) return;
    stdout.writeln('${'[$step/$total]'.cyan().bold()} $message');
  }

  /// Prints a debug message prefixed with a dimmed symbol `⚙`.
  void debug(String message) {
    if (level.index < LogLevel.debug.index) return;
    stdout.writeln('${'⚙'.dim()} $message');
  }

  /// Writes text directly to standard output without trailing newline.
  void write(String message) => stdout.write(message);

  /// Writes a line to standard output.
  void writeln([String message = '']) => stdout.writeln(message);

  /// Runs an asynchronous [action] with a spinner, automatically reporting ok or fail.
  Future<T> task<T>(String message, Future<T> Function() action) async {
    final s = Spinner()..start(message);
    try {
      final res = await action();
      s.ok(message);
      return res;
    } catch (e) {
      s.fail('$message ($e)');
      rethrow;
    }
  }
}
