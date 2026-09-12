/// # Console Domain (`system.console.*`)
///
/// Terminal output and input, split into sub-namespaces: [ConsoleLogger] for
/// status lines, [ConsoleWriter] for tables, boxes and rules, [ConsoleReader]
/// for prompts, plus [Terminal] and [Cursor] for raw control.
library;

import 'logger.dart';
import 'progress.dart';
import 'reader.dart';
import 'spinner.dart';
import 'table.dart';
import 'terminal.dart';
import 'writer.dart';

export 'ansi.dart';
export 'logger.dart';
export 'progress.dart';
export 'reader.dart';
export 'spinner.dart';
export 'table.dart';
export 'terminal.dart';
export 'writer.dart';

// ============================================================================
// CONSOLE DOMAIN (system.console.*)
// ============================================================================

final ConsoleWriter _writer = ConsoleWriter();
final ConsoleLogger _logger = ConsoleLogger(_writer);
final ConsoleReader _reader = ConsoleReader();

/// Entry point for terminal IO, reachable as `system.console`.
///
/// Each concern lives in its own sub-namespace:
///
/// ```dart
/// system.console.logger.step(1, 3, 'Fetching');
/// system.console.writer.rule('Summary');
/// final go = await system.console.reader.confirm('Continue?');
/// ```
class ConsoleAccessor {
  /// Creates the accessor. Prefer the shared `system.console` instance.
  const ConsoleAccessor();

  /// Status logging: [ConsoleLogger.info], [ConsoleLogger.ok] and friends.
  ConsoleLogger get logger => _logger;

  /// Structured output: tables, boxes, rules and raw writes.
  ConsoleWriter get writer => _writer;

  /// Interactive prompts: [ConsoleReader.ask], [ConsoleReader.pick] and more.
  ConsoleReader get reader => _reader;

  /// Prompts for yes/no confirmation.
  Future<bool> confirm(String prompt, {bool fallback = false}) =>
      _reader.confirm(prompt, fallback: fallback);

  /// Prompts for a line of text.
  Future<String> ask(String prompt, {String fallback = ''}) =>
      _reader.ask(prompt, fallback: fallback);

  /// Screen control. Geometry is [ConsoleWriter.width] and
  /// [ConsoleWriter.height], on [writer].
  Terminal get terminal => Terminal(_writer);

  /// Cursor positioning and visibility.
  Cursor get cursor => Cursor(_writer);

  /// Creates a [Table] with [headers], bound to this console's writer.
  ///
  /// Pass [width] to cap the rendered width; cells then wrap to fit.
  ///
  /// **This and `Table(...)` are not the same call.** The accessor binds the
  /// shared writer, so the output interleaves correctly with
  /// `system.console.logger` and the rest of the domain. The constructor
  /// takes a writer of its own — for a second output stream, or a test.
  Table table({
    required List<String> headers,
    List<ColumnAlign>? alignments,
    TableStyle style = TableStyle.unicode,
    int? width,
  }) => Table(
    headers: headers,
    alignments: alignments,
    style: style,
    width: width,
  );

  /// Creates a [Progress] bar counting up to [total], bound to this
  /// console's writer.
  ///
  /// `Progress(...)` is the constructor, and takes a writer of its own — see
  /// [table] for why the pair is two calls rather than two spellings.
  Progress progress({
    required int total,
    int width = 25,
    ProgressUnit unit = ProgressUnit.count,
    String fill = '█',
    String empty = '░',
    String message = '',
  }) => Progress(
    total: total,
    width: width,
    unit: unit,
    fill: fill,
    empty: empty,
    message: message,
    writer: _writer,
  );

  /// Creates a [Spinner] bound to this console's writer.
  ///
  /// `Spinner(...)` is the constructor, and takes a writer of its own — see
  /// [table] for why the pair is two calls rather than two spellings.
  Spinner spinner({
    List<String> frames = Spinner.braille,
    Duration interval = const Duration(milliseconds: 80),
  }) => Spinner(frames: frames, interval: interval, writer: _writer);
}
