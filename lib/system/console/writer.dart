/// # Console Writer (`ConsoleWriter`)
///
/// Where structured terminal output goes: the sinks, whether they are a
/// terminal, and how wide it is. Widths are measured with `String.width`, so
/// coloured cells still align.
///
/// [Table], [Progress] and [Spinner] were declared here through 5.5.0 — seven
/// public types in one file, of which one was a writer. They are in
/// `table.dart`, `progress.dart` and `spinner.dart` now. That was a file
/// layout problem and the fix was a file layout fix: no name moved, and the
/// barrel exports all four.
library;

import 'dart:io';

import 'ansi.dart';
import 'table.dart';
import 'terminal.dart';

// ============================================================================
// CONSOLE WRITER (ConsoleWriter)
// ============================================================================

/// Structured terminal output, reachable as `system.console.writer`.
///
/// Everything in this library that writes to the screen writes through one of
/// these — tables, rules, boxes, the logger, progress bars, spinners, and the
/// cursor and screen control in [Terminal] and [Cursor]. Give it a
/// [StringBuffer] and the output is a value a test can assert on:
///
/// ```dart
/// final buffer = StringBuffer();
/// final writer = ConsoleWriter(out: buffer, tty: true, width: 40);
/// Progress(total: 2, writer: writer)..tick()..done('Finished');
/// expect(buffer.toString(), contains('Finished'));
/// ```
class ConsoleWriter {
  /// Standard output sink.
  final StringSink out;

  /// Standard error sink.
  final StringSink err;

  final bool _tty;
  final int? _width;
  final int? _height;

  /// Creates a console writer. Defaults to [stdout] and [stderr].
  ///
  /// [tty] decides whether anything that only makes sense on a screen —
  /// escape codes, a repainting progress bar, a spinner — is written at all.
  /// It defaults to whether **stdout** is a terminal for a writer that uses
  /// stdout, and to `false` for one given a sink of its own, since a
  /// [StringBuffer] or a file wants text rather than control codes. Pass it
  /// explicitly to capture what a terminal would have received.
  ///
  /// [width] and [height] override the terminal's size, which is what lets a
  /// test render a table or a rule at a size it can predict.
  ConsoleWriter({
    StringSink? out,
    StringSink? err,
    bool? tty,
    int? width,
    int? height,
  }) : out = out ?? stdout,
       err = err ?? stderr,
       _width = width,
       _height = height,
       _tty = tty ?? (out == null && _stdoutIsTerminal());

  static bool _stdoutIsTerminal() {
    try {
      return stdout.hasTerminal;
    } catch (_) {
      // Querying a detached or redirected stdout can throw on some platforms.
      return false;
    }
  }

  /// Whether output is going to a terminal.
  ///
  /// False for a redirected run, so a script's piped output carries no escape
  /// codes, no repainted bars and no spinner frames.
  bool get tty => _tty;

  /// The width in columns: the override given to the constructor, the
  /// terminal's own width, or `80` when there is no terminal to ask.
  int get width => _width ?? _terminalSize(true, 80);

  /// The height in rows, on the same terms as [width], defaulting to `24`.
  int get height => _height ?? _terminalSize(false, 24);

  int _terminalSize(bool columns, int fallback) {
    try {
      if (stdout.hasTerminal) {
        return columns ? stdout.terminalColumns : stdout.terminalLines;
      }
    } catch (_) {}
    return fallback;
  }

  /// Writes [message] with no trailing newline.
  void write(String message) => out.write(message);

  /// Writes [message] followed by a newline.
  void writeln([String message = '']) => out.writeln(message);

  /// Writes [message] to the error sink.
  void error(String message) => err.write(message);

  /// Writes [message] followed by a newline to the error sink.
  void errorln([String message = '']) => err.writeln(message);

  /// Writes a full-width horizontal rule, optionally captioned with [title].
  void rule([String title = '']) {
    final width = this.width;
    if (title.isEmpty) {
      out.writeln('─' * width);
      return;
    }
    final caption = ' $title ';
    final remaining = width - caption.width;
    if (remaining < 4) {
      // No room to rule around it; the caption is the line.
      out.writeln(caption.trim().bold());
      return;
    }
    final left = (remaining ~/ 2).clamp(2, width);
    final right = (remaining - left).clamp(2, width);
    out.writeln('${'─' * left}${caption.bold()}${'─' * right}');
  }

  /// Writes [text] inside a box, optionally captioned with [title].
  void box(
    String text, {
    String? title,
    TableStyle style = TableStyle.unicode,
  }) {
    final lines = text.split('\n');
    var inner = title != null ? title.width + 4 : 0;
    for (final line in lines) {
      final length = line.width;
      if (length > inner) inner = length;
    }

    final caption = title != null ? ' ${title.bold()} ' : '';
    final pad = inner + 2 - caption.width;
    final left = pad ~/ 2;

    out.writeln(
      '${style.topleft}${style.horizontal * left}$caption'
      '${style.horizontal * (pad - left)}${style.topright}',
    );
    for (final line in lines) {
      final fill = ' ' * (inner - line.width);
      out.writeln('${style.vertical} $line$fill ${style.vertical}');
    }
    out.writeln(
      '${style.bottomleft}${style.horizontal * (inner + 2)}'
      '${style.bottomright}',
    );
  }
}
