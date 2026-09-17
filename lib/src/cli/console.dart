import 'dart:async';
import 'dart:math';

import '../util/time.dart';
import 'ansi.dart';
import '../util/stdio.dart';

/// Progress controller for terminal activity.
///
/// Instances are created via [Console.progress].
///
/// {@category Terminal}
class ConsoleProgress {
  final int total;
  final String message;
  final int? terminalColumns;
  int _current = 0;
  bool _isDone = false;
  int _lastWidth = 0;

  ConsoleProgress._(this.total, {this.message = '', this.terminalColumns});

  int get _columns {
    if (terminalColumns != null && terminalColumns! > 0) return terminalColumns!;
    try {
      final cols = ConsoleIo.columns;
      if (cols != null) {
        return cols;
      }
    } catch (_) {}
    return 80;
  }

  /// Formats the single-line progress text for current progress and [label],
  /// truncated to fit within terminal bounds.
  String formatLine([String? label]) {
    final percent = total > 0 ? ((_current / total) * 100).clamp(0, 100).toInt() : 0;
    const barLength = 20;
    final filled = total > 0 ? ((_current / total) * barLength).clamp(0, barLength).toInt() : 0;
    final bar = '=' * filled + '-' * (barLength - filled);
    final prefix = message.isNotEmpty ? '$message: ' : '';
    final base = '  $prefix[$bar] $percent% ($_current/$total)';
    final maxCols = max(20, _columns - 1);

    var line = base;
    final baseWidth = _stringVisualWidth(base);
    if (label != null && label.isNotEmpty) {
      final availableForSuffix = maxCols - baseWidth;
      // " ($label)" requires 3 columns for " (" and ")"
      if (availableForSuffix > 5) {
        final maxLabelWidth = availableForSuffix - 3;
        final truncatedLabel = _truncateToVisualWidth(label, maxLabelWidth);
        line = '$base ($truncatedLabel)';
      }
    }

    if (_stringVisualWidth(line) > maxCols) {
      line = _truncateToVisualWidth(line, maxCols);
    }

    return line;
  }

  /// Advances the progress by [count] and optionally displays [label].
  void tick([int count = 1, String? label]) {
    if (_isDone) return;
    _current += count;
    final maxCols = max(20, _columns - 1);
    final line = formatLine(label);
    final lineWidth = _stringVisualWidth(line);
    final padding = ' ' * max(0, min(_lastWidth - lineWidth, maxCols - lineWidth));

    if (ConsoleIo.isTerminal && Ansi.enabled) {
      ConsoleIo.out.write('\r\x1b[K${line.dim}$padding');
    } else {
      ConsoleIo.out.writeln(line);
    }
    _lastWidth = lineWidth + padding.length;
  }

  /// Marks progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _isDone = true;
    _lastWidth = 0;
    if (ConsoleIo.isTerminal && Ansi.enabled) {
      ConsoleIo.out.writeln();
    }
    if (message != null && message.isNotEmpty) {
      ConsoleIo.out.writeln('  ✓ $message'.green);
    }
  }
}

class _ProgressSlot {
  String? taskId;
  String label = '';
  double? ratio;
  int? received;
  int? total;
  String? status;
  bool isDone = false;
  DateTime lastUpdated = DateTime.now();

  void update({String? taskId, String? label, double? ratio, int? received, int? total, String? status, bool? isDone}) {
    if (taskId != null) this.taskId = taskId;
    if (label != null) this.label = label;
    this.ratio = ratio;
    this.received = received;
    this.total = total;
    this.status = status;
    if (isDone != null) this.isDone = isDone;
    lastUpdated = DateTime.now();
  }

  void reset() {
    taskId = null;
    label = '';
    ratio = null;
    received = null;
    total = null;
    status = null;
    isDone = false;
    lastUpdated = DateTime.now();
  }
}

