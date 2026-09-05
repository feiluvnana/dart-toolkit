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
  static final ConsoleWriter writer = ConsoleWriter();
  static final ConsoleReader reader = ConsoleReader();
  static final Terminal terminal = Terminal();
  static final Cursor cursor = Cursor();

  static void info(String message) {
    stdout.writeln('${'ℹ'.brightBlue()} $message');
  }

  static void ok(String message) {
    stdout.writeln('${'✔'.brightGreen()} $message');
  }

  static void warn(String message) {
    stdout.writeln('${'⚠'.brightYellow()} $message');
  }

  static void error(String message, [Object? error, StackTrace? stack]) {
    stderr.writeln('${'✖'.brightRed()} $message');
    if (error != null) stderr.writeln('  ${error.toString().red()}');
    if (stack != null) stderr.writeln(stack.toString().dim());
  }

  static void step(int step, int total, String message) {
    stdout.writeln('${'[$step/$total]'.cyan().bold()} $message');
  }

  static void write(String message) => stdout.write(message);
  static void writeln([String message = '']) => stdout.writeln(message);

  static void rule([String title = '']) => writer.rule(title);

  static Progress bar(int total, [String message = '']) =>
      writer.bar(total, message);

  static Spinner spin([String message = '']) => writer.spin(message);

  static Future<bool> confirm(String question, {bool defaultVal = true}) =>
      reader.confirm(question, defaultVal: defaultVal);

  static Future<String> ask(
    String question, {
    String? defaultVal,
    bool Function(String)? validator,
  }) =>
      reader.ask(question, defaultVal: defaultVal, validator: validator);

  static Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) =>
      reader.pick(question, options: options, label: label);

  /// Run an asynchronous task with an animated spinner, automatically marking ok/fail (1-word).
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

  ConsoleWriter get writer => Console.writer;
  ConsoleReader get reader => Console.reader;
  Terminal get terminal => Console.terminal;
  Cursor get cursor => Console.cursor;

  void info(String message) => Console.info(message);
  void ok(String message) => Console.ok(message);
  void warn(String message) => Console.warn(message);
  void error(String message, [Object? error, StackTrace? stack]) =>
      Console.error(message, error, stack);
  void fail(String message, [Object? error, StackTrace? stack]) =>
      Console.error(message, error, stack);
  void step(int step, int total, String message) =>
      Console.step(step, total, message);
  void rule([String title = '']) => Console.rule(title);
  void write(String message) => Console.write(message);
  void writeln([String message = '']) => Console.writeln(message);

  Progress bar(int total, [String message = '']) => Console.bar(total, message);
  Spinner spin([String message = '']) => Console.spin(message);
  Table table(List<String> headers, [List<List<dynamic>>? rows]) =>
      Console.writer.table(headers, rows);

  Future<bool> confirm(String question, {bool defaultVal = true}) =>
      Console.confirm(question, defaultVal: defaultVal);
  Future<String> ask(
    String question, {
    String? defaultVal,
    bool Function(String)? validator,
  }) =>
      Console.ask(question, defaultVal: defaultVal, validator: validator);
  Future<O> pick<O>(
    String question, {
    required List<O> options,
    String Function(O item)? label,
  }) =>
      Console.pick(question, options: options, label: label);

  Future<T> task<T>(String message, Future<T> Function() action) =>
      Console.task(message, action);
}
