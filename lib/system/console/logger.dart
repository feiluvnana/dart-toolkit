/// # Console Logger (`system.console.logger.*`)
///
/// Status lines with severity filtering. Errors go to stderr, everything else
/// to stdout, so a script's diagnostics survive piping.
library;

import 'dart:async';

import 'ansi.dart';
import 'writer.dart';

// ============================================================================
// CONSOLE LOGGER (system.console.logger.*)
// ============================================================================

/// Severity threshold for [ConsoleLogger], in increasing verbosity.
enum LogLevel {
  /// Suppress every message.
  none,

  /// Only [ConsoleLogger.error].
  error,

  /// Errors and [ConsoleLogger.warn].
  warn,

  /// Errors, warnings, [ConsoleLogger.info], [ConsoleLogger.ok] and
  /// [ConsoleLogger.step].
  info,

  /// Everything, including [ConsoleLogger.debug].
  debug,
}

/// Status logging, reachable as `system.console.logger`.
///
/// ```dart
/// system.console.logger.level = LogLevel.warn; // quiet mode
/// system.console.logger.step(1, 3, 'Crawling');
/// system.console.logger.ok('Done');
/// ```
class ConsoleLogger {
  /// The writer used for terminal writes.
  final ConsoleWriter writer;

  /// Messages below this severity are dropped.
  LogLevel level = LogLevel.debug;

  /// Creates a logger writing through [writer], or defaults to a new [ConsoleWriter].
  ConsoleLogger([ConsoleWriter? writer]) : writer = writer ?? ConsoleWriter();

  /// Reports progress or context.
  void info(String message) => _out(LogLevel.info, 'ℹ'.brightblue(), message);

  /// Reports success.
  void ok(String message) => _out(LogLevel.info, '✔'.brightgreen(), message);

  /// Reports a recoverable problem.
  void warn(String message) => _out(LogLevel.warn, '⚠'.brightyellow(), message);

  /// Reports a numbered step, e.g. `[2/5] Fetching`.
  void step(int step, int total, String message) =>
      _out(LogLevel.info, '[$step/$total]'.cyan().bold(), message);

  /// Reports detail only useful while debugging.
  void debug(String message) => _out(LogLevel.debug, '⚙'.dim(), message);

  /// Reports a failure to stderr, optionally with [exception] and [stack].
  void error(String message, [Object? exception, StackTrace? stack]) {
    if (level.index < LogLevel.error.index) return;
    writer.errorln('${'✖'.brightred()} $message');
    if (exception != null) writer.errorln('  ${exception.toString().red()}');
    if (stack != null) writer.errorln(stack.toString().dim());
  }

  /// Runs [action] behind a [Spinner], reporting success or failure.
  ///
  /// The spinner resolves to a tick on success and a cross on failure; the
  /// error is rethrown either way.
  Future<T> task<T>(String message, Future<T> Function() action) async {
    final spinner = Spinner()..start(message);
    try {
      final result = await action();
      spinner.ok(message);
      return result;
    } catch (e) {
      spinner.fail('$message ($e)');
      rethrow;
    }
  }

  void _out(LogLevel min, String badge, String message) {
    if (level.index < min.index) return;
    writer.writeln('$badge $message');
  }
}
