/// Prompts and progress, on stderr (`Console.table` prints to stdout: it is
/// the output).
///
/// ```dart
/// if (!await Console.confirm('Delete ${files.length} files?')) return;
/// final me = await Console.spin('Signing in', http.get(api).json());
/// final bar = Console.bar(urls.length, label: 'Pages');
/// await Pool.map(urls, fetch, onDone: bar.tick); // closes at its total
/// ```
///
/// Public surface is exactly: [Console], [Bar], [Speed].
/// - `Console.ask/confirm/choose/key/spin/bar/log/table/notify/copy()` prompt,
///   read keys, show progress, print above it or as columns, or reach the desktop.
/// - [Bar] supports `tick` `update` (plus [Pipe]/[Closeable]).
/// - [Speed] supports `add` `rate` (plus [Pipe]): a rate meter for progress
///   drawn by hand, as in a Tui.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'core.dart';
export 'core.dart';

import 'src/exit.dart' as exit;
import 'src/format.dart' as fmt;
import 'src/keys.dart' as keys;
import 'src/resume.dart' show PassThrough, replays, sizers;
import 'dart:math' as math;
import 'src/terminal.dart' as term;

const _bold = '\x1b[1m';
const _dim = '\x1b[2m';
const _reset = '\x1b[0m';

/// Entry point: prompts and progress, all on stderr.
abstract final class Console {
  /// The live lines (spinners, bars) stacked at the bottom, oldest first.
  /// Only used when animated; otherwise each prints one final line.
  static final _lives = <_Live>[];

  /// Rows of the live block on screen; the cursor rests at the start of
  /// its last row.
  static var _drawn = 0;
  static var _lastPaint = 0;

  /// Open prompts and tables: while any is writing, the live block is
  /// erased and does not repaint, so the 80 ms redraw never lands on a
  /// question or a typed answer.
  static var _parked = 0;

  static void _park() {
    if (_parked++ > 0 || _drawn == 0) return;
    io.stderr.write(_erase());
    _drawn = 0;
  }

  static void _unpark() {
    if (--_parked == 0) _paint(force: true);
  }

  /// Run [body] with the live block parked (see [_park]).
  static Future<T> _parkedFor<T>(Future<T> Function() body) async {
    _park();
    try {
      return await body();
    } finally {
      _unpark();
    }
  }

  /// Spinner frames: one timer for every spinner, running only while one
  /// is live (so it never keeps the script alive).
  static Timer? _ticker;
  static var _frame = 0;

  static void _addLive(_Live live) {
    if (!_animated) return;
    _lives.add(live);
    _paint(force: true);
    _syncTicker();
  }

  /// Remove [live] and print [last] in its place, as a permanent line above
  /// the remaining live lines; a null [last] leaves nothing behind.
  static void _endLive(_Live live, String? last) {
    if (!_lives.remove(live)) {
      if (last != null) io.stderr.writeln(last);
      return;
    }
    io.stderr.write(last == null ? _erase() : '${_erase()}$last\n');
    _drawn = 0;
    _paint(force: true);
    _syncTicker();
  }

