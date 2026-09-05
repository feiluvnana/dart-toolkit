import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'ansi.dart';
import 'terminal.dart';

// ============================================================================
// CONSOLE WRITER, TABLE, PROGRESS & SPINNER
// ============================================================================

/// Alignment options for table columns.
enum ColumnAlign {
  /// Left-aligned column content.
  left,

  /// Centered column content.
  center,

  /// Right-aligned column content.
  right,
}

/// Border styling definition for [Table].
class TableStyle {
  /// Top-left corner character.
  final String topLeft;

  /// Top-right corner character.
  final String topRight;

  /// Bottom-left corner character.
  final String bottomLeft;

  /// Bottom-right corner character.
  final String bottomRight;

  /// Horizontal border character.
  final String horizontal;

  /// Vertical border character.
  final String vertical;

  /// Cross intersection character.
  final String cross;

  /// Top header divider character.
  final String topDivider;

  /// Bottom footer divider character.
  final String bottomDivider;

  /// Left row divider character.
  final String leftDivider;

  /// Right row divider character.
  final String rightDivider;

  /// Creates custom table border styling.
  const TableStyle({
    required this.topLeft,
    required this.topRight,
    required this.bottomLeft,
    required this.bottomRight,
    required this.horizontal,
    required this.vertical,
    required this.cross,
    required this.topDivider,
    required this.bottomDivider,
    required this.leftDivider,
    required this.rightDivider,
  });

  /// Standard Unicode box-drawing table borders (`┌─┬─┐`).
  static const TableStyle unicode = TableStyle(
    topLeft: '┌',
    topRight: '┐',
    bottomLeft: '└',
    bottomRight: '┘',
    horizontal: '─',
    vertical: '│',
    cross: '┼',
    topDivider: '┬',
    bottomDivider: '┴',
    leftDivider: '├',
    rightDivider: '┤',
  );

  /// ASCII-compatible table borders (`+-+-+`).
  static const TableStyle ascii = TableStyle(
    topLeft: '+',
    topRight: '+',
    bottomLeft: '+',
    bottomRight: '+',
    horizontal: '-',
    vertical: '|',
    cross: '+',
    topDivider: '+',
    bottomDivider: '+',
    leftDivider: '+',
    rightDivider: '+',
  );
}

/// A formatted tabular display generator.
class Table {
  /// Column header titles.
  final List<String> headers;
  final List<List<String>> _rows = [];

  /// Alignments per column.
  final List<ColumnAlign> columnAlignments;

  /// Border style.
  final TableStyle style;

  /// Creates a table instance with [headers].
  Table({
    required this.headers,
    List<ColumnAlign>? alignments,
    this.style = TableStyle.unicode,
  }) : columnAlignments =
           alignments ?? List.filled(headers.length, ColumnAlign.left);

  /// Appends a single row or multiple rows.
  void add(Object? rowOrRows) {
    if (rowOrRows is Iterable<List<Object?>>) {
      for (final r in rowOrRows) {
        add(r);
      }
    } else if (rowOrRows is List) {
      _rows.add(rowOrRows.map((e) => e?.toString() ?? '').toList());
    }
  }

  /// Renders the table into a multi-line formatted string.
  String render() {
    final colCount = headers.length;
    final widths = List<int>.filled(colCount, 0);

    for (var col = 0; col < colCount; col++) {
      var maxW = Ansi.visibleLength(headers[col]);
      for (final row in _rows) {
        if (col < row.length) {
          final len = Ansi.visibleLength(row[col]);
          if (len > maxW) maxW = len;
        }
      }
      widths[col] = maxW;
    }

    final buf = StringBuffer();
    buf.write(style.topLeft);
    for (var i = 0; i < colCount; i++) {
      buf.write(style.horizontal * (widths[i] + 2));
      if (i < colCount - 1) buf.write(style.topDivider);
    }
    buf.writeln(style.topRight);

    buf.write(style.vertical);
    for (var i = 0; i < colCount; i++) {
      buf.write(' ');
      buf.write(_align(headers[i], widths[i], columnAlignments[i]).bold());
      buf.write(' ');
      buf.write(style.vertical);
    }
    buf.writeln();

    buf.write(style.leftDivider);
    for (var i = 0; i < colCount; i++) {
      buf.write(style.horizontal * (widths[i] + 2));
      if (i < colCount - 1) buf.write(style.cross);
    }
    buf.writeln(style.rightDivider);

    for (final row in _rows) {
      buf.write(style.vertical);
      for (var i = 0; i < colCount; i++) {
        final cell = i < row.length ? row[i] : '';
        final align = i < columnAlignments.length
            ? columnAlignments[i]
            : ColumnAlign.left;
        buf.write(' ');
        buf.write(_align(cell, widths[i], align));
        buf.write(' ');
        buf.write(style.vertical);
      }
      buf.writeln();
    }

    buf.write(style.bottomLeft);
    for (var i = 0; i < colCount; i++) {
      buf.write(style.horizontal * (widths[i] + 2));
      if (i < colCount - 1) buf.write(style.bottomDivider);
    }
    buf.writeln(style.bottomRight);

    return buf.toString();
  }

