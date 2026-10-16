/// Prompts and progress, on stderr (`Console.table` prints to stdout: it is
/// the output).
///
/// ```dart
/// if (!await Console.confirm('Delete ${files.length} files?', timeout: 30.seconds)) return;
/// final me = await (http.get(api).json() & Console.bar('Signing in'));   // a spinner
/// await (Pool.map(urls, fetch) & Console.bar('Pages'));                 // 12/40  3.1/s
/// await (http.get(iso) & Console.bar('ubuntu.iso') > Fs.file('ubuntu.iso'));
/// ```
///
/// Public surface is exactly: [Console], [Bar].
/// - `Console.ask/confirm/choose/key/bar/log/logged/table/notify/copy/out/input()`
///   prompt, read keys, show progress, print above it or as columns, reach
///   the desktop, or read and write the script's own stdin and stdout.
/// - [Bar] is a [Probe] (attach it with `&`) that supports `tick` `update`
///   (plus [Closeable]).
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
import 'src/logbook.dart';
import 'src/progress.dart' as progress show Tally, Watcher;
import 'src/progress.dart' show watchers;
import 'src/terminal.dart' as term;

const _bold = '\x1b[1m';
const _dim = '\x1b[2m';
const _reset = '\x1b[0m';

/// Entry point: prompts and progress, all on stderr.
abstract final class Console {
  /// The live lines (spinners, bars) stacked at the bottom, oldest first.
  /// Only used when animated; otherwise each prints one final line.
  static final _lives = <_Live>[];

  /// Cell widths of the live block's rows on screen; the cursor rests on
  /// its last row.
  static var _drawn = const <int>[];
  static var _lastPaint = 0;
  static final _csi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

  /// Open prompts and tables: while any is writing, the live block is
  /// erased and does not repaint, so the 80 ms redraw never lands on a
  /// question or a typed answer.
  static var _parked = 0;

  static void _park() {
    if (_parked++ > 0 || _drawn.isEmpty) return;
    io.stderr.write(_erase());
    _drawn = const [];
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
    _drawn = const [];
    _paint(force: true);
    _syncTicker();
  }

  static void _syncTicker() {
    final spinning = _lives.any((l) => l._spinning);
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
    if (_drawn.isEmpty) return '';
    final up = _rowsUp(_columns());
    return '\r${up > 0 ? '\x1b[${up}A' : ''}\x1b[J';
  }

  /// Screen rows from the live block's last row up to its first at [cols]:
  /// after a narrowing resize a reflowing terminal wraps each old row onto
  /// several. Capped at the screen height.
  static int _rowsUp(int cols) {
    var rows = 0;
    for (final w in _drawn) {
      rows += cols > 0 && w > cols ? (w + cols - 1) ~/ cols : 1;
    }
    final most = _lines() - 1;
    return rows - 1 > most ? most : rows - 1;
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
    final up = _rowsUp(cols);
    if (up > 0) b.write('\x1b[${up}A');
    final widths = <int>[];
    for (var i = 0; i < shown.length; i++) {
      if (i > 0) b.write('\n');
      final row = shown[i]._text(cols);
      widths.add(term.displayWidth(row.contains('\x1b') ? row.replaceAll(_csi, '') : row));
      b.write('$row\x1b[K');
    }
    if (shown.length <= up) b.write('\x1b[J');
    _drawn = widths;
    io.stderr.write(b);
  }

  /// Color codes when the terminal capabilities say styled: a terminal, or
  /// `FORCE_COLOR` (any value but empty, `0`, `false`) even when piped; a
  /// non-empty `NO_COLOR` always wins. See `TerminalCaps` in `src/terminal.dart`.
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

  /// Yes/no. Enter, a closed stdin, Escape in a Tui popup and no answer
  /// within [timeout] give [or] (the hint reads `[Y/n]` or `[y/N]`). Asks
  /// again on anything else. While a state-driven `Tui.run` is active,
  /// shows as a popup.
  static Future<bool> confirm(String question, {bool or = false, Duration? timeout}) async {
    final hint = or ? '[Y/n]' : '[y/N]';
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      return await bridge.promptConfirm('$question $hint', or, timeout: timeout) ?? or;
    }
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    for (;;) {
      final left = deadline?.difference(DateTime.now());
      if (left != null && left <= Duration.zero) return or;
      final answer = (await ask('$question $hint', timeout: left)).trim().toLowerCase();
      if (answer == 'y' || answer == 'yes') return true;
      if (answer == 'n' || answer == 'no') return false;
      if (answer.isEmpty) return or;
    }
  }