/// Multi-task concurrent progress display for terminal applications.
///
/// {@category Terminal}
class ConsoleMultiProgress {
  final int total;
  final int slots;
  final String message;
  final int? terminalColumns;
  int _current = 0;
  bool _isDone = false;
  int _renderedLines = 0;
  final List<_ProgressSlot> _slotList;
  final Map<String, int> _slotByTask = {};

  DateTime? _lastRenderTime;
  Timer? _renderTimer;

  ConsoleMultiProgress._(this.total, {this.slots = 4, this.message = '', this.terminalColumns})
    : _slotList = List.generate(slots > 0 ? slots : 1, (_) => _ProgressSlot());

  int get _columns {
    if (terminalColumns != null && terminalColumns! > 0) return terminalColumns!;
    try {
      final cols = ConsoleIo.columns;
      if (cols != null) {
        return cols;
      }
    } catch (_) {}
    return 80;
  }

  /// Formats the multi-progress lines (header + worker slots).
  List<String> formatLines() {
    final maxCols = max(20, _columns - 1);
    final lines = <String>[];

    final percent = total > 0 ? ((_current / total) * 100).clamp(0, 100).toInt() : 0;
    const barLength = 20;
    final filled = total > 0 ? ((_current / total) * barLength).clamp(0, barLength).toInt() : 0;
    final bar = '=' * filled + '-' * (barLength - filled);
    final prefix = message.isNotEmpty ? '$message: ' : '';
    final header = '  $prefix[$bar] $percent% ($_current/$total)';
    lines.add(_truncateToVisualWidth(header, maxCols));

    for (var i = 0; i < _slotList.length; i++) {
      final isLast = i == _slotList.length - 1;
      final treePfx = isLast ? '  └─ ' : '  ├─ ';
      final slotLine = _formatSlotLine(_slotList[i], treePfx, maxCols);
      lines.add(slotLine);
    }

    return lines;
  }

  String _formatSlotLine(_ProgressSlot slot, String prefix, int maxCols) {
    if (slot.taskId == null && slot.label.isEmpty) {
      return '$prefix(idle)';
    }

    const subBarLen = 10;
    final ratio = slot.ratio;
    final String barStr;
    final String percentStr;

    if (ratio != null) {
      final percent = (ratio * 100).clamp(0, 100).toInt();
      final filled = (ratio * subBarLen).clamp(0, subBarLen).toInt();
      final barChars = '=' * max(0, filled - 1) + (filled > 0 ? '>' : '') + '-' * (subBarLen - filled);
      barStr = '[$barChars]';
      percentStr = '$percent%'.padLeft(4);
    } else {
      barStr = '[----------]';
      percentStr = ' --%';
    }

    String sizeStr = '';
    if (slot.received != null && slot.total != null && slot.total! > 0) {
      final rec = _formatBytes(slot.received!);
      final tot = _formatBytes(slot.total!);
      sizeStr = '($rec/$tot) ';
    } else if (slot.received != null && slot.received! > 0) {
      sizeStr = '(${_formatBytes(slot.received!)}) ';
    }

    String statusSuffix = '';
    if (slot.status != null && slot.status!.isNotEmpty) {
      statusSuffix = ' [${slot.status}]';
    }

    final fullLine = '$prefix$barStr $percentStr $sizeStr${slot.label}$statusSuffix';
    return _truncateToVisualWidth(fullLine, maxCols);
  }

  void _render() {
    if (_isDone) return;
    if (!ConsoleIo.isTerminal || !Ansi.enabled) return;
    _renderInPlace();
  }

  void _renderInPlace() {
    final lines = formatLines();
    final buffer = StringBuffer();
    if (_renderedLines > 0) {
      buffer.write('\x1b[${_renderedLines}A');
    }
    for (final line in lines) {
      buffer.write('\r\x1b[K${line.dim}\n');
    }
    ConsoleIo.out.write(buffer.toString());
    _renderedLines = lines.length;
  }