  /// Directly prints the rendered table to stdout.
  void print() {
    stdout.write(render());
  }

  String _align(String text, int width, ColumnAlign align) {
    final vLen = Ansi.visibleLength(text);
    final pad = (width - vLen).clamp(0, width);
    switch (align) {
      case ColumnAlign.left:
        return '$text${' ' * pad}';
      case ColumnAlign.right:
        return '${' ' * pad}$text';
      case ColumnAlign.center:
        final left = (pad / 2).floor();
        final right = pad - left;
        return '${' ' * left}$text${' ' * right}';
    }
  }
}

/// Unit displayed alongside progress metrics.
enum ProgressUnit {
  /// Unit counted in items / discrete units.
  count,

  /// Unit counted in bytes (KB, MB, GB).
  bytes,
}

/// An interactive, real-time command-line progress bar.
class Progress {
  /// Total target count or bytes. Can be updated dynamically.
  int total;

  /// Visual character width of the progress bar gauge.
  final int width;

  /// Metrics unit (count vs bytes).
  final ProgressUnit unit;

  /// Fill character for completed progress.
  final String fill;

  /// Head pointer character.
  final String head;

  /// Empty track character.
  final String empty;

  int _current = 0;
  String _msg = '';
  final Stopwatch _stopwatch = Stopwatch();
  DateTime? _lastRender;

  /// Creates and initializes a progress bar.
  Progress({
    required this.total,
    this.width = 25,
    this.unit = ProgressUnit.bytes,
    this.fill = '=',
    this.head = '>',
    this.empty = ' ',
    String message = '',
  }) : _msg = message {
    _stopwatch.start();
  }

  /// Current completed progress count or bytes.
  int get current => _current;

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(
      0,
      units.length - 1,
    );
    final val = bytes / math.pow(1024, i);
    return '${val.toStringAsFixed(1)} ${units[i]}';
  }

  static String _formatDuration(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    final s = duration.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  /// Updates current progress to [current] with optional [newTotal] and status [message].
  void update(int current, {int? newTotal, String? message}) {
    if (newTotal != null) total = newTotal;
    _current = current;
    if (message != null) _msg = message;

    final now = DateTime.now();
    if (_lastRender == null ||
        now.difference(_lastRender!).inMilliseconds > 80 ||
        _current >= total) {
      _lastRender = now;
      render();
    }
  }

  /// Increments progress by [delta] (default: 1) with optional status [message].
  void tick([int delta = 1, String? message]) {
    update(_current + delta, message: message);
  }

  /// Renders the current progress bar state to the terminal line.
  void render() {
    if (!stdout.hasTerminal) return;

    final pct = total > 0 ? (_current / total).clamp(0.0, 1.0) : 0.0;
    final filled = (width * pct).round();
    final rem = (width - filled).clamp(0, width);

    final bar = '[${fill * filled}${empty * rem}]';
    final pctStr = '${(pct * 100).toStringAsFixed(1)}%'.padLeft(6);

    final metrics = unit == ProgressUnit.bytes
        ? '${_formatSize(_current)} / ${_formatSize(total)}'
        : '$_current / $total';

    final el = _stopwatch.elapsed;
    var speedStr = '';
    var etaStr = '';

    if (el.inMilliseconds > 300 && _current > 0) {
      final rate = _current / (el.inMilliseconds / 1000.0);
      speedStr = unit == ProgressUnit.bytes
          ? '${_formatSize(rate.round())}/s'
          : '${rate.toStringAsFixed(1)} items/s';

      if (total > _current && rate > 0) {
        final sec = ((total - _current) / rate).round();
        etaStr = 'ETA ${_formatDuration(Duration(seconds: sec))}';
      }
    }

    final parts = [
      if (_msg.isNotEmpty) _msg.brightCyan(),
      bar.bold(),
      pctStr.green(),
      '($metrics)'.dim(),
      if (speedStr.isNotEmpty) speedStr.dim(),
      if (etaStr.isNotEmpty) etaStr.dim(),
    ];

    final term = Terminal();
    term.line();
    stdout.write('\r${parts.join(' ')}');
  }

  /// Finalizes the progress bar at 100% with optional [message].
  void done([String? message]) {
    _stopwatch.stop();
    update(total, message: message);
    stdout.writeln();
  }

  /// Aborts the progress bar with an error symbol and optional [message].
  void fail([String? message]) {
    _stopwatch.stop();
    stdout.writeln();
    if (message != null) stderr.writeln('${'✖'.brightRed()} $message');
  }
}

