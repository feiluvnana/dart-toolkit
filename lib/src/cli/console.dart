import 'dart:async';
import 'dart:math';

import '../util/progress.dart';
import '../util/stdio.dart';
import '../util/time.dart';
import 'ansi.dart';

/// Coalesces redraws so a producer that reports per chunk does not issue a write
/// per chunk. Shared by [ConsoleProgress] and [ConsoleMultiProgress]; they must not
/// disagree about how often the terminal is touched. Always draws the *latest* state.
class _FrameGate {
  static const _interval = Duration(milliseconds: 33);
  DateTime? _last;
  Timer? _timer;
  void Function()? _pending;

  void request(void Function() render) {
    final now = DateTime.now();
    if (_last == null || now.difference(_last!) >= _interval) {
      _timer?.cancel();
      _timer = null;
      _pending = null;
      render();
      _last = now;
    } else {
      _pending = render;
      _timer ??= Timer(_interval, flush);
    }
  }

  /// Draws a deferred frame now, so `done()` never leaves the last state unrendered.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final render = _pending;
    _pending = null;
    if (render != null) {
      render();
      _last = DateTime.now();
    }
  }
}

int _columnsOr(int? fixed) {
  if (fixed != null && fixed > 0) return fixed;
  return ConsoleIo.columns ?? 80;
}

String _bar(int current, int total, String message) {
  const barLength = 20;
  final percent = total > 0 ? ((current / total) * 100).clamp(0, 100).toInt() : 0;
  final filled = total > 0 ? ((current / total) * barLength).clamp(0, barLength).toInt() : 0;
  final bar = '=' * filled + '-' * (barLength - filled);
  final prefix = message.isNotEmpty ? '$message: ' : '';
  return '  $prefix[$bar] $percent% ($current/$total)';
}

bool _interactive() => ConsoleIo.isTerminal && Ansi.enabled;

/// Progress controller for terminal activity.
///
/// Instances are created via [Console.progress].
///
/// {@category Terminal}
class ConsoleProgress {
  final int total;
  final String message;
  final int? columns;
  int _current = 0;
  bool _isDone = false;
  int _lastWidth = 0;
  int _lastDecile = -1;
  final _frames = _FrameGate();

  ConsoleProgress._(this.total, {this.message = '', this.columns});

  /// Formats the single-line progress text for current progress and [label],
  /// truncated to fit within terminal bounds.
  String formatLine([String? label]) {
    final base = _bar(_current, total, message);
    final maxCols = max(20, _columnsOr(columns) - 1);

    var line = base;
    if (label != null && label.isNotEmpty) {
      final availableForSuffix = maxCols - _stringVisualWidth(base);
      // " ($label)" requires 3 columns for " (" and ")"
      if (availableForSuffix > 5) line = '$base (${_truncateToVisualWidth(label, availableForSuffix - 3)})';
    }
    return _truncateToVisualWidth(line, maxCols);
  }

  /// Advances the progress by [count] and optionally displays [label].
  ///
  /// Redraws are coalesced at the same rate as [ConsoleMultiProgress]', so a caller
  /// may tick per chunk. Without a terminal a line is written when a new tenth is
  /// reached, not per tick.
  void tick([int count = 1, String? label]) {
    if (_isDone) return;
    _current += count;
    if (_interactive()) {
      _frames.request(() => _render(label));
    } else {
      final decile = total > 0 ? (_current * 10 ~/ total).clamp(0, 10) : 0;
      if (decile != _lastDecile) {
        _lastDecile = decile;
        ConsoleIo.out.writeln(formatLine(label));
      }
    }
  }

  void _render(String? label) {
    final maxCols = max(20, _columnsOr(columns) - 1);
    final line = formatLine(label);
    final lineWidth = _stringVisualWidth(line);
    final padding = ' ' * max(0, min(_lastWidth - lineWidth, maxCols - lineWidth));
    ConsoleIo.out.write('\r\x1b[K${line.dim}$padding');
    _lastWidth = lineWidth + padding.length;
  }

