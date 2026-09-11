/// # Tables (`Table`)
///
/// A grid rendered to the terminal, with alignment, wrapping and a border
/// style. Column widths are measured in terminal columns — `String.width` —
/// so a coloured or CJK cell still lines up.
///
/// Split out of `writer.dart` in 6.0.0, which held seven public types of
/// which one was a writer. Nothing about the API moved.
library;

import '../../collection/collection.dart';
import 'ansi.dart';
import 'writer.dart';

// ============================================================================
// TABLES (Table)
// ============================================================================

/// Horizontal alignment of a [Table] column.
enum ColumnAlign {
  /// Pad on the right.
  left,

  /// Pad both sides.
  center,

  /// Pad on the left.
  right,
}

/// Box-drawing characters used by [Table] and [ConsoleWriter.box].
class TableStyle {
  /// Top-left corner.
  final String topleft;

  /// Top-right corner.
  final String topright;

  /// Bottom-left corner.
  final String bottomleft;

  /// Bottom-right corner.
  final String bottomright;

  /// Horizontal rule segment.
  final String horizontal;

  /// Vertical rule segment.
  final String vertical;

  /// Interior four-way junction.
  final String cross;

  /// Junction on the top edge.
  final String topdivider;

  /// Junction on the bottom edge.
  final String bottomdivider;

  /// Junction on the left edge.
  final String leftdivider;

  /// Junction on the right edge.
  final String rightdivider;

  /// Creates a style. Prefer [unicode] or [ascii].
  const TableStyle({
    required this.topleft,
    required this.topright,
    required this.bottomleft,
    required this.bottomright,
    required this.horizontal,
    required this.vertical,
    required this.cross,
    required this.topdivider,
    required this.bottomdivider,
    required this.leftdivider,
    required this.rightdivider,
  });

  /// Box-drawing characters. The default.
  static const TableStyle unicode = TableStyle(
    topleft: '┌',
    topright: '┐',
    bottomleft: '└',
    bottomright: '┘',
    horizontal: '─',
    vertical: '│',
    cross: '┼',
    topdivider: '┬',
    bottomdivider: '┴',
    leftdivider: '├',
    rightdivider: '┤',
  );

  /// Pure-ASCII characters, for terminals without box drawing.
  static const TableStyle ascii = TableStyle(
    topleft: '+',
    topright: '+',
    bottomleft: '+',
    bottomright: '+',
    horizontal: '-',
    vertical: '|',
    cross: '+',
    topdivider: '+',
    bottomdivider: '+',
    leftdivider: '+',
    rightdivider: '+',
  );
}

/// A bordered text table.
///
/// Build it, then [render] it to a string — printing it is
/// `system.console.writer.write(table.render())`, which is what
/// `ConsoleWriter.table` was a second spelling of:
///
/// ```dart
/// final table = Table(headers: ['Metric', 'Value'])
///   ..add(['Crawled', 128]);
/// print(table.render());
/// ```
///
/// A cell may hold newlines, and with a [width] the table wraps to fit rather
/// than running off the screen:
///
/// ```dart
/// final table = Table(headers: ['URL', 'Error'], width: 60)
///   ..add([url, 'Connection reset\nRetried 3 times']);
/// ```
class Table {
  /// Column headers, which also fix the column count.
  final List<String> headers;

  /// Per-column alignment, defaulting to [ColumnAlign.left].
  final List<ColumnAlign> alignments;

  /// Border characters.
  final TableStyle style;

  /// The widest the rendered table may be, in terminal columns.
  ///
  /// Columns are narrowed widest-first until the whole table fits, and their
  /// cells wrap to the width they end up with. `null` lets the table be as
  /// wide as its content needs.
  final int? width;

  final List<List<String>> _rows = [];

  /// Creates a table with [headers].
  ///
  /// [alignments] is padded to the column count with [ColumnAlign.left], so a
  /// partial list aligns the columns it names and leaves the rest alone
  /// instead of failing when the table is rendered.
  Table({
    required this.headers,
    List<ColumnAlign>? alignments,
    this.style = TableStyle.unicode,
    this.width,
  }) : alignments = [
         for (var i = 0; i < headers.length; i++)
           (alignments != null && i < alignments.length)
               ? alignments[i]
               : ColumnAlign.left,
       ];

  /// Appends a row, or every row of an iterable.
  ///
  /// ```dart no-compile
  /// table.add(['app', '1.4 MB', 'ok']);   // one
  /// table.add.all(rows);                  // many
  /// ```
  ///
  /// Two members under one name, the way `count()` and `count.by` are: the
  /// plural was `addAll` through 6.1.0, the library's last camelCase member
  /// on a type it declares, and Rule 4 splits a compound at the capital
  /// rather than joining it. Cells are rendered with `toString`.
  late final TableAdd add = TableAdd._(this);