  /// Without a terminal there is no cursor to move, so emit one durable line per
  /// completed task instead of a redrawn frame. [ConsoleProgress] behaves the same
  /// way; the two must not diverge in CI.
  void _renderCompletion(_ProgressSlot slot) {
    if (_isDone || ConsoleIo.isTerminal) return;
    final status = slot.status ?? 'done';
    final size = slot.total != null && slot.total! > 0 ? ' (${_formatBytes(slot.total!)})' : '';
    ConsoleIo.out.writeln('  [$_current/$total] ${slot.label}$size [$status]');
  }

  void _requestRender() {
    if (_isDone) return;
    final now = DateTime.now();
    if (_lastRenderTime == null || now.difference(_lastRenderTime!) >= const Duration(milliseconds: 33)) {
      _renderTimer?.cancel();
      _renderTimer = null;
      _render();
      _lastRenderTime = now;
    } else {
      _renderTimer ??= Timer(const Duration(milliseconds: 33), () {
        _renderTimer = null;
        _render();
        _lastRenderTime = DateTime.now();
      });
    }
  }

  /// Updates progress for a specific concurrent [taskId].
  void updateTask(
    String taskId, {
    required String label,
    double? ratio,
    int? received,
    int? total,
    String? status,
    bool isDone = false,
  }) {
    if (_isDone) return;

    int targetSlot;
    final existingSlot = _slotByTask[taskId];
    if (existingSlot != null) {
      targetSlot = existingSlot;
    } else {
      var found = -1;
      for (var i = 0; i < _slotList.length; i++) {
        if (_slotList[i].taskId == null || _slotList[i].isDone) {
          found = i;
          break;
        }
      }
      if (found == -1) {
        var oldest = _slotList[0].lastUpdated;
        found = 0;
        for (var i = 1; i < _slotList.length; i++) {
          if (_slotList[i].lastUpdated.isBefore(oldest)) {
            oldest = _slotList[i].lastUpdated;
            found = i;
          }
        }
      }

      final oldTask = _slotList[found].taskId;
      if (oldTask != null) {
        _slotByTask.remove(oldTask);
      }
      _slotByTask[taskId] = found;
      targetSlot = found;
    }

    _slotList[targetSlot].update(
      taskId: taskId,
      label: label,
      ratio: ratio,
      received: received,
      total: total,
      status: status,
      isDone: isDone,
    );

    if (isDone) {
      _slotByTask.remove(taskId);
      _renderCompletion(_slotList[targetSlot]);
    }

    _requestRender();
  }

  /// Advances the overall progress by [count].
  void tick([int count = 1]) {
    if (_isDone) return;
    _current += count;
    _requestRender();
  }

  /// Sets overall completed count directly.
  void setCompleted(int completed) {
    if (_isDone) return;
    _current = completed;
    _requestRender();
  }

  /// Marks multi-progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _isDone = true;
    _renderTimer?.cancel();
    _renderTimer = null;

    if (ConsoleIo.isTerminal && Ansi.enabled && _renderedLines > 0) {
      final buffer = StringBuffer();
      buffer.write('\x1b[${_renderedLines}A');
      for (var i = 0; i < _renderedLines; i++) {
        buffer.write('\r\x1b[K\n');
      }
      buffer.write('\x1b[${_renderedLines}A');
      if (message != null && message.isNotEmpty) {
        buffer.write('  ✓ $message\n'.green);
      }
      ConsoleIo.out.write(buffer.toString());
      _renderedLines = 0;
    } else {
      if (message != null && message.isNotEmpty) {
        ConsoleIo.out.writeln('  ✓ $message'.green);
      }
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Animated terminal spinner for indeterminate background tasks.
///
/// Instances are created via [Console.spinner] or run using [Console.spin].
///
/// {@category Terminal}
class ConsoleSpinner {
  static const List<String> _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  final String message;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  int _frameIndex = 0;
  bool _isDone = false;

  ConsoleSpinner._(this.message);

  /// Starts the spinner animation.
  void start() {
    _stopwatch.start();
    if (ConsoleIo.isTerminal && Ansi.enabled) {
      _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        if (_isDone) return;
        final frame = _frames[_frameIndex % _frames.length];
        _frameIndex++;
        final elapsed = _stopwatch.elapsed.humanize();
        ConsoleIo.out.write('\r\x1b[K${frame.cyan} $message (${elapsed.dim})');
      });
    } else {
      ConsoleIo.out.writeln('  ⠋ $message...');
    }
  }

