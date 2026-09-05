import 'dart:io';

// ============================================================================
// TERMINAL GEOMETRY & CURSOR
// ============================================================================

/// Terminal display geometry and screen manipulation namespace.
class Terminal {
  /// Current terminal columns/width, defaulting to 80 if not attached to a TTY.
  int get width {
    try {
      if (stdout.hasTerminal) return stdout.terminalColumns;
    } catch (_) {}
    return 80;
  }

  /// Current terminal lines/height, defaulting to 24 if not attached to a TTY.
  int get height {
    try {
      if (stdout.hasTerminal) return stdout.terminalLines;
    } catch (_) {}
    return 24;
  }

  /// Clears the entire terminal screen and moves cursor to home (top-left).
  void clear() {
    if (stdout.hasTerminal) {
      stdout.write('\x1B[2J\x1B[H');
    }
  }

  /// Clears the current line in standard output.
  void line() {
    if (stdout.hasTerminal) {
      stdout.write('\x1B[2K');
    }
  }

  /// Emits an audible terminal alert bell (`\x07`).
  void bell() => stdout.write('\x07');
}

/// Terminal cursor manipulation namespace.
class Cursor {
  /// Hides the terminal cursor.
  void hide() {
    if (stdout.hasTerminal) stdout.write('\x1B[?25l');
  }

  /// Restores and shows the terminal cursor.
  void show() {
    if (stdout.hasTerminal) stdout.write('\x1B[?25h');
  }

  /// Moves the cursor up by [n] lines (default: 1).
  void up([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}A');
  }

  /// Moves the cursor down by [n] lines (default: 1).
  void down([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}B');
  }

  /// Moves the cursor forward (right) by [n] columns (default: 1).
  void forward([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}C');
  }

  /// Moves the cursor back (left) by [n] columns (default: 1).
  void back([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}D');
  }

  /// Moves the cursor to the home position (line 1, column 1).
  void home() {
    if (stdout.hasTerminal) stdout.write('\x1B[H');
  }

  /// Saves the current cursor position.
  void save() {
    if (stdout.hasTerminal) stdout.write('\x1B[s');
  }

  /// Restores the previously saved cursor position.
  void restore() {
    if (stdout.hasTerminal) stdout.write('\x1B[u');
  }
}
