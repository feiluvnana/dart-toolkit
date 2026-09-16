import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../collection/collection.dart';
import '../util/time.dart';
import 'ansi.dart';

/// Progress controller for terminal activity.
///
/// Instances are created via [Console.progress].
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
      if (stdout.hasTerminal) {
        return stdout.terminalColumns;
      }
    } catch (_) {}
    return 80;
  }

  /// Formats the single-line progress text for current progress and [label],
  /// truncated to fit within terminal bounds.
  String formatLine([String? label]) {
    final percent = total > 0 ? ((_current / total) * 100).clamp(0, 100).toInt() : 0;
    final barLength = 20;
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
    stdout.write('\r\x1b[K${line.dim}$padding');
    _lastWidth = lineWidth + padding.length;
  }

  /// Marks progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _isDone = true;
    _lastWidth = 0;
    stdout.writeln();
    if (message != null && message.isNotEmpty) {
      stdout.writeln('  ✓ $message'.green);
    }
  }
}

/// Animated terminal spinner for indeterminate background tasks.
///
/// Instances are created via [Console.spinner] or run using [Console.spin].
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
    if (_isDone) return;
    _stopwatch.start();

    if (!stdout.hasTerminal) {
      stdout.writeln('  ℹ $message...'.cyan);
      return;
    }

    _render();
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      _frameIndex = (_frameIndex + 1) % _frames.length;
      _render();
    });
  }

  void _render() {
    if (_isDone) return;
    final frame = _frames[_frameIndex].cyan;
    stdout.write('\r\x1b[K  $frame $message');
  }

  /// Stops the spinner with a success message.
  void success([String? finalMessage]) {
    _stop();
    final elapsed = _stopwatch.elapsed.humanize().dim;
    final text = finalMessage ?? message;
    stdout.writeln('  ✓ $text ($elapsed)'.green);
  }

  /// Stops the spinner with a failure message.
  void fail([String? errorMessage]) {
    _stop();
    final elapsed = _stopwatch.elapsed.humanize().dim;
    final text = errorMessage ?? message;
    stderr.writeln('  ✖ $text ($elapsed)'.red);
  }

  /// Stops the spinner with an informational message.
  void info([String? infoMessage]) {
    _stop();
    final elapsed = _stopwatch.elapsed.humanize().dim;
    final text = infoMessage ?? message;
    stdout.writeln('  ℹ $text ($elapsed)'.cyan);
  }

  void _stop() {
    if (_isDone) return;
    _isDone = true;
    _timer?.cancel();
    _timer = null;
    _stopwatch.stop();
    if (stdout.hasTerminal) {
      stdout.write('\r\x1b[K');
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
      spinner.success(successMessage);
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
  var width = 0;
  for (final rune in str.runes) {
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
  final buffer = StringBuffer();
  var currentWidth = 0;

  for (final rune in str.runes) {
    final w = _charVisualWidth(rune);
    if (currentWidth + w > targetWidth) break;
    buffer.writeCharCode(rune);
    currentWidth += w;
  }

  buffer.write(ellipsis);
  return buffer.toString();
}

/// Helper class for terminal layout, rules, tables, progress tracking, and spinners.
class Console {
  /// Prints a horizontal divider line with an optional centered [title].
  static void rule([String? title]) {
    const width = 60;
    if (title == null || title.isEmpty) {
      stdout.writeln(('=' * width).dim);
      return;
    }
    final paddedTitle = ' $title ';
    final remaining = max(0, width - paddedTitle.length);
    final left = remaining ~/ 2;
    final right = remaining - left;
    stdout.writeln('${'=' * left}$paddedTitle${'=' * right}'.bold);
  }

  /// Prints an aligned ASCII / ANSI table with [headers] and [rows].
  static void table({required List<String> headers, required List<List<Object?>> rows}) {
    if (headers.isEmpty) return;

    final columnWidths = List<int>.generate(headers.length, (i) => headers[i].length);
    final stringRows = rows.map((row) {
      return List<String>.generate(headers.length, (i) {
        final val = i < row.length ? '${row[i] ?? ""}' : '';
        if (val.length > columnWidths[i]) {
          columnWidths[i] = val.length;
        }
        return val;
      });
    }).toList();

    String buildBorder(String left, String mid, String right, String fill) {
      return left + columnWidths.map((w) => fill * (w + 2)).join(mid) + right;
    }

    // Top border
    stdout.writeln(buildBorder('┌', '┬', '┐', '─').dim);

    // Header row
    final headerContent = headers.mapIndexed((i, h) => h.padRight(columnWidths[i])).join(' │ ');
    final headerRow = '│ $headerContent │';
    stdout.writeln(headerRow.bold);

    // Header separator
    stdout.writeln(buildBorder('├', '┼', '┤', '─').dim);

    // Content rows
    for (final row in stringRows) {
      final rowContent = row.mapIndexed((i, val) => val.padRight(columnWidths[i])).join(' │ ');
      final line = '│ $rowContent │';
      stdout.writeln(line);
    }

    // Bottom border
    stdout.writeln(buildBorder('└', '┴', '┘', '─').dim);
  }

  /// Creates and starts a [ConsoleProgress] tracker.
  static ConsoleProgress progress(int total, {String? message, int? terminalColumns}) =>
      ConsoleProgress._(total, message: message ?? '', terminalColumns: terminalColumns);

  /// Creates an indeterminate [ConsoleSpinner] with [message].
  static ConsoleSpinner spinner(String message) => ConsoleSpinner._(message);

  /// Runs [action] while animating a terminal spinner with [message].
  static Future<T> spin<T>(
    String message,
    FutureOr<T> Function() action, {
    String? successMessage,
    String? failMessage,
  }) =>
      ConsoleSpinner._run(message, action, successMessage: successMessage, failMessage: failMessage);
}
