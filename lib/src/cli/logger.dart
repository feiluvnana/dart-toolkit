part of '../../cli.dart';

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
    if (!Logger.isEnabled(LogLevel.info)) return;
    Io.out.writeln('[$_current/$total] $message'.cyan.bold);
  }
}

/// Levelled terminal logging, written through [Io].
///
/// {@category CLI}
class Logger {
  static const _levelKey = #dartToolkitLogLevel;
  static LogLevel _processLevel = LogLevel.info;

  /// The minimum severity that is emitted. Defaults to [LogLevel.info].
  ///
  /// Reads the level [silenced] set for the work in progress, if any, and otherwise the
  /// process-wide one that assigning to this sets.
  static LogLevel get level => Zone.current[_levelKey] as LogLevel? ?? _processLevel;

  static set level(LogLevel value) => _processLevel = value;

  /// Whether [level] currently permits [candidate] to be written.
  static bool isEnabled(LogLevel candidate) => candidate.index >= level.index && level != LogLevel.silent;

  /// Runs [action], sync or async, with logging suppressed.
  ///
  /// The suppression belongs to [action] and what it awaits — not to the process — so a
  /// task running beside it still reports. `Http.session` scopes its client the same way.
  static Future<T> silenced<T>(FutureOr<T> Function() action) =>
      runZoned(() async => action(), zoneValues: {_levelKey: LogLevel.silent});

  /// A counter over [total] stages, printing `[n/total] message` on each call.
  ///
  /// ```dart
  /// final stage = Logger.stages(3);
  /// stage('Scraping metadata');   // [1/3] Scraping metadata
  /// ```
  static Stages stages(int total) => Stages(total);

  /// Logs a verbose diagnostic message: `  · message`.
  static void debug(String message) {
    if (!isEnabled(LogLevel.debug)) return;
    Io.out.writeln('  · $message'.dim);
  }

  /// Logs a success message: `  ✓ message`.
  static void ok(String message) {
    if (!isEnabled(LogLevel.info)) return;
    Io.out.writeln('  ✓ $message'.green);
  }

  /// Logs an informational message: `  ℹ message`.
  static void info(String message) {
    if (!isEnabled(LogLevel.info)) return;
    Io.out.writeln('  ℹ $message'.cyan);
  }

  /// Logs a warning message to standard error: `  ⚠ message`.
  static void warn(String message) {
    if (!isEnabled(LogLevel.warn)) return;
    Io.err.writeln('  ⚠ $message'.yellow);
  }

  /// Logs an error message to standard error: `  ✖ message`.
  static void error(String message) {
    if (!isEnabled(LogLevel.error)) return;
    Io.err.writeln('  ✖ $message'.red);
  }
}
