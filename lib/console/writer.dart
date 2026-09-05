import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'ansi.dart';
import 'terminal.dart';

// ============================================================================
// CONSOLE WRITER, TABLE, PROGRESS & SPINNER
// ============================================================================

enum ColumnAlign { left, center, right }

class TableStyle {
  final String topLeft;
  final String topRight;
  final String bottomLeft;
  final String bottomRight;
  final String horizontal;
  final String vertical;
  final String cross;
  final String topDivider;
  final String bottomDivider;
  final String leftDivider;
  final String rightDivider;

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

class Table {
  final List<String> headers;
  final List<List<String>> _rows = [];
  final List<ColumnAlign> columnAlignments;
  final TableStyle style;

  Table({
    required this.headers,
    List<ColumnAlign>? alignments,
    this.style = TableStyle.unicode,
  }) : columnAlignments =
            alignments ?? List.filled(headers.length, ColumnAlign.left);

  void add(dynamic rowOrRows) {
    if (rowOrRows is Iterable<List<Object?>>) {
      for (final r in rowOrRows) {
        add(r);
      }
    } else if (rowOrRows is List) {
      _rows.add(rowOrRows.map((e) => e?.toString() ?? '').toList());
    }
  }

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

enum ProgressUnit { count, bytes }

class Progress {
  int total;
  final int width;
  final ProgressUnit unit;
  final String fill;
  final String head;
  final String empty;

  int _current = 0;
  String _msg = '';
  final Stopwatch _stopwatch = Stopwatch();
  DateTime? _lastRender;

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

  int get current => _current;

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(0, units.length - 1);
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

  void tick([int delta = 1, String? message]) {
    update(_current + delta, message: message);
  }

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

  void done([String? message]) {
    _stopwatch.stop();
    update(total, message: message);
    stdout.writeln();
  }

  void fail([String? message]) {
    _stopwatch.stop();
    stdout.writeln();
    if (message != null) stderr.writeln('${'✖'.brightRed()} $message');
  }
}

class Spinner {
  static const List<String> defaultFrames = [
    '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'
  ];

  final List<String> frames;
  final Duration interval;
  Timer? _timer;
  int _idx = 0;
  String _msg = '';
  bool _spinning = false;

  Spinner({
    this.frames = defaultFrames,
    this.interval = const Duration(milliseconds: 80),
  });

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

  void update(String message) {
    _msg = message;
    if (_spinning) _render();
  }

  void _render() {
    if (!stdout.hasTerminal) return;
    Terminal().line();
    stdout.write('\r${frames[_idx].brightCyan().bold()} $_msg');
  }

  void stop() {
    if (!_spinning) return;
    _spinning = false;
    _timer?.cancel();
    _timer = null;
    Terminal().line();
    stdout.write('\r');
    Cursor().show();
  }

  void ok([String? message]) {
    stop();
    stdout.writeln('${'✔'.brightGreen()} ${message ?? _msg}');
  }

  void fail([String? message]) {
    stop();
    stderr.writeln('${'✖'.brightRed()} ${message ?? _msg}');
  }
}

/// Dedicated console formatting and structured output writer.
class ConsoleWriter {
  final Terminal _terminal = Terminal();

  /// Render and print a formatted table in 1 shot.
  Table table(
    List<String> headers, [
    List<List<dynamic>>? rows,
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

  /// Output a horizontal divider rule.
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

  /// Write a single line to standard output.
  void line([String message = '']) {
    stdout.writeln(message);
  }

  /// Write text without newline.
  void write(String message) {
    stdout.write(message);
  }

  /// Write text in a bordered box.
  void box(String text, {String? title, TableStyle style = TableStyle.unicode}) {
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

    stdout.writeln('${style.topLeft}${style.horizontal * leftTop}$topTitle${style.horizontal * rightTop}${style.topRight}');
    for (final l in lines) {
      final pad = maxLen - Ansi.visibleLength(l);
      stdout.writeln('${style.vertical} $l${' ' * pad} ${style.vertical}');
    }
    stdout.writeln('${style.bottomLeft}${style.horizontal * (maxLen + 2)}${style.bottomRight}');
  }

  /// Create a progress bar instance.
  Progress bar(int total, [String message = '']) =>
      Progress(total: total, message: message, unit: ProgressUnit.count);

  /// Create and start an animated spinner.
  Spinner spin([String message = '']) => Spinner()..start(message);
}
