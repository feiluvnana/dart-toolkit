/// # Terminal & Cursor Control
///
/// Screen and cursor control, written through a [ConsoleWriter]. Every method
/// is a no-op when that writer is not a terminal, so piped and redirected
/// output stays clean.
library;

import 'writer.dart';

// ============================================================================
// TERMINAL & CURSOR CONTROL
// ============================================================================

/// Screen control, reachable as `system.console.terminal`.
///
/// The terminal's size is [ConsoleWriter.width] and [ConsoleWriter.height]:
/// geometry belongs to the thing that knows where the output is going.
class Terminal {
  /// The writer control codes are written to.
  final ConsoleWriter writer;

  /// Creates an accessor writing through [writer], or to stdout by default.
  ///
  /// Prefer the shared `system.console.terminal`. Pass a writer of your own to
  /// capture what would have been sent to the screen.
  Terminal([ConsoleWriter? writer]) : writer = writer ?? ConsoleWriter();

  /// Clears the screen and homes the cursor.
  void clear() => _emit('\x1B[2J\x1B[H');

  /// Erases the current line.
  void line() => _emit('\x1B[2K');

  /// Rings the terminal bell.
  void bell() => _emit('\x07');

  void _emit(String code) {
    if (writer.tty) writer.write(code);
  }
}

/// Cursor control, reachable as `system.console.cursor`.
class Cursor {
  /// The writer control codes are written to.
  final ConsoleWriter writer;

  /// Creates an accessor writing through [writer], or to stdout by default.
  ///
  /// Prefer the shared `system.console.cursor`.
  Cursor([ConsoleWriter? writer]) : writer = writer ?? ConsoleWriter();

  /// Hides the cursor.
  void hide() => _emit('\x1B[?25l');

  /// Shows the cursor.
  void show() => _emit('\x1B[?25h');

  /// Moves the cursor up [n] rows.
  void up([int n = 1]) => _emit('\x1B[${n}A');

  /// Moves the cursor down [n] rows.
  void down([int n = 1]) => _emit('\x1B[${n}B');

  /// Moves the cursor right [n] columns.
  void forward([int n = 1]) => _emit('\x1B[${n}C');

  /// Moves the cursor left [n] columns.
  void back([int n = 1]) => _emit('\x1B[${n}D');

  /// Homes the cursor to the top-left.
  void home() => _emit('\x1B[H');

  /// Saves the cursor position.
  void save() => _emit('\x1B[s');

  /// Restores the saved cursor position.
  void restore() => _emit('\x1B[u');

  void _emit(String code) {
    if (writer.tty) writer.write(code);
  }
}