  /// Renders the table, including a trailing newline.
  String render() {
    final columns = headers.length;
    if (columns == 0) return '';

    final header = [for (var i = 0; i < columns; i++) headers[i].bold()];
    final widths = _widths(columns, header);

    String rule(String left, String mid, String right) => [
      left,
      [
        for (var i = 0; i < columns; i++) style.horizontal * (widths[i] + 2),
      ].join(mid),
      right,
    ].join();

    /// One row, as however many physical lines its tallest cell needs.
    String row(List<String> cells) {
      final wrapped = [
        for (var i = 0; i < columns; i++)
          Ansi.wrap(i < cells.length ? cells[i] : '', widths[i]),
      ];
      final height = wrapped.fold(
        1,
        (tallest, cell) => cell.length > tallest ? cell.length : tallest,
      );

      final buffer = StringBuffer();
      for (var line = 0; line < height; line++) {
        buffer
          ..write(style.vertical)
          ..writeAll([
            for (var i = 0; i < columns; i++)
              ' ${_pad(line < wrapped[i].length ? wrapped[i][line] : '', widths[i], alignments[i])} '
                  '${style.vertical}',
          ])
          ..writeln();
      }
      return buffer.toString();
    }

    final buffer = StringBuffer()
      ..writeln(rule(style.topleft, style.topdivider, style.topright))
      ..write(row(header))
      ..writeln(rule(style.leftdivider, style.cross, style.rightdivider));
    for (final cells in _rows) {
      buffer.write(row(cells));
    }
    buffer.writeln(
      rule(style.bottomleft, style.bottomdivider, style.bottomright),
    );
    return buffer.toString();
  }

  /// The width of each column: what its widest line needs, narrowed to fit
  /// [width] when one is set.
  List<int> _widths(int columns, List<String> header) {
    final widths = List<int>.generate(columns, (col) {
      var widest = _widest(header[col]);
      for (final row in _rows) {
        if (col >= row.length) continue;
        final cell = _widest(row[col]);
        if (cell > widest) widest = cell;
      }
      return widest;
    });

    final cap = width;
    if (cap == null) return widths;

    // Every column costs its content plus a space either side and a border.
    // The table opens with one more border, so: 1 + sum(w + 3).
    final budget = cap - 1 - 3 * columns;
    if (budget < columns) {
      // No width worth speaking of. One column apiece is the narrowest a
      // table can be while still being a table.
      return List<int>.filled(columns, 1);
    }

    var total = widths.fold(0, (sum, w) => sum + w);
    while (total > budget) {
      // Narrow the widest column first, so a table of one long URL and three
      // short numbers wraps the URL rather than everything.
      var widest = 0;
      for (var i = 1; i < columns; i++) {
        if (widths[i] > widths[widest]) widest = i;
      }
      if (widths[widest] <= 1) break;
      widths[widest]--;
      total--;
    }
    return widths;
  }

  /// The widest line in [cell], which may hold newlines of its own.
  static int _widest(String cell) {
    var widest = 0;
    for (final line in cell.split('\n')) {
      final columns = line.width;
      if (columns > widest) widest = columns;
    }
    return widest;
  }

  String _pad(String text, int width, ColumnAlign align) {
    // Bold headers carry escape codes, so pad by visible width, not length.
    final pad = (width - text.width).clamp(0, width);
    return switch (align) {
      ColumnAlign.left => '$text${' ' * pad}',
      ColumnAlign.right => '${' ' * pad}$text',
      ColumnAlign.center => '${' ' * (pad ~/ 2)}$text${' ' * (pad - pad ~/ 2)}',
    };
  }
}

/// The namespace behind [Table.add].
///
/// Callable, so `table.add(row)` is the singular and `table.add.all(rows)`
/// the plural — one word each, no capital in the middle.
class TableAdd {
  const TableAdd._(this._table);

  final Table _table;

  /// Appends one [row].
  void call(List<Object?> row) =>
      _table._rows.add([for (final cell in row) cell?.toString() ?? '']);

  /// Appends every row of [rows].
  ///
  /// A [Sequence] of rows, so what `format.csv.parse(...).rows` and
  /// `io.csv.rows` read goes straight into a table; `.seq` turns a literal
  /// grid into one. Each row stays a `List`, because its cells are a tuple
  /// read by position and not a collection to be shaped.
  void all(Sequence<List<Object?>> rows) =>
      rows.transform(.cast<List<Object?>>()).collect(.foreach(call));
}
