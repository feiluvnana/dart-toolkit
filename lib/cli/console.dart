import 'dart:io';
import 'dart:math';

import '../collection/collection.dart';
import 'ansi.dart';

/// Progress controller for terminal activity.
class ConsoleProgress {
  final int total;
  final String message;
  int _current = 0;
  bool _isDone = false;

  ConsoleProgress(this.total, {this.message = ''});

  /// Advances the progress by [count] and optionally displays [label].
  void tick([int count = 1, String? label]) {
    if (_isDone) return;
    _current += count;
    final percent = total > 0 ? ((_current / total) * 100).clamp(0, 100).toInt() : 0;
    final barLength = 20;
    final filled = total > 0 ? ((_current / total) * barLength).clamp(0, barLength).toInt() : 0;
    final bar = '=' * filled + '-' * (barLength - filled);
    final prefix = message.isNotEmpty ? '$message: ' : '';
    final suffix = label != null ? ' ($label)' : '';
    stdout.write('\r  $prefix[$bar] $percent% ($_current/$total)$suffix'.dim);
  }

  /// Marks progress as done with an optional final [message].
  void done([String? message]) {
    if (_isDone) return;
    _isDone = true;
    stdout.writeln();
    if (message != null && message.isNotEmpty) {
      stdout.writeln('  ✓ $message'.green);
    }
  }
}

/// Helper class for terminal layout, rules, tables, and progress tracking.
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
  static ConsoleProgress progress(int total, {String? message}) => ConsoleProgress(total, message: message ?? '');
}
