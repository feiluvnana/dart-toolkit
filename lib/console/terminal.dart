import 'dart:io';

// ============================================================================
// TERMINAL GEOMETRY & CURSOR
// ============================================================================

/// Terminal display geometry and screen manipulation namespace.
class Terminal {
  int get width {
    try {
      if (stdout.hasTerminal) return stdout.terminalColumns;
    } catch (_) {}
    return 80;
  }

  int get height {
    try {
      if (stdout.hasTerminal) return stdout.terminalLines;
    } catch (_) {}
    return 24;
  }

  void clear() {
    if (stdout.hasTerminal) {
      stdout.write('\x1B[2J\x1B[H');
    }
  }

  void line() {
    if (stdout.hasTerminal) {
      stdout.write('\x1B[2K');
    }
  }

  void bell() => stdout.write('\x07');
}

/// Terminal cursor manipulation namespace.
class Cursor {
  void hide() {
    if (stdout.hasTerminal) stdout.write('\x1B[?25l');
  }

  void show() {
    if (stdout.hasTerminal) stdout.write('\x1B[?25h');
  }

  void up([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}A');
  }

  void down([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}B');
  }

  void forward([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}C');
  }

  void back([int n = 1]) {
    if (stdout.hasTerminal) stdout.write('\x1B[${n}D');
  }

  void home() {
    if (stdout.hasTerminal) stdout.write('\x1B[H');
  }

  void save() {
    if (stdout.hasTerminal) stdout.write('\x1B[s');
  }

  void restore() {
    if (stdout.hasTerminal) stdout.write('\x1B[u');
  }
}