  /// Marks progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _frames.flush();
    _isDone = true;
    _lastWidth = 0;
    if (_interactive()) ConsoleIo.out.writeln();
    if (message != null && message.isNotEmpty) ConsoleIo.out.writeln('  ✓ $message'.green);
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

  void update(TaskProgress task) {
    taskId = task.taskId;
    label = task.label;
    ratio = task.ratio;
    received = task.received;
    total = task.total;
    status = task.status;
    isDone = task.isDone;
    lastUpdated = DateTime.now();
  }
}

/// Multi-task concurrent progress display for terminal applications.
///
/// Driven by [report]; it renders whatever a [BatchProgress] carries.
///
/// {@category Terminal}
class ConsoleMultiProgress {
  /// Steps in the batch. A stream-sourced batch revises it upward as work is discovered.
  int total;
  final int slots;
  final String message;
  final int? columns;
  int _current = 0;
  bool _isDone = false;
  int _renderedLines = 0;
  final List<_ProgressSlot> _slotList;
  final Map<String, int> _slotByTask = {};
  final _frames = _FrameGate();

  ConsoleMultiProgress._(this.total, {this.slots = 4, this.message = '', this.columns})
    : _slotList = List.generate(slots > 0 ? slots : 1, (_) => _ProgressSlot());

  /// Formats the multi-progress lines (header + worker slots).
  List<String> formatLines() {
    final maxCols = max(20, _columnsOr(columns) - 1);
    return [
      _truncateToVisualWidth(_bar(_current, total, message), maxCols),
      for (var i = 0; i < _slotList.length; i++)
        _formatSlotLine(_slotList[i], i == _slotList.length - 1 ? '  └─ ' : '  ├─ ', maxCols),
    ];
  }

  String _formatSlotLine(_ProgressSlot slot, String prefix, int maxCols) {
    if (slot.taskId == null && slot.label.isEmpty) return '$prefix(idle)';

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

    var sizeStr = '';
    if (slot.received != null && slot.total != null && slot.total! > 0) {
      sizeStr = '(${_formatBytes(slot.received!)}/${_formatBytes(slot.total!)}) ';
    } else if (slot.received != null && slot.received! > 0) {
      sizeStr = '(${_formatBytes(slot.received!)}) ';
    }

    final statusSuffix = slot.status != null && slot.status!.isNotEmpty ? ' [${slot.status}]' : '';
    return _truncateToVisualWidth('$prefix$barStr $percentStr $sizeStr${slot.label}$statusSuffix', maxCols);
  }

  void _render() {
    if (_isDone || !_interactive()) return;
    final buffer = StringBuffer();
    if (_renderedLines > 0) buffer.write('\x1b[${_renderedLines}A');
    final lines = formatLines();
    for (final line in lines) {
      buffer.write('\r\x1b[K${line.dim}\n');
    }
    ConsoleIo.out.write(buffer.toString());
    _renderedLines = lines.length;
  }

  /// Without a terminal there is no cursor to move, so emit one durable line per
  /// completed task instead of a redrawn frame.
  void _renderCompletion(_ProgressSlot slot) {
    if (_isDone || ConsoleIo.isTerminal) return;
    final status = slot.status ?? 'done';
    final size = slot.total != null && slot.total! > 0 ? ' (${_formatBytes(slot.total!)})' : '';
    ConsoleIo.out.writeln('  [$_current/$total] ${slot.label}$size [$status]');
  }

  int _slotFor(String taskId) {
    final existing = _slotByTask[taskId];
    if (existing != null) return existing;

    var found = _slotList.indexWhere((s) => s.taskId == null || s.isDone);
    if (found == -1) {
      found = 0;
      for (var i = 1; i < _slotList.length; i++) {
        if (_slotList[i].lastUpdated.isBefore(_slotList[found].lastUpdated)) found = i;
      }
    }
    final oldTask = _slotList[found].taskId;
    if (oldTask != null) _slotByTask.remove(oldTask);
    _slotByTask[taskId] = found;
    return found;
  }