  static void _syncTicker() {
    final spinning = _lives.any((l) => l is _Spinner);
    if (spinning && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) {
        _frame++;
        _paint(force: true);
      });
    } else if (!spinning) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Move to the top of the live block and clear it.
  static String _erase() {
    if (_drawn == 0) return '';
    return '\r${_drawn > 1 ? '\x1b[${_drawn - 1}A' : ''}\x1b[J';
  }

  /// Redraw the live block in place (throttled to 80 ms unless [force]).
  /// Every row fits `cols - 1` (a full last column leaves a pending wrap
  /// that breaks the move-up); the block keeps to the screen height, newest
  /// lines first.
  static void _paint({bool force = false}) {
    if (_lives.isEmpty || _parked > 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastPaint < 80) return;
    _lastPaint = now;
    final cols = _columns();
    final room = _lines() - 1 < 1 ? 1 : _lines() - 1;
    final shown = _lives.length > room ? _lives.sublist(_lives.length - room) : _lives;
    final b = StringBuffer('\r');
    if (_drawn > 1) b.write('\x1b[${_drawn - 1}A');
    for (var i = 0; i < shown.length; i++) {
      if (i > 0) b.write('\n');
      b.write('${shown[i]._text(cols)}\x1b[K');
    }
    if (shown.length < _drawn) b.write('\x1b[J');
    _drawn = shown.length;
    io.stderr.write(b);
  }

  /// Color codes when the terminal capabilities say styled: a terminal, or
  /// `FORCE_COLOR=1`/`true`/`always` even when piped; `NO_COLOR` (any value)
  /// always wins. See `TerminalCaps` in `src/terminal.dart`.
  static bool get _styled => term.TerminalCaps.current.styled;

  /// Live redraw (spinners, bars, menu repaints): needs a terminal that
  /// takes escapes. Independent of [_styled]: `NO_COLOR` keeps motion.
  static bool get _animated => term.TerminalCaps.current.animated;

  /// Glyphs, ASCII where the locale is not UTF-8 (`LANG=C`), as in the Tui.
  static bool get _ascii => term.TerminalCaps.current.ascii;
  static String get _okMark => _ascii ? '+' : '✓';
  static String get _failMark => _ascii ? 'x' : '✗';

  static int _columns() {
    try {
      final cols = io.stderr.terminalColumns;
      if (cols > 0) return cols;
    } catch (_) {}
    return 80;
  }

  static int _lines() {
    try {
      final rows = io.stderr.terminalLines;
      if (rows > 0) return rows;
    } catch (_) {}
    return 24;
  }

  /// Read one line. An empty line, a closed stdin and a cancelled Tui
  /// popup give [or] (`''` by default; a non-empty one is shown as `[or]`
  /// after the question). With [secret], echo is turned off (passwords) and
  /// [or] is not shown. With [timeout], no answer in that time also gives
  /// [or]: the reader is stopped, so an unanswered prompt never keeps the
  /// script alive. Use [timeout], never an outer `.timeout()`: that one
  /// leaves the reader waiting, holding the script until stdin closes.
  /// Asynchronous: timers, downloads and bars keep running while one waits.
  /// Ctrl-C restores the terminal and exits with 130. While a state-driven
  /// [Tui.run] is active, shows as a popup (Escape closes it like EOF).
  ///
  /// The cooked, echoed modes this prompt needs are established up front
  /// instead of trusting the inherited ones: a run killed mid-menu can
  /// leave echo off, which makes typing invisible while Enter still
  /// submits. The captured modes are restored afterwards.
  static Future<String> ask(String question, {bool secret = false, String or = '', Duration? timeout}) async {
    final shown = or.isEmpty || secret ? question : '$question [$or]';
    final String? line;
    try {
      line = await _ask(shown, secret: secret, timeout: timeout);
    } on io.StdinException {
      return or;
    } on TimeoutException {
      return or;
    }
    return line == null || line.isEmpty ? or : line;
  }

  /// One prompt and one line: null when the Tui popup was cancelled or
  /// timed out; throws [io.StdinException] on a closed stdin and
  /// [TimeoutException] when [timeout] passes.
  static Future<String?> _ask(String question, {required bool secret, Duration? timeout}) async {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.promptAsk(question, secret: secret, timeout: timeout);
    return _parkedFor(() async {
      io.stderr.writeln(term.safeText(question));
      final modes = term.captureModes();
      term.setLineModes(echo: !secret);
      // Terminal restore on signals (first), via the single owner in
      // src/exit.dart; browsers registered earlier run after us.
      final token = exit.onExit(() => term.restoreModes(modes));
      try {
        return await _readLine(secret: secret, timeout: timeout);
      } finally {
        exit.offExit(token);
        term.restoreModes(modes);
        if (secret) io.stderr.writeln();
      }
    });
  }

  /// Yes/no. Enter, a closed stdin and Escape in a Tui popup give [or]
  /// (the hint reads `[Y/n]` or `[y/N]`). Asks again on anything else. While
  /// a state-driven `Tui.run` is active, shows as a popup.
  static Future<bool> confirm(String question, {bool or = false}) async {
    final hint = or ? '[Y/n]' : '[y/N]';
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      return await bridge.promptConfirm('$question $hint', or) ?? or;
    }
    for (;;) {
      final answer = (await ask('$question $hint')).trim().toLowerCase();
      if (answer == 'y' || answer == 'yes') return true;
      if (answer == 'n' || answer == 'no') return false;
      if (answer.isEmpty) return or;
    }
  }

  /// Pick one of [items], returned as the item itself. [label] names each
  /// item for display (`'$item'` by default); [or] preselects an item (an
  /// [ArgumentError] when it is not one of [items]) and is what Escape, a
  /// closed stdin or a cancelled Tui popup give. Without [or] those give
  /// null.
  ///
  /// On a terminal with working raw mode, `↑`/`↓` arrows (or `w`/`s`, `j`/`k`
  /// where arrows don't reach, e.g. Windows consoles where arrow keys never
  /// arrive at all) move, `1`-`9` jump to that row, and Enter picks, in the
  /// bold with a scrolling window when the items outnumber the
  /// rows. [keys] maps bindings to values that return immediately without
  /// Enter (`{'b escape': Next.back, 'q': Next.quit}` — one typed map for
  /// shortcuts and Escape together); each binding lists space-separated
  /// alternatives (key names as in `Tui`); an unknown name is an
  /// [ArgumentError].
  /// Bindings win over movement keys. An unbound Escape gives [or]. Where raw mode is unavailable (or piped), a numbered list
  /// and a number instead, so the menu always works. Empty [items] is an
  /// [ArgumentError]. While a state-driven `Tui.run` is active, shows as a
  /// popup (the popup speaks labels and the answer is mapped back, so
  /// duplicate labels resolve to their first item; [keys] is the console
  /// menu's own and does not apply there).
  static Future<T?> choose<T>(
    String question,
    List<T> items, {
    String Function(T)? label,
    T? or,
    Map<String, T>? keys,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'must not be empty');
    }
    final labels = [for (final item in items) term.plainLabel(label == null ? '$item' : label(item))];
    var selected = 0;
    if (or != null) {
      final at = items.indexOf(or);
      if (at < 0) {
        throw ArgumentError.value(or, 'or', 'must be one of items');
      }
      selected = at;
    }
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      final picked = await bridge.promptChoose(question, labels, selected);
      if (picked == null) return or;
      final at = labels.indexOf(picked);
      if (at < 0) {
        throw StateError('tui answered with an unknown choice: $picked');
      }
      return items[at];
    }
    final bindings = _canonicalBindings(keys);
    try {
      return await _parkedFor(() async {
        if (!term.stdinTty || !io.stderr.hasTerminal || !term.rawModeSticks()) {
          return await _chooseNumbered(question, items, labels);
        }
        return await _chooseInteractive(question, items, labels, selected, bindings, or);
      });
    } on io.StdinException {
      return or;
    }
  }

  /// Canonicalize each [keys] binding (`'b escape'`, `'ctrl+c'`) up front so
  /// a misspelled key fails fast with [ArgumentError].
  static Map<String, T> _canonicalBindings<T>(Map<String, T>? ks) {
    if (ks == null) return {};
    final out = <String, T>{};
    ks.forEach((binding, value) {
      out[keys.splitBinding(binding).map(keys.canonicalize).join(' ')] = value;
    });
    return out;
  }

  /// Numbered choose: print the list, read a number. Used piped and
  /// wherever raw single-key mode is unavailable. Restores cooked, echoed
  /// input first (best effort), so typing stays visible and line-buffered.
  static Future<T> _chooseNumbered<T>(String question, List<T> items, List<String> labels) async {
    term.setLineModes(); // undo a half-applied raw mode: fallback prompts stay visible
    io.stderr.writeln(term.safeText(question));
    for (var i = 0; i < labels.length; i++) {
      io.stderr.writeln('  ${i + 1}. ${labels[i]}');
    }
    for (;;) {
      final line = await _ask('Enter a number (1-${labels.length}):', secret: false);
      if (line == null) throw const io.StdinException('stdin is closed');
      final n = int.tryParse(line.trim());
      if (n != null && n >= 1 && n <= labels.length) {
        return items[n - 1];
      }
    }
  }

  /// Read a single keypress, without waiting for Enter. Prints [prompt]
  /// first when given. Returns the key: a printable key as itself (`'q'`,
  /// `'Q'`, `'1'` — case is preserved, only the first rune of a burst),
  /// anything else by name (`'enter'`, `'escape'`, `'space'`, `'tab'`,
  /// `'backspace'`, `'up'`, `'down'`, `'left'`, `'right'`, `'home'`,
  /// `'end'`, `'pageup'`, `'pagedown'`, `'delete'`, `'insert'`, `'f1'` …
  /// `'f12'`, `'ctrl+c'` …). A bracketed paste is not a keypress and is
  /// skipped. A closed stdin throws [io.StdinException]. Ctrl-C restores
  /// the terminal and exits with 130.
  ///
  /// ```dart
  /// stderr.writeln('Downloaded. Press q to quit, any other key for more.');
  /// if ((await Console.key()).toLowerCase() == 'q') return;
  /// ```
  ///
  /// Where raw mode is unavailable (or piped), a line is read instead and
  /// its first character counts as the key (an empty line counts as Enter).
  static Future<String> key({String? prompt}) => _parkedFor(() => _key(prompt));

  static Future<String> _key(String? prompt) async {
    if (!term.stdinTty || !io.stderr.hasTerminal || !term.rawModeSticks()) {
      term.setLineModes(); // undo a half-applied raw mode: fallback prompts stay visible
      final line = await _ask(prompt ?? 'Press a key, then Enter:', secret: false);
      if (line == null) throw const io.StdinException('stdin is closed');
      if (line.isEmpty) return 'enter';
      return String.fromCharCode(line.runes.first);
    }
    if (prompt != null) io.stderr.writeln(term.safeText(prompt));
    return _withKeys((found) async {
      for (;;) {
        final event = await found.nextEvent();
        if (event == null) throw const io.StdinException('stdin is closed');
        switch (event) {
          case term.TermKey(:final name):
            return name;
          case term.TermType(text: final text, paste: false):
            if (text.isNotEmpty) {
              return String.fromCharCode(text.runes.first);
            }
          default:
            break; // paste, clicks, focus: not a keypress, keep waiting.
        }
      }
    });
  }

  /// A desktop notification ("done", "needs you"): OSC 9/777 plus a bell,
  /// for long runs a human walked away from. Inside a running `Tui.run` it
  /// goes through the app (silent while the terminal has focus).
  static void notify(String message) {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.notify(message);
    if (_animated) io.stderr.write(term.notifyCodes(message)); // TERM=dumb takes no escapes
  }

  /// Copy [text] to the clipboard (OSC 52; the terminal may ask first or
  /// refuse). Inside a running `Tui.run` it goes through the app.
  static void copy(String text) {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.copy(text);
    if (_animated) io.stderr.write(term.copyCodes(text));
  }

  static final _blank = RegExp('[\n\t]');

  /// Print [rows] to stdout as aligned columns, two spaces apart, sized by
  /// cell width (wide characters count twice); numbers align right. The
  /// [header] is bold on a styled terminal and plain when piped or under
  /// `NO_COLOR`. A null cell prints empty.
  static void table(List<List<Object?>> rows, {List<String>? header}) {
    final cells = [
      for (final row in [?header, ...rows]) [for (final c in row) term.safeText('${c ?? ''}').replaceAll(_blank, ' ')],
    ];
    if (cells.isEmpty) return;
    // Colour codes take no cells.
    int cellWidth(String c) => term.displayWidth(term.unstyled(c));
    final widths = <int>[];
    for (final row in cells) {
      for (final (i, c) in row.indexed) {
        final w = cellWidth(c);
        if (i == widths.length) {
          widths.add(w);
        } else if (w > widths[i]) {
          widths[i] = w;
        }
      }
    }
    final bold = header != null && term.TerminalCaps.forStdout.styled;
    // The live block is on the same terminal: erase it around the rows.
    _park();
    try {
      for (final (r, row) in cells.indexed) {
        final numeric = r == 0 && header != null ? const <Object?>[] : rows[r - (header == null ? 0 : 1)];
        final line = StringBuffer();
        for (final (i, c) in row.indexed) {
          final pad = ' ' * (widths[i] - cellWidth(c));
          final right = i < numeric.length && numeric[i] is num;
          if (i > 0) line.write('  ');
          line.write(right ? '$pad$c' : (i == row.length - 1 ? c : '$c$pad'));
        }
        final text = '$line'.trimRight();
        io.stdout.writeln(bold && r == 0 ? '\x1b[1m$text\x1b[22m' : text);
      }
    } finally {
      _unpark();
    }
  }

  /// Print [line] to stderr above a live spinner or bar, which redraws
  /// beneath it. While a state-driven `Tui.run` is active it goes to the
  /// status row.
  static void log(String line) {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.log(line);
    if (_lives.isEmpty) return io.stderr.writeln(term.safeText(line));
    io.stderr.write('${_erase()}${term.safeText(line)}\n');
    _drawn = 0;
    _paint(force: true);
  }

  /// Animate `⠋ label` until [work] completes, then `✓ label` and return its
  /// value, or `✗ label` and a rethrow. The live line always fits the width (the
  /// width is re-read on each frame, so no resize subscription is needed).
  /// Several spinners and bars stack, one row each; without a terminal
  /// only the final `✓`/`✗` line prints. While a state-driven `Tui.run` is
  /// active, draws in its status row instead (several at once).
  static Future<T> spin<T>(String label, Future<T> work) {
    label = term.plainLabel(label);
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      final id = bridge.spinStarted(label);
      return work.then(
        (v) {
          bridge.spinEnded(id, true);
          return v;
        },
        onError: (Object e, StackTrace st) {
          bridge.spinEnded(id, false);
          throw e;
        },
      );
    }
    if (!_animated) {
      return work.then(
        (v) {
          io.stderr.writeln('$_okMark $label');
          return v;
        },
        onError: (Object e, StackTrace st) {
          io.stderr.writeln('$_failMark $label');
          throw e;
        },
      );
    }
    final live = _Spinner(label);
    _addLive(live);
    return work.then(
      (v) {
        _endLive(live, _Spinner._fit(_okMark, label, _columns()));
        return v;
      },
      onError: (Object e, StackTrace st) {
        _endLive(live, _Spinner._fit(_failMark, label, _columns()));
        throw e;
      },
    );
  }

  /// A progress bar over [total] items or bytes (`null` or 0 means unknown).
  /// As a [Pipe] it counts bytes; with [Bar.tick] it counts items. Stacks
  /// with other live bars and spinners; without a terminal only the final
  /// line prints. While a state-driven `Tui.run` is active, draws in its
  /// status row instead (several at once). With `keep: false` the line
  /// vanishes when the bar finishes (a failed one still prints ✗).
  static Bar bar(int? total, {String? label, bool keep = true}) {
    if (label != null) label = term.plainLabel(label);
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      return Bar._bridged(bridge, bridge.barStarted(total, label), total, label: label);
    }
    final bar = Bar._(total, label: label, keep: keep);
    _addLive(bar);
    return bar;
  }

  /// Leftover bytes after a `\n` in one `_readLine` chunk, for the next call.
  /// Piped `2\n3\n` in one chunk must not lose `3`.
  static List<int>? _linePushback;

  /// The last line ended in a bare `\r`: a `\n` that follows is its CRLF
  /// half, not an empty line.
  static bool _afterCr = false;

  /// Index after the line break at [i] in [bytes]; a CRLF pair counts as one.
  static int _skipBreak(List<int> bytes, int i) {
    var next = i + 1;
    if (bytes[i] == 0x0d && next < bytes.length && bytes[next] == 0x0a) next++;
    _afterCr = bytes[i] == 0x0d && next == i + 1;
    return next;
  }

  /// One cooked line from the shared broadcast stdin, without blocking the
  /// event loop. Handles `\n` and `\r`; in secret mode backspace edits by
  /// grapheme (not byte, so multibyte passwords survive).
  static Future<String> _readLine({required bool secret, Duration? timeout}) async {
    // Piped stdin is read line by line off the event loop while nothing has
    // subscribed to it: a subscription drops lines that arrive between
    // prompts and keeps the script alive until the writer closes the pipe.
    if (!term.stdinTty && term.stdinUnclaimed && (_linePushback?.isEmpty ?? true)) {
      final line = await term.pipedLine(timeout: timeout);
      if (line == null) throw const io.StdinException('stdin is closed');
      return line;
    }
    final result = Completer<String>();
    final buf = <int>[...?_linePushback];
    _linePushback = null;
    if (_afterCr && buf.isNotEmpty) {
      if (buf.first == 0x0a) buf.removeAt(0);
      _afterCr = false;
    }
    // A pushback that already holds a full line resolves immediately.
    final pushNewline = buf.indexWhere((b) => b == 0x0a || b == 0x0d);
    late final StreamSubscription<List<int>> sub;
    Timer? timer;
    void finish([List<int>? rest]) {
      timer?.cancel();
      if (rest != null && rest.isNotEmpty) _linePushback = rest;
      sub.cancel().then(
        (_) {
          if (!result.isCompleted) {
            result.complete(utf8.decode(buf, allowMalformed: true));
          }
        },
        onError: (_) {
          if (!result.isCompleted) {
            result.complete(utf8.decode(buf, allowMalformed: true));
          }
        },
      );
    }

    // Check the pushback first: it may already contain a newline.
    if (pushNewline >= 0) {
      final line = buf.sublist(0, pushNewline);
      final rest = buf.sublist(_skipBreak(buf, pushNewline));
      if (rest.isNotEmpty) _linePushback = rest;
      return Future.value(utf8.decode(line, allowMalformed: true));
    }

    sub = term.sharedStdin().listen(
      (chunk) {
        var i = 0;
        if (_afterCr) {
          _afterCr = false;
          if (chunk.isNotEmpty && chunk[0] == 0x0a) i = 1;
        }
        while (i < chunk.length) {
          final b = chunk[i];
          if (b == 0x0a || b == 0x0d) {
            finish(chunk.sublist(_skipBreak(chunk, i)));
            return;
          }
          if (secret && (b == 0x7f || b == 0x08)) {
            _backspaceGrapheme(buf);
            i++;
            continue;
          }
          buf.add(b);
          i++;
        }
      },
      onError: (Object e) {
        if (!result.isCompleted) {
          result.completeError(e is io.IOException ? e : const io.StdinException('stdin is closed'));
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          // EOF with a partial line still yields it; a truly empty stdin
          // is closed.
          if (buf.isEmpty) {
            result.completeError(const io.StdinException('stdin is closed'));
          } else {
            result.complete(utf8.decode(buf, allowMalformed: true));
          }
        }
      },
      cancelOnError: false,
    );
    if (timeout != null) {
      // No answer in time: stop listening, so the tty reader stops too.
      timer = Timer(timeout, () {
        if (result.isCompleted) return;
        result.completeError(TimeoutException('no answer', timeout));
        unawaited(sub.cancel().then((_) {}, onError: (_) {}));
      });
    }
    return result.future;
  }

  /// Remove one grapheme (base char plus combining marks/ZWJ) from [buf].
  static void _backspaceGrapheme(List<int> buf) {
    if (buf.isEmpty) return;
    final text = utf8.decode(buf, allowMalformed: true);
    final runes = text.runes.toList();
    var end = runes.length;
    // Drop trailing zero-width marks with their base? No: backspace deletes
    // one user-perceived char: the last base plus its trailing marks, or a
    // lone mark if that's all that's left. Walk back over zero-width runes,
    // then one more base rune.
    while (end > 0 && term.isZeroWidth(runes[end - 1])) {
      end--;
    }
    if (end > 0) end--;
    // If we stopped on a base, keep any zero-width marks before it? No:
    // those belong to an earlier base, keep them. Just cut at end.
    // But a dangling ZWJ sequence (man+ZWJ+woman -> backspace leaves ZWJ)?
    // Cutting one grapheme as defined above leaves no dangling ZWJ for the
    // common cases; full grapheme-cluster segmentation is overkill here.
    final kept = String.fromCharCodes(runes.sublist(0, end));
    buf
      ..clear()
      ..addAll(utf8.encode(kept));
  }

  static Future<T?> _chooseInteractive<T>(
    String question,
    List<T> items,
    List<String> labels,
    int selected,
    Map<String, T> bindings,
    T? or,
  ) async {
    var current = selected;
    return _withKeys((found) async {
      var painted = const <int>[];
      io.stderr.writeln(_emph(term.safeText(question)));
      for (;;) {
        painted = _paintChoices(labels, current, painted);
        final keyName = await found.nextKey();
        if (keyName == null) {
          throw const io.StdinException('stdin is closed');
        }
        // Bound keys return at once, no Enter needed. They win over
        // movement keys, so consoles without arrows/escape stay fully
        // operable from letters alone.
        for (final entry in bindings.entries) {
          if (keys.matchesBinding(entry.key, keyName)) {
            io.stderr.writeln();
            return entry.value;
          }
        }
        switch (keyName) {
          case 'up' || 'w' || 'W' || 'k' || 'K':
            current = (current - 1 + labels.length) % labels.length;
          case 'down' || 's' || 'S' || 'j' || 'J':
            current = (current + 1) % labels.length;
          case 'wheelup':
            current = (current - 1 + labels.length) % labels.length;
          case 'wheeldown':
            current = (current + 1) % labels.length;
          case 'home':
            current = 0;
          case 'end':
            current = labels.length - 1;
          case 'pageup':
            current = (current - 10).clamp(0, labels.length - 1);
          case 'pagedown':
            current = (current + 10).clamp(0, labels.length - 1);
          case 'enter':
            io.stderr.writeln();
            return items[current];
          case 'escape':
            // A bound Escape returned through [bindings] above.
            io.stderr.writeln();
            return or;
          default:
            // `1`-`9` jump straight to that row (still needs Enter);
            // anything else is ignored while choosing.
            final n = int.tryParse(keyName);
            if (n != null && n >= 1 && n <= 9 && n <= labels.length) {
              current = n - 1;
            }
            break;
        }
      }
    });
  }

  /// Run [body] with stdin in raw mode (no echo, no line buffering) and the
  /// terminal-restore hook armed; restores the terminal modes afterwards.
  /// Shared by the interactive [choose] menu and [key]. Signals run
  /// through `src/exit.dart`: the restore hook runs first, then browsers.
  static Future<T> _withKeys<T>(Future<T> Function(_KeyReader keys) body) async {
    final modes = term.captureModes();
    term.setRawModes();
    final token = exit.onExit(() => term.restoreModes(modes));
    final found = _KeyReader();
    StreamSubscription<List<int>>? sub;
    try {
      sub = term.sharedStdin().listen(
        found._add,
        onError: (_) => found._close(),
        onDone: found._close,
        cancelOnError: false,
      );
      return await body(found);
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      exit.offExit(token);
      term.restoreModes(modes);
    }
  }

  /// Paint the scrolling window around [selected] plus a dim key-hint row;
  /// each choice cut to fit. The selection draws bold.
  /// Returns the cell width of each row painted, for the next repaint's
  /// move-up.
  static List<int> _paintChoices(List<String> choices, int selected, List<int> painted) {
    final cols = _columns();
    final lines = _lines();
    final rows = lines - 3; // question, hint, and a spare row
    final visible = rows.clamp(1, choices.length);
    var start = selected - visible ~/ 2;
    if (start < 0) start = 0;
    if (start + visible > choices.length) start = choices.length - visible;
    io.stderr.write(_menuUp(painted, cols, lines));
    final width = cols - 2 > 0 ? cols - 2 : 0;
    final widths = <int>[];
    for (var r = 0; r < visible; r++) {
      final current = start + r == selected;
      final choice = term.truncateWidth(choices[start + r], width);
      final row = '${current ? (_ascii ? '>' : '❯') : ' '}${choice.isEmpty ? '' : ' $choice'}';
      widths.add(term.displayWidth(row));
      if (_styled && current) {
        io.stderr.writeln('$_bold$row$_reset\x1b[K');
      } else {
        io.stderr.writeln('$row\x1b[K');
      }
    }
    const hint = 'w/s or ↑↓ move · 1-9 jump · enter select · esc cancel';
    final hintRow = term.truncateWidth(hint, cols > 0 ? cols : hint.length);
    widths.add(term.displayWidth(hintRow));
    if (_styled) {
      io.stderr.writeln('$_dim$hintRow$_reset\x1b[K');
    } else {
      io.stderr.writeln('$hintRow\x1b[K');
    }
    return widths;
  }

  /// Back to the top of the last paint and clear below it. Rows are counted
  /// at the current width: after a resize the terminal reflows a row wider
  /// than the screen onto several, and a shorter window shows fewer rows
  /// (the leftovers are cleared). Capped at the screen height.
  static String _menuUp(List<int> painted, int cols, int lines) {
    if (painted.isEmpty) return '';
    var up = 0;
    for (final w in painted) {
      up += cols > 0 && w > cols ? (w + cols - 1) ~/ cols : 1;
    }
    if (up > lines - 1) up = lines - 1;
    return '${up > 0 ? '\x1b[${up}A' : ''}\r\x1b[J';
  }

  /// Emphasize [text] (bold) when styling is on.
  static String _emph(String text) => _styled ? '$_bold$text$_reset' : text;
}