  /// Stops the spinner with a success message.
  void succeed([String? successMessage]) {
    _stop();
    final elapsed = _stopwatch.elapsed.humanize();
    final text = successMessage ?? message;
    ConsoleIo.out.writeln('  ✓ $text (${elapsed.dim})'.green);
  }

  /// Stops the spinner with a failure message.
  void fail([String? errorMessage]) {
    _stop();
    final elapsed = _stopwatch.elapsed.humanize();
    final text = errorMessage ?? message;
    ConsoleIo.err.writeln('  ✖ $text ($elapsed)'.red);
  }

  /// Stops the spinner with a neutral message.
  void stop([String? finalMessage]) {
    _stop();
    final elapsed = _stopwatch.elapsed.humanize();
    final text = finalMessage ?? message;
    ConsoleIo.out.writeln('  ℹ $text ($elapsed)'.cyan);
  }

  void _stop() {
    if (_isDone) return;
    _isDone = true;
    _timer?.cancel();
    _timer = null;
    _stopwatch.stop();
    if (ConsoleIo.isTerminal && Ansi.enabled) {
      ConsoleIo.out.write('\r\x1b[K');
    }
  }

  static Future<T> _run<T>(
    String message,
    FutureOr<T> Function() action, {
    String? successMessage,
    String? failMessage,
  }) async {
    final spinner = ConsoleSpinner._(message)..start();
    try {
      final result = await action();
      spinner.succeed(successMessage);
      return result;
    } catch (e) {
      spinner.fail(failMessage ?? '$message failed: $e');
      rethrow;
    }
  }
}

int _charVisualWidth(int rune) {
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  // Combining characters / zero width
  if (rune >= 0x0300 && rune <= 0x036f) return 0;
  if (rune >= 0x200b && rune <= 0x200f) return 0;
  if (rune >= 0xfe00 && rune <= 0xfe0f) return 0;

  // East Asian Wide / Fullwidth / Emoji
  if ((rune >= 0x1100 && rune <= 0x115f) ||
      rune == 0x2329 ||
      rune == 0x232a ||
      (rune >= 0x2e80 && rune <= 0x303e) ||
      (rune >= 0x3040 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe10 && rune <= 0xfe19) ||
      (rune >= 0xfe30 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x2600 && rune <= 0x27bf) ||
      (rune >= 0x1f300 && rune <= 0x1faff) ||
      (rune >= 0x20000 && rune <= 0x2fffd) ||
      (rune >= 0x30000 && rune <= 0x3fffd)) {
    return 2;
  }
  return 1;
}

int _stringVisualWidth(String str) {
  final clean = Ansi.strip(str);
  var width = 0;
  for (final rune in clean.runes) {
    width += _charVisualWidth(rune);
  }
  return width;
}

String _truncateToVisualWidth(String str, int maxWidth) {
  if (maxWidth <= 0) return '';
  if (_stringVisualWidth(str) <= maxWidth) return str;

  const ellipsis = '...';
  const ellipsisWidth = 3;
  if (maxWidth <= ellipsisWidth) {
    return '.' * maxWidth;
  }

  final targetWidth = maxWidth - ellipsisWidth;
  final clean = Ansi.strip(str);
  final buffer = StringBuffer();
  var currentWidth = 0;

  for (final rune in clean.runes) {
    final w = _charVisualWidth(rune);
    if (currentWidth + w > targetWidth) break;
    buffer.writeCharCode(rune);
    currentWidth += w;
  }

  buffer.write(ellipsis);
  return buffer.toString();
}

