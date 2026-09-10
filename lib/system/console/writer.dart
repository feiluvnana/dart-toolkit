/// # Console Writer, Table, Progress & Spinner
///
/// Structured terminal output. Widths are measured with [Ansi.width],
/// so coloured cells still align.
library;

import 'dart:async';
import 'dart:io';

import '../../util/size.dart';
import '../../util/time.dart';
import 'ansi.dart';
import 'terminal.dart';

// ============================================================================
// CONSOLE WRITER, TABLE, PROGRESS & SPINNER
// ============================================================================

const SizeAccessor _size = SizeAccessor();
const TimeAccessor _time = TimeAccessor();

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
/// Build it, then [render] it to a string — printing is [ConsoleWriter.table]'s
/// job:
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

  /// Appends one [row]. Cells are rendered with `toString`.
  void add(List<Object?> row) =>
      _rows.add(row.map((cell) => cell?.toString() ?? '').toList());

  /// Appends every row of [rows].
  void addAll(Iterable<List<Object?>> rows) => rows.forEach(add);

  /// The number of appended rows.
  int get length => _rows.length;

  /// Renders the table, including a trailing newline.
  String render() {
    final columns = headers.length;
    if (columns == 0) return '';

    final header = [for (var i = 0; i < columns; i++) headers[i].bold()];
    final widths = _widths(columns, header);

    String rule(String left, String mid, String right) =>
        [
          left,
          [for (var i = 0; i < columns; i++) style.horizontal * (widths[i] + 2)]
              .join(mid),
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

    final buffer =
        StringBuffer()
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
      final columns = Ansi.width(line);
      if (columns > widest) widest = columns;
    }
    return widest;
  }

  String _pad(String text, int width, ColumnAlign align) {
    // Bold headers carry escape codes, so pad by visible width, not length.
    final pad = (width - Ansi.width(text)).clamp(0, width);
    return switch (align) {
      ColumnAlign.left => '$text${' ' * pad}',
      ColumnAlign.right => '${' ' * pad}$text',
      ColumnAlign.center => '${' ' * (pad ~/ 2)}$text${' ' * (pad - pad ~/ 2)}',
    };
  }
}

/// What a [Progress] bar is counting.
enum ProgressUnit {
  /// Plain item counts.
  count,

  /// Byte totals, rendered with [SizeAccessor.format].
  bytes,
}

/// A single-line progress bar with rate and ETA.
///
/// Renders only to a terminal, so piped output stays clean.
///
/// ```dart
/// final bar = Progress(total: files.count(), message: 'Downloading');
/// for (final f in files.list) { await io.async.read(f.path); bar.tick(); }
/// bar.done('Finished');
/// ```
class Progress {
  /// Where the bar is drawn. Defaults to stdout.
  final ConsoleWriter writer;

  /// The target count, updatable through [update].
  int total;

  /// Width of the bar itself, in characters.
  final int width;

  /// Whether [total] counts items or bytes.
  final ProgressUnit unit;

  /// Character filling completed space.
  final String fill;

  /// Character filling remaining space.
  final String empty;

  final Stopwatch _clock = Stopwatch();
  int _current = 0;
  String _message;
  DateTime? _painted;

  /// Creates a bar counting up to [total].
  ///
  /// The glyph defaults match `system.console.progress`, so a bar built either
  /// way looks the same.
  Progress({
    required this.total,
    this.width = 25,
    this.unit = ProgressUnit.count,
    this.fill = '█',
    this.empty = '░',
    String message = '',
    ConsoleWriter? writer,
  }) : _message = message,
       writer = writer ?? ConsoleWriter() {
    _clock.start();
  }

  /// The current count.
  int get current => _current;

  /// Sets the count to [current], optionally changing [total] or [message].
  ///
  /// Repaints at most every 80ms, and always on completion.
  void update(int current, {int? total, String? message}) {
    if (total != null) this.total = total;
    if (message != null) _message = message;
    _current = current;

    final now = DateTime.now();
    final due =
        _painted == null ||
        now.difference(_painted!).inMilliseconds > 80 ||
        _current >= this.total;
    if (!due) return;
    _painted = now;
    render();
  }

  /// Advances the count by [delta].
  void tick([int delta = 1, String? message]) =>
      update(_current + delta, message: message);

  /// Repaints the bar in place.
  void render() {
    if (!writer.tty) return;
    final fraction = total > 0 ? (_current / total).clamp(0.0, 1.0) : 0.0;
    final filled = (width * fraction).round();
    final metrics =
        unit == ProgressUnit.bytes
            ? '${_size.format(_current)} / ${_size.format(total)}'
            : '$_current / $total';

    final parts = [
      if (_message.isNotEmpty) _message.brightcyan(),
      '[${fill * filled}${empty * (width - filled).clamp(0, width)}]'.bold(),
      '${(fraction * 100).toStringAsFixed(1)}%'.padLeft(6).green(),
      '($metrics)'.dim(),
      ..._rate(),
    ];

    Terminal(writer).line();
    writer.write('\r${parts.join(' ')}');
  }