/// Decoded-key source for [Console._withKeys]: stdin bytes accumulate from
/// the listener, and each wait parks on a completer the listener completes —
/// no polling loop, no per-pump buffer copy. A held run (a lone ESC, a split
/// sequence or character) is resolved by the Tui's own rule,
/// `term.resolveHeld`, so both read a key the same way.
final class _KeyReader {
  final _pending = <int>[];

  /// Decoded events not yet handed out: one read can hold several keys.
  final _events = <term.TermEvent>[];
  Completer<void>? _wake;
  var _done = false;

  void _add(List<int> chunk) {
    _pending.addAll(chunk);
    final w = _wake;
    _wake = null;
    try {
      w?.complete();
    } catch (_) {}
  }

  void _close() {
    _done = true;
    final w = _wake;
    _wake = null;
    try {
      w?.complete();
    } catch (_) {}
  }

  /// The next decoded key name, waiting for bytes as needed: special keys
  /// by name (`'up'`, `'enter'` …), single typed characters as themselves
  /// (`'w'`). Longer typed runs, pastes and mouse/focus reports are not
  /// keys and are skipped. A lone ESC that gains no sequel within
  /// `term.escapeWait` counts as `escape` (it is not held forever, and it
  /// never swallows the next key). `null` when stdin closed with nothing
  /// left to decode.
  Future<String?> nextKey() => _pump(
    (event) => switch (event) {
      term.TermKey(:final name) => name,
      term.TermType(text: final text, paste: false) when text.runes.length == 1 => text,
      _ => null,
    },
  );