/// Helpers for rendering tables, rules, and terminal animations.
///
/// {@category Terminal}
class Console {
  /// Clears the terminal screen.
  static void clear() {
    if (ConsoleIo.isTerminal && Ansi.enabled) {
      ConsoleIo.out.write('\x1B[2J\x1B[0;0H');
    }
  }

  /// Renders a horizontal divider rule across the terminal with an optional centered [title].
  static void rule([String? title]) {
    int cols = 80;
    try {
      cols = ConsoleIo.columns ?? cols;
    } catch (_) {}

    if (title == null || title.isEmpty) {
      ConsoleIo.out.writeln('─' * cols);
      return;
    }

    final cleanTitle = Ansi.strip(title);
    final titleLen = cleanTitle.length + 2;
    if (titleLen >= cols) {
      ConsoleIo.out.writeln('── $title ──');
      return;
    }

    final sideLen = (cols - titleLen) ~/ 2;
    final left = '─' * sideLen;
    final right = '─' * (cols - titleLen - sideLen);
    ConsoleIo.out.writeln('$left $title $right'.cyan);
  }

  /// Renders a formatted text table with borders to standard output.
  static void table({required List<String> headers, required List<List<dynamic>> rows}) {
    if (headers.isEmpty && rows.isEmpty) return;

    final numCols = headers.isNotEmpty ? headers.length : (rows.isNotEmpty ? rows.first.length : 0);
    final colWidths = List<int>.filled(numCols, 0);

    for (var i = 0; i < headers.length; i++) {
      colWidths[i] = max(colWidths[i], _stringVisualWidth(headers[i]));
    }

    for (final row in rows) {
      for (var i = 0; i < row.length && i < numCols; i++) {
        colWidths[i] = max(colWidths[i], _stringVisualWidth('${row[i]}'));
      }
    }

    String buildDivider(String left, String mid, String right, String cross) {
      final parts = colWidths.map((w) => mid * (w + 2));
      return '$left${parts.join(cross)}$right';
    }

    String formatRow(List<dynamic> cells) {
      final parts = <String>[];
      for (var i = 0; i < numCols; i++) {
        final val = i < cells.length ? '${cells[i]}' : '';
        final pad = ' ' * (colWidths[i] - _stringVisualWidth(val));
        parts.add(' $val$pad ');
      }
      return '│${parts.join('│')}│';
    }

    ConsoleIo.out.writeln(buildDivider('┌', '─', '┐', '┬'));
    if (headers.isNotEmpty) {
      ConsoleIo.out.writeln(formatRow(headers));
      ConsoleIo.out.writeln(buildDivider('├', '─', '┤', '┼'));
    }
    for (final row in rows) {
      ConsoleIo.out.writeln(formatRow(row));
    }
    ConsoleIo.out.writeln(buildDivider('└', '─', '┘', '┴'));
  }

  /// Creates a single-line progress indicator for [total] steps.
  static ConsoleProgress progress(int total, {String message = '', int? terminalColumns}) =>
      ConsoleProgress._(total, message: message, terminalColumns: terminalColumns);

  /// Creates a multi-line concurrent progress indicator for [total] steps across [slots] workers.
  static ConsoleMultiProgress multiProgress(int total, {int slots = 4, String message = '', int? terminalColumns}) =>
      ConsoleMultiProgress._(total, slots: slots, message: message, terminalColumns: terminalColumns);

  /// Creates an indeterminate animated spinner.
  static ConsoleSpinner spinner(String message) => ConsoleSpinner._(message);

  /// Executes [action] while displaying an animated spinner with [message].
  static Future<T> spin<T>(
    String message,
    FutureOr<T> Function() action, {
    String? successMessage,
    String? failMessage,
  }) => ConsoleSpinner._run(message, action, successMessage: successMessage, failMessage: failMessage);
}