  /// Renders one [BatchProgress] update: the overall count, a revised [total], and
  /// the current task's slot.
  void report(BatchProgress batch) {
    if (_isDone) return;
    final discovered = batch.total;
    if (discovered != null && discovered > total) total = discovered;
    _current = batch.completed;

    final task = batch.current;
    final slot = _slotList[_slotFor(task.taskId)]..update(task);
    if (task.isDone) {
      _slotByTask.remove(task.taskId);
      _renderCompletion(slot);
    }
    _frames.request(_render);
  }

  /// Marks multi-progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _frames.flush();
    _isDone = true;

    if (_interactive() && _renderedLines > 0) {
      final buffer = StringBuffer('\x1b[${_renderedLines}A');
      for (var i = 0; i < _renderedLines; i++) {
        buffer.write('\r\x1b[K\n');
      }
      buffer.write('\x1b[${_renderedLines}A');
      if (message != null && message.isNotEmpty) buffer.write('  ✓ $message\n'.green);
      ConsoleIo.out.write(buffer.toString());
      _renderedLines = 0;
    } else if (message != null && message.isNotEmpty) {
      ConsoleIo.out.writeln('  ✓ $message'.green);
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
    if (_interactive()) {
      _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        if (_isDone) return;
        final frame = _frames[_frameIndex++ % _frames.length];
        ConsoleIo.out.write('\r\x1b[K${frame.cyan} $message (${_stopwatch.elapsed.humanized.dim})');
      });
    } else {
      ConsoleIo.out.writeln('  ⠋ $message...');
    }
  }

  /// Stops the spinner with a success message.
  void succeed([String? successMessage]) {
    _stop();
    ConsoleIo.out.writeln('  ✓ ${successMessage ?? message} (${_stopwatch.elapsed.humanized.dim})'.green);
  }

  /// Stops the spinner with a failure message.
  void fail([String? errorMessage]) {
    _stop();
    ConsoleIo.err.writeln('  ✖ ${errorMessage ?? message} (${_stopwatch.elapsed.humanized})'.red);
  }

  /// Stops the spinner with a neutral message.
  void stop([String? finalMessage]) {
    _stop();
    ConsoleIo.out.writeln('  ℹ ${finalMessage ?? message} (${_stopwatch.elapsed.humanized})'.cyan);
  }

  void _stop() {
    if (_isDone) return;
    _isDone = true;
    _timer?.cancel();
    _timer = null;
    _stopwatch.stop();
    if (_interactive()) ConsoleIo.out.write('\r\x1b[K');
  }

  static Future<T> _run<T>(String message, FutureOr<T> Function() action, {String? done, String? failed}) async {
    final spinner = ConsoleSpinner._(message)..start();
    try {
      final result = await action();
      spinner.succeed(done);
      return result;
    } catch (e) {
      spinner.fail(failed ?? '$message failed: $e');
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

  // East Asian Wide / Fullwidth / Emoji. Dingbats (✓ ✖ ⚠, U+2600–27BF) are one column.
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
      (rune >= 0x1f300 && rune <= 0x1faff) ||
      (rune >= 0x20000 && rune <= 0x2fffd) ||
      (rune >= 0x30000 && rune <= 0x3fffd)) {
    return 2;
  }
  return 1;
}

int _stringVisualWidth(String str) {
  var width = 0;
  for (final rune in Ansi.strip(str).runes) {
    width += _charVisualWidth(rune);
  }
  return width;
}

String _truncateToVisualWidth(String str, int maxWidth) {
  if (maxWidth <= 0) return '';
  if (_stringVisualWidth(str) <= maxWidth) return str;

  const ellipsis = '...';
  if (maxWidth <= ellipsis.length) return '.' * maxWidth;

  final targetWidth = maxWidth - ellipsis.length;
  final buffer = StringBuffer();
  var currentWidth = 0;
  for (final rune in Ansi.strip(str).runes) {
    final w = _charVisualWidth(rune);
    if (currentWidth + w > targetWidth) break;
    buffer.writeCharCode(rune);
    currentWidth += w;
  }
  return '$buffer$ellipsis';
}

/// Helpers for rendering tables, rules, and terminal animations.
///
/// {@category Terminal}
class Console {
  /// Clears the terminal screen.
  static void clear() {
    if (_interactive()) ConsoleIo.out.write('\x1B[2J\x1B[0;0H');
  }

