/// [ConsoleUtils] (exported by `utils`): the clipboard, kept apart from
/// `console` (prompts and progress). Light: it never loads the terminal layer.
library;

import 'dart:io' as io;

import 'bridge.dart';

/// Helpers beside `Console`: [copy] puts text on the clipboard.
abstract final class ConsoleUtils {
  /// Copy [text] to the clipboard (OSC 52 on stderr; the terminal may ask
  /// first or refuse). Inside a running `Tui.run` it goes through the app.
  /// Nothing is written when stderr is not a terminal or `TERM=dumb`.
  static void copy(String text) {
    final bridge = TuiBridge.current;
    if (bridge != null) return bridge.copy(text);
    if (_takesEscapes()) io.stderr.write(copyCodes(text));
  }

  static bool _takesEscapes() {
    try {
      return io.stderr.hasTerminal && (io.Platform.environment['TERM'] ?? '').toLowerCase() != 'dumb';
    } catch (_) {
      return false;
    }
  }
}