  /// The next decoded input event that counts as a keypress (a [term.TermKey]
  /// or non-paste [term.TermType]); mouse, focus and paste events are
  /// skipped. Same waiting semantics as [nextKey].
  Future<term.TermEvent?> nextEvent() => _pump(
    (event) => switch (event) {
      term.TermKey() || term.TermType(paste: false) => event,
      _ => null,
    },
  );

  /// Pull decoded events off [_pending], returning the first one [pick]
  /// accepts. Bytes arrive in chunks, so a trailing incomplete sequence is
  /// held for the next read instead of being emitted as mojibake. `null`
  /// when stdin closed with nothing left to decode.
  Future<T?> _pump<T>(T? Function(term.TermEvent event) pick) async {
    for (;;) {
      while (_events.isNotEmpty) {
        final hit = pick(_events.removeAt(0));
        if (hit != null) return hit;
      }
      if (_pending.isNotEmpty) {
        final parsed = term.decodeKeys(_pending);
        if (parsed.consumed > 0) _pending.removeRange(0, parsed.consumed);
        // Typed runs (keys pressed faster than one read) split into one
        // key per character; pastes stay whole.
        for (final event in parsed.events) {
          if (event is term.TermType && !event.paste && event.text.runes.length > 1) {
            _events.addAll([for (final r in event.text.runes) term.TermType(String.fromCharCode(r))]);
          } else {
            _events.add(event);
          }
        }
        if (_events.isNotEmpty) continue;
        if (_done) {
          // Closed with only skipped or undecodable leftovers: nothing more
          // is coming.
          _pending.clear();
          return null;
        }
        // A held run: wait for its sequel, and on quiet ask the shared
        // resolver what it was (Escape, a dropped split, or keep holding).
        final held = DateTime.now();
        var key = term.resolveHeld(_pending, Duration.zero);
        while (key == null) {
          final waited = DateTime.now().difference(held);
          final left = (waited < term.escapeWait ? term.escapeWait : term.heldWait) - waited;
          // Past both waits only a paste is still held: wait for its end.
          if (!await _quiet(left > Duration.zero ? left : null)) break;
          key = term.resolveHeld(_pending, DateTime.now().difference(held));
        }
        if (key != null) {
          _pending.clear();
          // Surface it as a key event for the caller to take (or skip,
          // when its picker wants nothing of it).
          final hit = key.isEmpty ? null : pick(term.TermKey(key));
          if (hit != null) return hit;
        }
        continue;
      } else if (_done) {
        return null;
      }
      final wake = _wake ??= Completer<void>();
      await wake.future;
    }
  }