  /// Renders a horizontal divider rule across the terminal with an optional centered [title].
  static void rule([String? title]) {
    final cols = ConsoleIo.columns ?? 80;

    if (title == null || title.isEmpty) {
      ConsoleIo.out.writeln('─' * cols);
      return;
    }

    final titleLen = _stringVisualWidth(title) + 2;
    if (titleLen >= cols) {
      ConsoleIo.out.writeln('── $title ──');
      return;
    }

    final sideLen = (cols - titleLen) ~/ 2;
    ConsoleIo.out.writeln('${'─' * sideLen} $title ${'─' * (cols - titleLen - sideLen)}'.cyan);
  }

  /// Renders a formatted text table with borders to standard output.
  static void table({required List<String> headers, required List<List<Object?>> rows}) {
    if (headers.isEmpty && rows.isEmpty) return;

    final numCols = headers.isNotEmpty ? headers.length : rows.first.length;
    final cells = [
      for (final row in rows) [for (var i = 0; i < numCols; i++) i < row.length ? '${row[i]}' : ''],
    ];
    final widths = [for (final h in headers) _stringVisualWidth(h)];
    while (widths.length < numCols) {
      widths.add(0);
    }
    for (final row in cells) {
      for (var i = 0; i < numCols; i++) {
        widths[i] = max(widths[i], _stringVisualWidth(row[i]));
      }
    }

    String divider(String left, String mid, String right, String cross) =>
        '$left${widths.map((w) => mid * (w + 2)).join(cross)}$right';

    String formatRow(List<String> row) =>
        '│${[for (var i = 0; i < numCols; i++) ' ${row[i]}${' ' * (widths[i] - _stringVisualWidth(row[i]))} '].join('│')}│';

    ConsoleIo.out.writeln(divider('┌', '─', '┐', '┬'));
    if (headers.isNotEmpty) {
      ConsoleIo.out.writeln(formatRow(headers));
      ConsoleIo.out.writeln(divider('├', '─', '┤', '┼'));
    }
    for (final row in cells) {
      ConsoleIo.out.writeln(formatRow(row));
    }
    ConsoleIo.out.writeln(divider('└', '─', '┘', '┴'));
  }

  /// Creates a single-line progress indicator for [total] steps.
  static ConsoleProgress progress(int total, {String message = '', int? columns}) =>
      ConsoleProgress._(total, message: message, columns: columns);

  /// Creates a multi-line concurrent progress indicator across [slots] workers.
  ///
  /// Omit [total] when the work is still being discovered; [ConsoleMultiProgress.report]
  /// revises it upward as it arrives.
  static ConsoleMultiProgress multiProgress({int total = 0, int slots = 4, String message = '', int? columns}) =>
      ConsoleMultiProgress._(total, slots: slots, message: message, columns: columns);

  /// Creates an indeterminate animated spinner.
  static ConsoleSpinner spinner(String message) => ConsoleSpinner._(message);

  /// Runs [action] behind a spinner; [done] and [failed] replace [message] on the final line.
  static Future<T> spin<T>(String message, FutureOr<T> Function() action, {String? done, String? failed}) =>
      ConsoleSpinner._run(message, action, done: done, failed: failed);
}

/// Rendering a batch as it runs.
///
/// {@category Terminal}
extension StreamBatchProgressExtensions<T extends BatchProgress> on Stream<T> {
  /// Draws this batch in a [ConsoleMultiProgress] until it ends, then prints [done].
  ///
  /// Returns the last event, or `null` for an empty batch.
  ///
  /// ```dart
  /// final last = await pairs.downloadAll(concurrency: 4).show(slots: 4, message: 'Downloading');
  /// ```
  Future<T?> show({int slots = 4, String message = '', String? done, int? columns}) async {
    final progress = Console.multiProgress(slots: slots, message: message, columns: columns);
    T? last;
    var failed = true;
    try {
      await for (final p in this) {
        progress.report(last = p);
      }
      failed = false;
    } finally {
      progress.done(failed ? null : done);
    }
    return last;
  }
}