  /// Rate and ETA, once there is enough elapsed time to be meaningful.
  List<String> _rate() {
    final elapsed = _clock.elapsed;
    if (elapsed.inMilliseconds <= 300 || _current <= 0) return const [];
    final perSecond = _current / (elapsed.inMilliseconds / 1000);
    final rate =
        unit == ProgressUnit.bytes
            ? '${_size.format(perSecond.round())}/s'
            : '${perSecond.toStringAsFixed(1)} items/s';
    if (total <= _current || perSecond <= 0) return [rate.dim()];
    final remaining = Duration(
      seconds: ((total - _current) / perSecond).round(),
    );
    return [rate.dim(), 'ETA ${_time.format(remaining)}'.dim()];
  }

  /// Fills the bar, prints [message] and moves to the next line.
  ///
  /// Off a terminal nothing was drawn, so nothing is closed off either — a
  /// bare newline would be the one mark a redirected run still carried.
  void done([String? message]) {
    _clock.stop();
    update(total, message: message);
    if (writer.tty) writer.writeln();
  }

  /// Abandons the bar and reports [message] as a failure.
  void fail([String? message]) {
    _clock.stop();
    if (writer.tty) writer.writeln();
    if (message != null) writer.errorln('${'✖'.brightred()} $message');
  }
}

/// An animated single-line spinner for work of unknown length.
///
/// ```dart
/// final spinner = Spinner()..start('Resolving');
/// await work();
/// spinner.ok('Resolved');
/// ```
class Spinner {
  /// Braille frames used by default.
  static const List<String> braille = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  /// Where the spinner is drawn. Defaults to stdout.
  final ConsoleWriter writer;

  /// Animation frames, in order.
  final List<String> frames;

  /// Delay between frames.
  final Duration interval;

  Timer? _timer;
  int _frame = 0;
  String _message = '';

  /// Creates a spinner.
  Spinner({
    this.frames = braille,
    this.interval = const Duration(milliseconds: 80),
    ConsoleWriter? writer,
  }) : writer = writer ?? ConsoleWriter();

  /// Whether the spinner is currently animating.
  bool get spinning => _timer != null;

  /// Starts animating with [message].
  void start([String message = '']) {
    if (spinning) return;
    _message = message;
    _frame = 0;
    Cursor(writer).hide();
    _render();
    _timer = Timer.periodic(interval, (_) {
      _frame = (_frame + 1) % frames.length;
      _render();
    });
  }

  /// Replaces the message without interrupting the animation.
  void update(String message) {
    _message = message;
    if (spinning) _render();
  }

  /// Stops animating and clears the line.
  void stop() {
    if (!spinning) return;
    _timer?.cancel();
    _timer = null;
    if (writer.tty) {
      Terminal(writer).line();
      writer.write('\r');
    }
    Cursor(writer).show();
  }

  /// Stops and reports success, defaulting to the current message.
  void ok([String? message]) {
    stop();
    writer.writeln('${'✔'.brightgreen()} ${message ?? _message}');
  }

  /// Stops and reports failure to stderr.
  void fail([String? message]) {
    stop();
    writer.errorln('${'✖'.brightred()} ${message ?? _message}');
  }

  void _render() {
    if (!writer.tty) return;
    Terminal(writer).line();
    writer.write('\r${frames[_frame].brightcyan().bold()} $_message');
  }
}

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

  /// Renders [table] to [out].
  void table(Table table) => out.write(table.render());

  /// Writes a full-width horizontal rule, optionally captioned with [title].
  void rule([String title = '']) {
    final width = this.width;
    if (title.isEmpty) {
      out.writeln('─' * width);
      return;
    }
    final caption = ' $title ';
    final remaining = width - Ansi.width(caption);
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
    var inner = title != null ? Ansi.width(title) + 4 : 0;
    for (final line in lines) {
      final length = Ansi.width(line);
      if (length > inner) inner = length;
    }

    final caption = title != null ? ' ${title.bold()} ' : '';
    final pad = inner + 2 - Ansi.width(caption);
    final left = pad ~/ 2;

    out.writeln(
      '${style.topleft}${style.horizontal * left}$caption'
      '${style.horizontal * (pad - left)}${style.topright}',
    );
    for (final line in lines) {
      final fill = ' ' * (inner - Ansi.width(line));
      out.writeln('${style.vertical} $line$fill ${style.vertical}');
    }
    out.writeln(
      '${style.bottomleft}${style.horizontal * (inner + 2)}'
      '${style.bottomright}',
    );
  }
}