  /// True when [quiet] elapsed with no new bytes; false when bytes arrived
  /// or stdin closed first. A null [quiet] waits for bytes only.
  Future<bool> _quiet(Duration? quiet) async {
    if (_done) return false;
    final wake = _wake = Completer<void>();
    if (quiet == null) {
      await wake.future;
      return false;
    }
    var timedOut = false;
    final timer = Timer(quiet, () {
      timedOut = true;
      _wake = null;
      try {
        wake.complete();
      } catch (_) {}
    });
    await wake.future;
    if (!timedOut) timer.cancel();
    return timedOut;
  }
}

/// One row of the live block.
abstract final class _Live {
  /// The row as drawn now, fitted to `cols - 1` cells.
  String _text(int cols);
}

/// A progress bar: a [Pipe] counting the bytes that pass, [Closeable] at end.
///
/// A bar used in a pipe counts bytes and shows sizes and a rate
/// (`12.1/40 MB  1.2 MB/s`, over the last 5 s); used with [tick], it counts
/// items (`12/40  3.1/s`). Once piped, it stays in bytes. A `null` total
/// shows a count and a rate with no bar, so `Console.bar(res.size())`
/// just works. Bytes a resumed download replays from its `.part` fill the
/// bar but not the rate.
final class Bar extends _Live implements Pipe, Closeable, PassThrough {
  Bar._(this._total, {this._label, this._keep = true}) : _bridge = null, _bridgeId = null {
    _hooks();
  }

