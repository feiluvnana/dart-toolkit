/// # Console
///
/// Terminal output and input, on one type.
///
/// ```dart
/// Console.rule('Building');
/// Console.writeln('42 files');
/// Console.box(text, title: 'Result');
///
/// final name = await Console.ask('Project name', fallback: 'app');
/// if (await Console.confirm('Overwrite?')) rebuild();
/// ```
///
/// Status lines are [logger], which is the one console global left: a script
/// logs constantly, `logger.ok(...)` is the whole call, and `Console.log.ok`
/// would be four characters of ceremony on the most frequent line in a script.
///
/// [ConsoleWriter] and [ConsoleReader] are still the types underneath, for the
/// same reason [Fetcher] is still a type beside [Http]: something that needs
/// its own writer — a test capturing output, a logger pointed at a file —
/// constructs one. [Console] is the shared pair, which is what a script wants.
///
/// [Terminal] and [Cursor] are raw control; [Table], [Progress] and [Spinner]
/// render.
/// {@category Terminal}
library;

import 'ansi.dart';
import 'logger.dart';
import 'reader.dart';
import 'table.dart';
import 'writer.dart';

export 'ansi.dart';
export 'logger.dart';
export 'progress.dart';
export 'reader.dart';
export 'spinner.dart';
export 'table.dart';
export 'terminal.dart';
export 'writer.dart' hide sharedConsoleWriter;

final ConsoleWriter _writer = sharedConsoleWriter;
final ConsoleLogger _logger = ConsoleLogger(_writer);
final ConsoleReader _reader = ConsoleReader();

/// The shared status logger.
///
/// ```dart
/// logger.step(1, 3, 'Crawling...');
/// logger.ok('Done.');
/// ```
ConsoleLogger get logger => _logger;

/// The terminal: what a script writes to it, and what it reads back.
///
/// Through 8.1.0 these were two globals — `consoleWriter` and `consoleReader`
/// — whose names said which half you wanted before you knew what you were
/// asking for. One type holds both, and `Console.` lists them.
abstract final class Console {
  /// Whether standard output is a terminal rather than a pipe or a file.
  ///
  /// Progress bars, spinners and colour check this; a redirected run gets
  /// plain lines.
  static bool get tty => _writer.tty;

  /// The terminal's width in columns, or 80 when there is no terminal.
  static int get width => _writer.width;

  /// The terminal's height in rows, or 24 when there is no terminal.
  static int get height => _writer.height;

  /// Whether standard input is a pipe rather than a keyboard.
  static bool get piped => _reader.piped;

  /// Writes [message] to standard output, with no trailing newline.
  static void write(String message) => _writer.write(message);

  /// Writes [message] to standard output, followed by a newline.
  static void writeln([String message = '']) => _writer.writeln(message);

  /// Writes [message] to standard error, with no trailing newline.
  static void error(String message) => _writer.error(message);

  /// Writes [message] to standard error, followed by a newline.
  static void errorln([String message = '']) => _writer.errorln(message);

  /// Draws a horizontal rule across the terminal, with an optional [title].
  static void rule([String title = '']) => _writer.rule(title);

  /// Draws [text] inside a box, with an optional [title].
  static void box(
    String text, {
    String? title,
    TableStyle style = TableStyle.unicode,
  }) => _writer.box(text, title: title, style: style);

  /// The next line of standard input, or `null` at end of input.
  static Future<String?> line() => _reader.line();

  /// Every remaining line of standard input.
  static Stream<String> get lines => _reader.lines;

  /// Asks [question] and returns the answer, or [fallback] for an empty one.
  ///
  /// Re-prompts while [validator] rejects the answer.
  static Future<String> ask(
    String question, {
    String? fallback,
    bool Function(String answer)? validator,
  }) => _reader.ask(question, fallback: fallback, validator: validator);

  /// Asks [question] as a yes/no question.
  static Future<bool> confirm(String question, {bool fallback = true}) =>
      _reader.confirm(question, fallback: fallback);

  /// Asks [question] without echoing what is typed.
  static Future<String> askSecret(String question) =>
      _reader.askSecret(question);

  /// Asks [question] as a numbered menu and returns the chosen option.
  static Future<O> pick<O>(
    String question, {
    required Iterable<O> options,
    String Function(O item)? label,
  }) => _reader.pick(question, options: options, label: label);

  /// Asks [question] as a numbered menu and returns every chosen option.
  static Future<List<O>> pickMany<O>(
    String question, {
    required Iterable<O> options,
    String Function(O item)? label,
  }) => _reader.pickMany(question, options: options, label: label);

  /// Closes standard input.
  static Future<void> close() => _reader.close();
}

/// ANSI styling helper.
const Ansi ansi = Ansi();