/// An animated terminal spinner indicator.
class Spinner {
  /// Default Braille dot animation frames.
  static const List<String> defaultFrames = [
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

  /// The list of character frames for the animation loop.
  final List<String> frames;

  /// Duration interval between animation frame ticks.
  final Duration interval;
  Timer? _timer;
  int _idx = 0;
  String _msg = '';
  bool _spinning = false;

  /// Creates a spinner instance.
  Spinner({
    this.frames = defaultFrames,
    this.interval = const Duration(milliseconds: 80),
  });

  /// Starts the spinner animation with initial [message].
  void start([String message = '']) {
    if (_spinning) return;
    _spinning = true;
    _msg = message;
    _idx = 0;

    Cursor().hide();
    _render();

    _timer = Timer.periodic(interval, (_) {
      _idx = (_idx + 1) % frames.length;
      _render();
    });
  }

  /// Updates the message displayed next to the running spinner.
  void update(String message) {
    _msg = message;
    if (_spinning) _render();
  }

  void _render() {
    if (!stdout.hasTerminal) return;
    Terminal().line();
    stdout.write('\r${frames[_idx].brightCyan().bold()} $_msg');
  }

  /// Stops the spinner animation and restores cursor visibility.
  void stop() {
    if (!_spinning) return;
    _spinning = false;
    _timer?.cancel();
    _timer = null;
    Terminal().line();
    stdout.write('\r');
    Cursor().show();
  }

  /// Stops the spinner with a green success checkmark and optional [message].
  void ok([String? message]) {
    stop();
    stdout.writeln('${'✔'.brightGreen()} ${message ?? _msg}');
  }

  /// Stops the spinner with a red error cross and optional [message].
  void fail([String? message]) {
    stop();
    stderr.writeln('${'✖'.brightRed()} ${message ?? _msg}');
  }
}

/// Dedicated console formatting and structured output writer.
class ConsoleWriter {
  final Terminal _terminal = Terminal();

  /// Renders and prints a formatted table with [headers] and optional [rows].
  Table table(
    List<String> headers, [
    List<List<Object?>>? rows,
    List<ColumnAlign>? alignments,
    TableStyle style = TableStyle.unicode,
  ]) {
    final tbl = Table(headers: headers, alignments: alignments, style: style);
    if (rows != null) {
      for (final r in rows) {
        tbl.add(r);
      }
    }
    tbl.print();
    return tbl;
  }

  /// Outputs a full-width horizontal divider rule with optional centered [title].
  void rule([String title = '']) {
    final w = _terminal.width;
    if (title.isEmpty) {
      stdout.writeln('─' * w);
      return;
    }
    final pad = ' $title ';
    final rem = w - Ansi.visibleLength(pad);
    final left = (rem / 2).floor().clamp(2, w);
    final right = (rem - left).clamp(2, w);
    stdout.writeln('${'─' * left}${pad.bold()}${'─' * right}');
  }

  /// Writes a line to standard output.
  void line([String message = '']) {
    stdout.writeln(message);
  }

  /// Writes text to standard output without trailing newline.
  void write(String message) {
    stdout.write(message);
  }

  /// Displays text enclosed inside a decorative bordered callout box.
  void box(
    String text, {
    String? title,
    TableStyle style = TableStyle.unicode,
  }) {
    final lines = text.split('\n');
    var maxLen = title != null ? Ansi.visibleLength(title) + 4 : 0;
    for (final l in lines) {
      final len = Ansi.visibleLength(l);
      if (len > maxLen) maxLen = len;
    }

    final topTitle = title != null ? ' ${title.bold()} ' : '';
    final topPad = maxLen + 2 - Ansi.visibleLength(topTitle);
    final leftTop = (topPad / 2).floor();
    final rightTop = topPad - leftTop;

    stdout.writeln(
      '${style.topLeft}${style.horizontal * leftTop}$topTitle${style.horizontal * rightTop}${style.topRight}',
    );
    for (final l in lines) {
      final pad = maxLen - Ansi.visibleLength(l);
      stdout.writeln('${style.vertical} $l${' ' * pad} ${style.vertical}');
    }
    stdout.writeln(
      '${style.bottomLeft}${style.horizontal * (maxLen + 2)}${style.bottomRight}',
    );
  }

  /// Creates a progress bar instance for [total] units with optional [message].
  Progress bar(int total, [String message = '']) =>
      Progress(total: total, message: message, unit: ProgressUnit.count);

  /// Creates and starts an animated spinner with optional [message].
  Spinner spin([String message = '']) => Spinner()..start(message);
}