  Bar._bridged(this._bridge, this._bridgeId, this._total, {this._label}) : _keep = true {
    _hooks();
  }

  void _hooks() {
    sizers[this] = _sized;
    replays[this] = (bytes) => _replay += bytes;
  }

  /// Whether the final line stays when the bar finishes.
  final bool _keep;

  int? _total;
  final String? _label;
  final term.TuiBridge? _bridge;
  final Object? _bridgeId;
  var _done = 0;
  var _closed = false;
  var _piped = false;
  var _replay = 0;
  final _meter = fmt.Meter();

  /// Run clock for the final line's average: started at the first tick, so
  /// setup time never dilutes it.
  final Stopwatch _clock = Stopwatch();

  /// Add [count] (1 by default; non-positive is ignored). A bar counting
  /// items closes itself when it reaches its total, so a loop needs no
  /// `close()`. Piped bytes past the total are kept (the length may be the
  /// compressed size); the bar fills and stays full. Returns this bar.
  Bar tick([int count = 1]) => _advance(count, count);

  /// [count] more done, of which [fresh] count towards the rate (the rest
  /// were replayed from disk).
  Bar _advance(int count, int fresh) {
    if (_closed) return this;
    if (!_clock.isRunning) _clock.start();
    if (count <= 0) return this;
    _done += count;
    _meter.add(fresh);
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      bridge.barTick(id, count, fresh);
    } else {
      _render();
    }
    _closeAtTotal();
    return this;
  }

  void _closeAtTotal() {
    final total = _total;
    if (!_piped && total != null && total > 0 && _done >= total) unawaited(close());
  }

  /// Show [done] of [total], for a total that grows as work is found
  /// (`bar.update(done, queued)`), or that arrives late (a download's
  /// length comes with its headers). Closes at the total like [tick].
  Bar update(int done, int? total) {
    if (total != _total) _setTotal(total);
    return tick(done - _done);
  }

  /// A resumable download piped through this bar reports its length; a total
  /// set by hand wins.
  void _sized(int bytes) {
    if (_total == null) _setTotal(bytes);
  }

  void _setTotal(int? total) {
    _total = total;
    if (_closed) return;
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      bridge.barTotal(id, total);
    } else {
      _render();
    }
  }

  /// Print the final line. A ticked bar does this itself at its total; call
  /// it for bars that may stop early (in `finally`) and for piped ones.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      bridge.barEnded(id, true);
      return;
    }
    if (Console._lives.contains(this)) {
      Console._endLive(this, _keep ? _text(Console._columns()) : null);
    } else if (_keep) {
      final secs = _clock.elapsed.inMilliseconds / 1000;
      final rate = secs > 0 ? _meter.counted / secs : 0.0;
      // No bar without a terminal: the counts, and the rate unless a
      // counted total says it all.
      final total = _total;
      final known = total != null && total > 0;
      final label = _label == null ? '' : '$_label ';
      if (_piped) {
        final counts = known ? '${fmt.fmtSize(_done)}/${fmt.fmtSize(total)}' : fmt.fmtSize(_done);
        io.stderr.writeln('$label$counts  ${fmt.fmtRate(rate)}');
      } else {
        io.stderr.writeln(known ? '$label$_done/$total' : '$label$_done  ${fmt.fmtCount(rate)}/s');
      }
    }
  }

  /// [Pipe.abort]: the run failed (possibly before this stage was ever
  /// read). Print ✗ and release the live line without starting anything.
  /// Covers broadcast sources too. Synchronous: the line is free before
  /// `Reader >` rethrows, so the next bar can start at once.
  @override
  void abort(Object error) {
    if (_closed) return;
    _closed = true;
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      bridge.barEnded(id, false);
      return;
    }
    Console._endLive(this, '${Console._failMark} ${_label ?? ''}'.trimRight());
  }

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    // The replay count belongs to the stream the resume path starts right
    // after announcing it: take it now, before the generator waits.
    final skip = _replay;
    _replay = 0;
    return _pass(input, skip);
  }

  Stream<List<int>> _pass(Stream<List<int>> input, int skip) async* {
    // async* (not a hand-rolled controller) so the stream's backpressure
    // survives: a slow writer pauses this loop at yield, keeping memory at
    // a few chunks whatever the size of the data.
    // A pipeline that fails after this pipe started tears this generator
    // down, running the finally below; a writer-first failure never starts
    // it and is handled by [abort] above (no listen-then-cancel probe).
    _piped = true;
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) bridge.barMode(id, true);
    var ok = false;
    try {
      await for (final chunk in input) {
        final replayed = math.min(skip, chunk.length);
        skip -= replayed;
        _advance(chunk.length, chunk.length - replayed);
        yield chunk;
      }
      await close();
      ok = true;
    } catch (_) {
      abort(0);
      rethrow;
    } finally {
      // A downstream cancel tears the generator down without an error:
      // still print ✗ and release the live line (§2).
      if (!ok && !_closed) abort(0);
    }
  }

  /// Redraw the live block (throttled); the width is re-read on every
  /// redraw, so resizes fit.
  void _render() => Console._paint();

  @override
  String _text(int cols) {
    // The last column stays empty (a full row would autowrap).
    return term.barLine(
      cols - 1,
      label: _label,
      done: _done,
      total: _total,
      bytes: _piped,
      rate: _meter.rate(),
      ascii: Console._ascii,
    );
  }
}

