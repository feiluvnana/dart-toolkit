/// # Console Domain (`system.console.*`)
///
/// Terminal output and input, split into sub-namespaces: [ConsoleLogger] for
/// status lines, [ConsoleWriter] for tables, boxes and rules, [ConsoleReader]
/// for prompts, plus [Terminal] and [Cursor] for raw control.
library;

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

  /// Screen control. Geometry is [ConsoleWriter.width] and
  /// [ConsoleWriter.height], on [writer].
  Terminal get terminal => Terminal(_writer);

  /// Cursor positioning and visibility.
  Cursor get cursor => Cursor(_writer);

  /// Creates a [Table] with [headers].
  ///
  /// Pass [width] to cap the rendered width; cells then wrap to fit.
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

  /// Creates a [Progress] bar counting up to [total].
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

  /// Creates a [Spinner].
  Spinner spinner({
    List<String> frames = Spinner.braille,
    Duration interval = const Duration(milliseconds: 80),
  }) => Spinner(frames: frames, interval: interval, writer: _writer);
}
