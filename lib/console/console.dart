import 'dart:async';
import 'dart:io';

import 'ansi.dart';
import 'reader.dart';
import 'terminal.dart';
import 'writer.dart';

export 'ansi.dart';
export 'reader.dart';
export 'terminal.dart';
export 'writer.dart';

// ============================================================================
// CONSOLE ROOT ACCESSOR & NAMESPACES
// ============================================================================

/// Main Console logging, prompt, and output interface.
class Console {
  /// Structured output writer for tables, boxes, rules, bars, and spinners.
  static final ConsoleWriter writer = ConsoleWriter();

  /// Interactive reader for CLI user input, confirmations, and menus.
  static final ConsoleReader reader = ConsoleReader();

  /// Terminal geometry and screen clearing utilities.
  static final Terminal terminal = Terminal();

  /// Terminal cursor positioning and visibility manipulation.
  static final Cursor cursor = Cursor();

  /// Prints an informational message prefixed with a blue notice symbol `ℹ`.
  static void info(String message) {
    stdout.writeln('${'ℹ'.brightBlue()} $message');
  }

  /// Prints a success message prefixed with a green checkmark `✔`.
  static void ok(String message) {
    stdout.writeln('${'✔'.brightGreen()} $message');
  }

  /// Prints a warning message prefixed with a yellow warning symbol `⚠`.
  static void warn(String message) {
    stdout.writeln('${'⚠'.brightYellow()} $message');
  }

  /// Prints an error message prefixed with a red error cross `✖` and optional stack trace.
  static void error(String message, [Object? error, StackTrace? stack]) {
    stderr.writeln('${'✖'.brightRed()} $message');
    if (error != null) stderr.writeln('  ${error.toString().red()}');
    if (stack != null) stderr.writeln(stack.toString().dim());
  }

  /// Prints a progress step header in `[step/total]` format.
  static void step(int step, int total, String message) {
    stdout.writeln('${'[$step/$total]'.cyan().bold()} $message');
  }

  /// Writes text directly to standard output without trailing newline.
  static void write(String message) => stdout.write(message);

  /// Writes a line to standard output.
  static void writeln([String message = '']) => stdout.writeln(message);

  /// Draws a full-width horizontal divider rule with optional centered [title].
  static void rule([String title = '']) => writer.rule(title);

  /// Creates a progress bar instance tracking [total] items with [message].
  static Progress bar(int total, [String message = '']) =>
      writer.bar(total, message);

  /// Starts an animated terminal spinner with [message].
  static Spinner spin([String message = '']) => writer.spin(message);

  /// Prompts user with a Yes/No boolean question.
  static Future<bool> confirm(String question, {bool defaultVal = true}) =>
      reader.confirm(question, defaultVal: defaultVal);

  /// Prompts user for text input with optional default and validator.
  static Future<String> ask(
    String question, {
    String? defaultVal,
    bool Function(String)? validator,
  }) =>
      reader.ask(question, defaultVal: defaultVal, validator: validator);

  /// Prompts user to pick an option from a numbered list.
  static Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) =>
      reader.pick(question, options: options, label: label);

  /// Runs an asynchronous [action] with a spinner, automatically reporting ok or fail.
  static Future<T> task<T>(String message, Future<T> Function() action) async {
    final s = spin(message);
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

/// Top-level console instance (`console.step(...)`, `console.writer.table(...)`, `console.reader.ask(...)`).
const ConsoleAccessor console = ConsoleAccessor();

/// Namespace accessor for console subsystem.
class ConsoleAccessor {
  const ConsoleAccessor();

  /// Sub-namespace for structured output (tables, boxes, rules, bars, spinners).
  ConsoleWriter get writer => Console.writer;

  /// Sub-namespace for interactive terminal input (prompts, confirms, menus, passwords).
  ConsoleReader get reader => Console.reader;

  /// Sub-namespace for terminal geometry, dimensions, and screen clearing.
  Terminal get terminal => Console.terminal;

  /// Sub-namespace for terminal cursor manipulation.
  Cursor get cursor => Console.cursor;

  /// Prints an informational message prefixed with `ℹ`.
  void info(String message) => Console.info(message);

  /// Prints a success message prefixed with `✔`.
  void ok(String message) => Console.ok(message);

  /// Prints a warning message prefixed with `⚠`.
  void warn(String message) => Console.warn(message);

  /// Prints an error message prefixed with `✖` and optional stack trace.
  void error(String message, [Object? error, StackTrace? stack]) =>
      Console.error(message, error, stack);

  /// Alias for [error] (1-word).
  void fail(String message, [Object? error, StackTrace? stack]) =>
      Console.error(message, error, stack);

  /// Prints a workflow step header: `[step/total] message`.
  void step(int step, int total, String message) =>
      Console.step(step, total, message);

  /// Draws a horizontal divider rule with optional centered [title].
  void rule([String title = '']) => Console.rule(title);

  /// Writes text without trailing newline.
  void write(String message) => Console.write(message);

  /// Writes a line of text.
  void writeln([String message = '']) => Console.writeln(message);

  /// Creates a progress bar instance for [total] units.
  Progress bar(int total, [String message = '']) => Console.bar(total, message);

  /// Starts an animated spinner with [message].
  Spinner spin([String message = '']) => Console.spin(message);

  /// Prints a formatted table with [headers] and optional [rows].
  Table table(List<String> headers, [List<List<dynamic>>? rows]) =>
      Console.writer.table(headers, rows);

  /// Prompts user with a Yes/No boolean confirmation question.
  Future<bool> confirm(String question, {bool defaultVal = true}) =>
      Console.confirm(question, defaultVal: defaultVal);

  /// Prompts user for a text response with optional default and validator.
  Future<String> ask(
    String question, {
    String? defaultVal,
    bool Function(String)? validator,
  }) =>
      Console.ask(question, defaultVal: defaultVal, validator: validator);

  /// Prompts user to choose from a list of options.
  Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) =>
      Console.pick(question, options: options, label: label);

  /// Runs an async [action] wrapped in a terminal spinner.
  Future<T> task<T>(String message, Future<T> Function() action) =>
      Console.task(message, action);
}