  /// Pick one of [items], returned as the item itself. [label] names each
  /// item for display, as in `Region.list` (`(s) => s` for strings); [or]
  /// preselects an item (an [ArgumentError] when it is not one of [items])
  /// and is what Escape, a closed stdin, a cancelled Tui popup and no
  /// answer within [timeout] give. Without [or] those give null.
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
    List<T> items,
    String Function(T item) label, {
    T? or,
    Map<String, T>? keys,
    Duration? timeout,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'must not be empty');
    }
    final labels = [for (final item in items) term.plainLabel(label(item))];
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
      final picked = await bridge.promptChoose(question, labels, selected, timeout: timeout);
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
        // TERM=dumb takes no cursor motion: the numbered list there too.
        if (!term.stdinTty || !io.stderr.hasTerminal || !_animated || !term.rawModeSticks()) {
          return await _chooseNumbered(question, items, labels, timeout);
        }
        return await _chooseInteractive(question, items, labels, selected, bindings, or, timeout);
      });
    } on io.StdinException {
      return or;
    } on TimeoutException {
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
  static Future<T> _chooseNumbered<T>(String question, List<T> items, List<String> labels, Duration? timeout) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    term.setLineModes(); // undo a half-applied raw mode: fallback prompts stay visible
    io.stderr.writeln(term.safeText(question));
    for (var i = 0; i < labels.length; i++) {
      io.stderr.writeln('  ${i + 1}. ${labels[i]}');
    }
    for (;;) {
      final left = deadline?.difference(DateTime.now());
      if (left != null && left <= Duration.zero) throw TimeoutException('no answer', timeout);
      final line = await _ask('Enter a number (1-${labels.length}):', secret: false, timeout: left);
      if (line == null) throw const io.StdinException('stdin is closed');
      final n = int.tryParse(line.trim());
      if (n != null && n >= 1 && n <= labels.length) {
        return items[n - 1];
      }
    }
  }

  /// Read a single keypress, without waiting for Enter. Prints [prompt]
  /// first (`''` for none). Returns the key: a printable key as itself (`'q'`,
  /// `'Q'`, `'1'` — case is preserved, only the first rune of a burst),
  /// anything else by name (`'enter'`, `'escape'`, `'space'`, `'tab'`,
  /// `'backspace'`, `'up'`, `'down'`, `'left'`, `'right'`, `'home'`,
  /// `'end'`, `'pageup'`, `'pagedown'`, `'delete'`, `'insert'`, `'f1'` …
  /// `'f12'`, `'ctrl+c'` …). A bracketed paste is not a keypress and is
  /// skipped. A closed stdin and no key within [timeout] give [or], or
  /// without one throw ([io.StdinException], [TimeoutException]). Ctrl-C
  /// restores the terminal and exits with 130.
  ///
  /// ```dart
  /// stderr.writeln('Downloaded. Press q to quit, any other key for more.');
  /// if ((await Console.key('')).toLowerCase() == 'q') return;
  /// ```
  ///
  /// Where raw mode is unavailable (or piped), a line is read instead and
  /// its first character counts as the key (an empty line counts as Enter).
  static Future<String> key(String prompt, {String? or, Duration? timeout}) async {
    try {
      return await _parkedFor(() => _key(prompt, timeout));
    } on io.StdinException {
      if (or != null) return or;
      rethrow;
    } on TimeoutException {
      if (or != null) return or;
      rethrow;
    }
  }

  static Future<String> _key(String prompt, Duration? timeout) async {
    if (!term.stdinTty || !io.stderr.hasTerminal || !term.rawModeSticks()) {
      term.setLineModes(); // undo a half-applied raw mode: fallback prompts stay visible
      final line = await _ask(prompt.isEmpty ? 'Press a key, then Enter:' : prompt, secret: false, timeout: timeout);
      if (line == null) throw const io.StdinException('stdin is closed');
      if (line.isEmpty) return 'enter';
      return String.fromCharCode(line.runes.first);
    }
    if (prompt.isNotEmpty) io.stderr.writeln(term.safeText(prompt));
    return _withKeys(timeout: timeout, (found) async {
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
  /// beneath it; a [failed] one is marked `✗`. Every line is kept, timed,
  /// for [logged]. While a state-driven `Tui.run` is active it goes to the
  /// screen's `Region.log`, or to the status row when the screen draws none.
  static void log(String line, {bool failed = false}) {
    logbook.add((at: DateTime.now(), text: line, failed: failed));
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.log(line, failed: failed);
    final text = term.safeText(failed ? '$_failMark $line' : line);
    if (_lives.isEmpty) return io.stderr.writeln(text);
    io.stderr.write('${_erase()}$text\n');
    _drawn = const [];
    _paint(force: true);
  }

  /// A live progress line labelled [label] (`''` for none): attach it with `&` to a flow,
  /// a [Task] or any future (`work & Console.bar('build')`), and it shows
  /// that run: its count, total and rate, or a spinner until it completes.
  /// Or [Bar.tick] it by hand towards [total]. Stacks with other live bars;
  /// without a terminal only the final line prints. While a state-driven
  /// `Tui.run` is active, draws in its status row instead (several at
  /// once). With `keep: false` the line vanishes when the bar finishes (a
  /// failed one still prints ✗).
  static Bar bar(String label, {int? total, bool keep = true}) {
    final shown = label.isEmpty ? null : term.plainLabel(label);
    final bridge = term.TuiBridge.current;
    if (bridge != null) return Bar._bridged(bridge, shown, total, keep: keep);
    final bar = Bar._(shown, total, keep: keep);
    _addLive(bar);
    return bar;
  }

  /// Every line [log] printed this run, one per line with its time (failed
  /// ones marked `✗`), as a [Reader]: `await (Console.logged() > Fs.file('run.log'))`.
  static Reader logged() => Reader.of(utf8.encode([
    for (final l in logbook) '${l.at.format('yyyy-MM-dd HH:mm:ss')}  ${l.failed ? '$_failMark ' : ''}${l.text}\n',
  ].join()));

  /// Our stdout as a [Writer]: `Shell.read(cmd) > Console.out()` shows a
  /// program's output as it runs. Live bars step aside while it writes.
  static Writer out() => const _Stdout();

  /// Our stdin as a [Reader], so a script can sit in a shell pipeline:
  /// `await (Console.input() | Shell.filter(['sort']) > Console.out())`.
  static Reader input() => Reader.of(const []) | const _Stdin();

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
    Duration? timeout,
  ) async {
    var current = selected;
    return _withKeys(timeout: timeout, (found) async {
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
  /// With [timeout], no key in that time throws [TimeoutException] and
  /// stops reading, so nothing keeps the script alive.
  static Future<T> _withKeys<T>(Future<T> Function(_KeyReader keys) body, {Duration? timeout}) async {
    final modes = term.captureModes();
    term.setRawModes();
    final token = exit.onExit(() => term.restoreModes(modes));
    final found = _KeyReader();
    StreamSubscription<List<int>>? sub;
    var timedOut = false;
    final timer = timeout == null
        ? null
        : Timer(timeout, () {
            timedOut = true;
            found._close();
          });
    try {
      sub = term.sharedStdin().listen(
        found._add,
        onError: (_) => found._close(),
        onDone: found._close,
        cancelOnError: false,
      );
      return await body(found);
    } on io.StdinException {
      if (timedOut) throw TimeoutException('no key', timeout);
      rethrow;
    } finally {
      timer?.cancel();
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
    final hint = _ascii
        ? 'w/s or arrows move - 1-9 jump - enter select - esc cancel'
        : 'w/s or ↑↓ move · 1-9 jump · enter select · esc cancel';
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

  /// Whether the row animates (a spinner frame).
  bool get _spinning => false;
}

/// A live progress line: a [Probe] that shows the run it watches (`&`),
/// or a count you [tick] by hand. [Closeable]: [close] prints its final line.
///
/// Watching a flow it shows sizes and a rate (`12.1/40 MB  1.2 MB/s`), an
/// encode media time (`1:12/4:30  3.4×`), a [Task] its items (`12/40
/// 3.1/s`), and a plain future a spinner until it completes. The total is
/// learned from the run. Bytes a resumed download replays from its `.part`
/// fill the bar but not the rate. A bar closes itself when the runs it
/// watches end (✗ when one failed), and a hand-ticked one at its total.
final class Bar extends _Live with Probe implements Closeable {
  Bar._(this._label, this._handTotal, {this._keep = true}) : _bridge = null {
    watchers[this] = _BarWatch(this);
  }

  Bar._bridged(term.TuiBridge bridge, this._label, this._handTotal, {this._keep = true}) : _bridge = bridge {
    watchers[this] = _BarWatch(this);
    _bridgeId = bridge.barStarted(_state, keep: _keep);
  }

  /// Whether the final line stays when the bar finishes.
  final bool _keep;

  final String? _label;
  final term.TuiBridge? _bridge;
  Object? _bridgeId;
  var _closed = false;

  /// Counted by hand ([tick], [update]); a [total] given to `Console.bar`.
  var _hand = 0;
  int? _handTotal;
  var _handUsed = false;

  /// Summed over the runs this bar watches.
  final _tally = progress.Tally();
  var _watched = false;
  var _reported = false;
  final _window = fmt.Window();

  /// Run clock for the final line's average: started at the first count,
  /// so setup time never dilutes it.
  final Stopwatch _clock = Stopwatch();

  int get _done => _watched && !_handUsed ? _tally.done : _hand;
  int? get _total => _handTotal ?? (_watched && !_handUsed ? _tally.total : null);
  fmt.Unit get _unit => _watched && !_handUsed ? _tally.unit ?? fmt.Unit.items : fmt.Unit.items;

  /// No count yet and no total: a spinner.
  @override
  bool get _spinning => !_reported && !_handUsed && _handTotal == null;

  term.BarState _state() =>
      (label: _label, done: _done, total: _total, unit: _unit, rate: _window.rate(), spinning: _spinning);

  /// Add [count] (1 by default; non-positive is ignored). A bar counting
  /// items closes itself when it reaches its total, so a loop needs no
  /// `close()`. Returns this bar.
  Bar tick([int count = 1]) {
    if (_closed || count <= 0) return this;
    if (!_clock.isRunning) _clock.start();
    _handUsed = true;
    _hand += count;
    _window.add(count);
    _changed();
    final total = _handTotal;
    if (total != null && total > 0 && _hand >= total) unawaited(close());
    return this;
  }

  /// Show [done] of [total] by hand, for a total that grows as work is
  /// found (`bar.update(done, queued)`). Closes at the total like [tick].
  @override
  Bar update(int done, int? total) {
    _handTotal = total;
    _handUsed = true;
    if (done > _hand) return tick(done - _hand);
    _changed();
    return this;
  }

  void _changed() {
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      bridge.barChanged(id);
    } else {
      Console._paint();
    }
  }

  /// Print the final line. A bar does this itself when its runs end or a
  /// ticked count reaches its total; call it for bars that may stop early
  /// (in `finally`).
  @override
  Future<void> close() async => _end(ok: !_tally.failed);

  void _end({required bool ok}) {
    if (_closed) return;
    _closed = true;
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      bridge.barEnded(id, ok);
      return;
    }
    final label = _label ?? '';
    if (!ok) {
      Console._endLive(this, '${Console._failMark} $label'.trimRight());
    } else if (_spinning) {
      Console._endLive(this, _keep ? '${Console._okMark} $label'.trimRight() : null);
    } else if (Console._lives.contains(this)) {
      Console._endLive(this, _keep ? _text(Console._columns()) : null);
    } else if (_keep) {
      // No bar without a terminal: the counts, and the average rate unless
      // a counted total says it all.
      final secs = _clock.elapsed.inMilliseconds / 1000;
      final rate = secs > 0 ? _window.counted / secs : 0.0;
      final total = _total;
      final unit = _unit;
      final counts = fmt.fmtCounts(_done, total, unit);
      final whole = unit == fmt.Unit.items && total != null && total > 0;
      io.stderr.writeln('${label.isEmpty ? '' : '$label '}$counts${whole ? '' : '  ${fmt.fmtPace(rate, unit)}'}');
    }
  }

  @override
  String _text(int cols) {
    if (_spinning) {
      final frames = fmt.spinFrames(ascii: Console._ascii);
      return _fit(frames[Console._frame % frames.length], _label ?? '', cols);
    }
    // The last column stays empty (a full row would autowrap).
    return term.barLine(
      cols - 1,
      label: _label,
      done: _done,
      total: _total,
      unit: _unit,
      rate: _window.rate(),
      ascii: Console._ascii,
    );
  }

  /// `prefix text` cut to `cols - 1` cells.
  static String _fit(String prefix, String text, int cols) {
    final line = '$prefix $text'.trimRight();
    if (term.displayWidth(line) < cols) return line;
    final room = cols - 1 - term.displayWidth(prefix) - 1;
    if (room <= 0) return prefix;
    return '$prefix ${term.truncateWidth(text, room)}';
  }
}

/// What a [Bar] hears from the runs it watches.
final class _BarWatch implements progress.Watcher {
  _BarWatch(this._bar);

  final Bar _bar;

  @override
  void begin(Object run) {
    _bar
      .._watched = true
      .._tally.begin(run);
  }

  @override
  void report(Object run, int done, int? total, fmt.Unit unit, int fresh) {
    final bar = _bar;
    if (bar._closed) return;
    if (!bar._clock.isRunning) bar._clock.start();
    final was = bar._spinning;
    bar._reported = true;
    bar._tally.report(run, done, total, unit);
    bar._window.add(fresh);
    if (was) Console._syncTicker();
    bar._changed();
  }

  @override
  void finish(Object run, Object? error) {
    final bar = _bar;
    bar._tally.finish(run, ok: error == null);
    if (bar._tally.open == 0) bar._end(ok: !bar._tally.failed);
  }
}

/// Our stdout as a [Writer]; the live lines step aside while it writes to
/// the same terminal.
final class _Stdout with Writer {
  const _Stdout();

  @override
  Future<void> consume(Stream<List<int>> input) async {
    final shared = io.stdout.hasTerminal && io.stderr.hasTerminal;
    if (shared) Console._park();
    try {
      await io.stdout.addStream(input);
      await io.stdout.flush();
    } finally {
      if (shared) Console._unpark();
    }
  }
}

/// Our stdin, as the pipe after an empty source: the bytes piped in, until
/// EOF. Built from core's own readers: the first `with Reader` outside core
/// costs a script ~70 ms of startup, which console alone would pay.
final class _Stdin with Pipe {
  const _Stdin();

  @override
  Stream<List<int>> transform(Stream<List<int>> input) => term.stdinBytes();
}
