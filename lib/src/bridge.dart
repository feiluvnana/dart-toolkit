/// Console-in-Tui routing, kept apart from the terminal layer so a light
/// caller (a first-use tool download) can reach the Tui's status row
/// without loading it.
library;

import 'dart:convert';

import 'format.dart' show Unit;

/// What a Console bar shows now, read by the Tui status row on each draw.
typedef BarState = ({String? label, int done, int? total, Unit unit, double rate, bool spinning});

/// Console-in-Tui routing: while a state-driven [Tui.run] is active,
/// `Console.bar` draws in the status row (several at once) and
/// `ask`/`confirm`/`choose`/`pick` open modal popups. The active session publishes
/// itself here; `console.dart` delegates when it is non-null.
abstract class TuiBridge {
  static TuiBridge? current;

  /// A bar started; the row reads [state] whenever it draws. A [keep] bar
  /// shows its ✓/✗ row for a moment once it ends.
  Object barStarted(BarState Function() state, {required bool keep});
  void barChanged(Object id);
  void barEnded(Object id, bool ok);
  void log(String line, {required bool failed});
  void notify(String message);
  void copy(String text);

  /// Prompts resolve null when the popup is cancelled (Escape, Ctrl-C) or
  /// [timeout] passes with no answer.
  Future<String?> promptAsk(String question, {required bool secret, Duration? timeout});
  Future<bool?> promptConfirm(String question, bool or, {Duration? timeout});
  Future<String?> promptChoose(String question, List<String> choices, int initial, {Duration? timeout});

  /// The indexes ticked when Enter closes the checkbox popup.
  Future<List<int>?> promptPick(String question, List<String> choices, Set<int> initial, {Duration? timeout});
}


/// Clipboard copy as OSC 52 (base64, so [text] cannot break out).
String copyCodes(String text) => '\x1b]52;c;${base64.encode(utf8.encode(text))}\x1b\\';
