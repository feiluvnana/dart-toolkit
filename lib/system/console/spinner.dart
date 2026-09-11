/// # Spinners (`Spinner`)
///
/// An animated single-line status indicator. It owns a timer and a cursor
/// position, so like [Progress] it has a lifecycle: start it, then finish it.
///
/// Split out of `writer.dart` in 6.0.0. Nothing about the API moved.
library;

import 'dart:async';

import 'ansi.dart';
import 'progress.dart';
import 'terminal.dart';
import 'writer.dart';

// ============================================================================
// SPINNERS (Spinner)
// ============================================================================

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
