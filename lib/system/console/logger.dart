/// # Console Logger (`system.console.logger.*`)
///
/// Status lines with severity filtering. Errors go to stderr, everything else
/// to stdout, so a script's diagnostics survive piping.
library;

import 'dart:async';
import 'dart:convert';

import 'ansi.dart';
import 'spinner.dart';
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

/// How [ConsoleLogger] renders a line.
enum LogFormat {
  /// A badge and the message, for a person reading a terminal.
  plain,

  /// One JSON object per line, for a machine reading a file.
  json,
}

/// Status logging, reachable as [logger].
///
/// ```dart
/// logger.level = LogLevel.warn; // quiet mode
/// logger.step(1, 3, 'Crawling');
/// logger.ok('Done');
/// ```
///
/// Where the lines go is [writer]'s business, so a run can be logged to a file
/// as easily as to a screen, and a test can read back what was logged:
///
/// ```dart
/// logger.writer = ConsoleWriter(
///   out: File('run.log').openWrite(),
/// );
/// logger.format = LogFormat.json;
/// logger.stamp = true;
/// ```
class ConsoleLogger {
  /// Where lines are written.
  ///
  /// Replace it to send a run's diagnostics to a file, a buffer, or anywhere
  /// else a [StringSink] reaches.
  ConsoleWriter writer;

  /// Messages below this severity are dropped.
  LogLevel level = LogLevel.debug;

  /// Whether lines are rendered for a person or for a machine.
  LogFormat format = LogFormat.plain;

  /// Whether each line carries the time it was written.
  ///
  /// An ISO-8601 prefix in [LogFormat.plain], a `time` field in
  /// [LogFormat.json].
  bool stamp = false;

  /// Creates a logger writing through [writer], or defaults to a new [ConsoleWriter].
  ConsoleLogger([ConsoleWriter? writer]) : writer = writer ?? ConsoleWriter();

  /// Reports progress or context.
  void info(String message) =>
      _out(LogLevel.info, 'info', 'ℹ'.brightBlue(), message);

  /// Reports success.
  void ok(String message) =>
      _out(LogLevel.info, 'ok', '✔'.brightGreen(), message);

  /// Reports success. Alias for [ok].
  void success(String message) => ok(message);

  /// Reports a recoverable problem.
  void warn(String message) =>
      _out(LogLevel.warn, 'warn', '⚠'.brightYellow(), message);

  /// Reports a numbered step, e.g. `[2/5] Fetching`.
  void step(int step, int total, String message) => _out(
    LogLevel.info,
    'step',
    '[$step/$total]'.cyan().bold(),
    message,
    fields: {'step': step, 'total': total},
  );

  /// Reports detail only useful while debugging.
  void debug(String message) =>
      _out(LogLevel.debug, 'debug', '⚙'.dim(), message);

  /// Reports a failure to stderr, optionally with [exception] and [stack].
  void error(String message, [Object? exception, StackTrace? stack]) {
    if (level.index < LogLevel.error.index) return;
    if (format == LogFormat.json) {
      writer.errorln(
        _json('error', message, {
          if (exception != null) 'error': exception.toString(),
          if (stack != null) 'stack': stack.toString(),
        }),
      );
      return;
    }
    writer.errorln('${_prefix()}${'✖'.brightRed()} $message');
    if (exception != null) writer.errorln('  ${exception.toString().red()}');
    if (stack != null) writer.errorln(stack.toString().dim());
  }

  /// Runs [action] behind a [Spinner], reporting success or failure.
  ///
  /// The spinner resolves to a tick on success and a cross on failure; the
  /// error is rethrown either way. Honours [level] like every other method
  /// here: below [LogLevel.info] the work still runs, silently, and a
  /// [LogLevel.none] logger does not even report the failure.
  ///
  /// The spinner is drawn through this logger's [writer], so a logger sending
  /// its output to a file or a buffer takes its spinner along.
  Future<T> task<T>(String message, Future<T> Function() action) async {
    final show = level.index >= LogLevel.info.index;
    final spinner = show ? (Spinner(writer: writer)..start(message)) : null;
    try {
      final result = await action();
      spinner?.ok(message);
      return result;
    } catch (e) {
      spinner?.stop();
      error('$message ($e)');
      rethrow;
    }
  }

  void _out(
    LogLevel min,
    String name,
    String badge,
    String message, {
    Map<String, Object?> fields = const {},
  }) {
    if (level.index < min.index) return;
    if (format == LogFormat.json) {
      writer.writeln(_json(name, message, fields));
      return;
    }
    writer.writeln('${_prefix()}$badge $message');
  }

  /// The moment a stamped line is written, ISO-8601 in UTC.
  static String _now() => DateTime.now().toUtc().toIso8601String();

  /// The timestamp a plain line opens with, or nothing when [stamp] is off.
  String _prefix() => stamp ? '${'[${_now()}]'.dim()} ' : '';

  /// One JSON line. The message is carried as text, never as a badge: a
  /// machine reading this wants the level named, not drawn.
  String _json(String level, String message, Map<String, Object?> fields) =>
      jsonEncode({
        if (stamp) 'time': _now(),
        'level': level,
        // Escape codes are for a screen. A log file keeps the words.
        'message': message.plain,
        ...fields,
      });
}
