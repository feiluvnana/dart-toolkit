import 'dart:async';
import 'dart:io';

import 'logger.dart';
import 'reader.dart';
import 'terminal.dart';
import 'writer.dart';

export 'ansi.dart';
export 'logger.dart';
export 'reader.dart';
export 'terminal.dart';
export 'writer.dart';

// ============================================================================
// CONSOLE ROOT ACCESSOR & NAMESPACES
// ============================================================================

/// Main Console logging, prompt, and output interface.
class Console {
  /// Structured status logger for workflow steps, success, warnings, errors, and tasks.
  static final ConsoleLogger logger = ConsoleLogger();

  /// Structured output writer for tables, boxes, rules, bars, and spinners.
  static final ConsoleWriter writer = ConsoleWriter();

  /// Interactive reader for CLI user input, confirmations, and menus.
  static final ConsoleReader reader = ConsoleReader();

  /// Terminal geometry and screen clearing utilities.
  static final Terminal terminal = Terminal();

  /// Terminal cursor positioning and visibility manipulation.
  static final Cursor cursor = Cursor();

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
  }) => reader.ask(question, defaultVal: defaultVal, validator: validator);

  /// Prompts user to pick an option from a numbered list.
  static Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) => reader.pick(question, options: options, label: label);

  /// Prompts user to select multiple options from a numbered list.
  static Future<List<O>> picks<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) => reader.picks(question, options: options, label: label);
}

/// Namespace accessor for console subsystem.
class ConsoleAccessor {
  const ConsoleAccessor();

  /// Sub-namespace for status and event logging (info, ok, warn, error, fail, step, task, debug).
  ConsoleLogger get logger => Console.logger;

  /// Sub-namespace for structured output (tables, boxes, rules, bars, spinners).
  ConsoleWriter get writer => Console.writer;

  /// Sub-namespace for interactive terminal input (prompts, confirms, menus, passwords).
  ConsoleReader get reader => Console.reader;

  /// Sub-namespace for terminal geometry, dimensions, and screen clearing.
  Terminal get terminal => Console.terminal;

  /// Sub-namespace for terminal cursor manipulation.
  Cursor get cursor => Console.cursor;

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
  Table table(List<String> headers, [List<List<Object?>>? rows]) =>
      Console.writer.table(headers, rows);

  /// Prompts user with a Yes/No boolean confirmation question.
  Future<bool> confirm(String question, {bool defaultVal = true}) =>
      Console.confirm(question, defaultVal: defaultVal);

  /// Prompts user for a text response with optional default and validator.
  Future<String> ask(
    String question, {
    String? defaultVal,
    bool Function(String)? validator,
  }) => Console.ask(question, defaultVal: defaultVal, validator: validator);

  /// Prompts user to choose from a list of options.
  Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) => Console.pick(question, options: options, label: label);

  /// Prompts user to choose multiple options from a list.
  Future<List<O>> picks<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) => Console.picks(question, options: options, label: label);
}
