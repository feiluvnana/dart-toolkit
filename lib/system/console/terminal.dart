/// # Terminal Geometry & Cursor
///
/// Size queries and raw cursor control. Every method is a no-op when stdout is
/// not a terminal, so piped and redirected output stays clean.
library;

import 'dart:io';

// ============================================================================
// TERMINAL GEOMETRY & CURSOR
// ============================================================================

/// Terminal size and screen control, reachable as `system.console.terminal`.
class Terminal {
  /// Creates the accessor. Prefer the shared `system.console.terminal` instance.
  const Terminal();

  /// The terminal width in columns, or `80` when unavailable.
  int get width {
    try {
      if (stdout.hasTerminal) return stdout.terminalColumns;
    } catch (_) {}
    return 80;
  }

  /// The terminal height in rows, or `24` when unavailable.
  int get height {
    try {
      if (stdout.hasTerminal) return stdout.terminalLines;
    } catch (_) {}
    return 24;
  }

  /// Clears the screen and homes the cursor.
  void clear() => _emit('\x1B[2J\x1B[H');

  /// Erases the current line.
  void line() => _emit('\x1B[2K');

  /// Rings the terminal bell.
  void bell() => _emit('\x07');

  static void _emit(String code) {
    if (stdout.hasTerminal) stdout.write(code);
  }
}

/// Cursor control, reachable as `system.console.cursor`.
class Cursor {
  /// Creates the accessor. Prefer the shared `system.console.cursor` instance.
  const Cursor();

  /// Hides the cursor.
  void hide() => Terminal._emit('\x1B[?25l');

  /// Shows the cursor.
  void show() => Terminal._emit('\x1B[?25h');

  /// Moves the cursor up [n] rows.
  void up([int n = 1]) => Terminal._emit('\x1B[${n}A');

  /// Moves the cursor down [n] rows.
  void down([int n = 1]) => Terminal._emit('\x1B[${n}B');

  /// Moves the cursor right [n] columns.
  void forward([int n = 1]) => Terminal._emit('\x1B[${n}C');

  /// Moves the cursor left [n] columns.
  void back([int n = 1]) => Terminal._emit('\x1B[${n}D');

  /// Homes the cursor to the top-left.
  void home() => Terminal._emit('\x1B[H');

  /// Saves the cursor position.
  void save() => Terminal._emit('\x1B[s');

  /// Restores the saved cursor position.
  void restore() => Terminal._emit('\x1B[u');
}