/// A rate meter for progress drawn by hand, as in a Tui: bytes or items
/// per second over the last 5 seconds.
///
/// ```dart
/// final speed = Speed();                          // one for every download
/// await (http.get(url) | speed | Pipe.tap(t.update) > Fs.file(name));
/// r.write('${speed.rate().size()}/s');            // 1.2 MB/s
/// ```
///
/// As a [Pipe] it counts the bytes that pass, and leaves out the ones a
/// resumed download replays from its `.part`; [add] counts by hand.
/// Counts that go back (a negative delta) are ignored. One meter may be
/// shared by many pipelines at once.
final class Speed with Pipe implements PassThrough {
  Speed() {
    replays[this] = (bytes) => _replay += bytes;
  }

  final _meter = fmt.Meter();
  var _replay = 0;

  /// Count [count] more now; zero or negative is ignored. Returns this.
  Speed add(int count) {
    _meter.add(count);
    return this;
  }

  /// Per second over the last 5 s (over the time since the first count,
  /// at least 1 s, when that is shorter); 0 after 5 s with nothing counted.
  double rate() => _meter.rate();

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    var skip = _replay;
    _replay = 0;
    return input.map((chunk) {
      final replayed = math.min(skip, chunk.length);
      skip -= replayed;
      _meter.add(chunk.length - replayed);
      return chunk;
    });
  }
}

final class _Spinner extends _Live {
  _Spinner(this.label);

  final String label;

  @override
  String _text(int cols) {
    final frames = fmt.spinFrames(ascii: Console._ascii);
    return _fit(frames[Console._frame % frames.length], label, cols);
  }

  /// `prefix text` cut to `cols - 1` cells.
  static String _fit(String prefix, String text, int cols) {
    final line = '$prefix $text';
    if (term.displayWidth(line) < cols) return line;
    final room = cols - 1 - term.displayWidth(prefix) - 1;
    if (room <= 0) return prefix;
    return '$prefix ${term.truncateWidth(text, room)}';
  }
}
