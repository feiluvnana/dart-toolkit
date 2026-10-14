/// Prompts and progress. Everything writes to stderr.
///
/// ```dart
/// if (!await Console.confirm('Delete ${files.length} files?')) return;
/// final me = await Console.spin('Signing in', Http.get(api).json());
/// final bar = Console.bar(urls.length, label: 'Pages');
/// await Pool.map(urls, fetch, onResult: (_) => bar.tick());
/// await bar.close();
/// ```
///
/// Public surface is exactly: [Console], [Bar].
/// - `Console.ask/confirm/choose/key/spin/bar/log/clear()` prompt, read keys,
///   show progress, or print above it.
/// - [Bar] supports `tick` `setTotal` (plus [Pipe]/[Closeable]).
/// Key decoding, broadcast stdin, terminal modes and capabilities are shared
/// with `tui` through `src/terminal.dart` (imported relatively, never
/// exported). Signals go through `src/exit.dart` (the only `ProcessSignal`
/// subscriber in the package); key names through `src/keys.dart`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'core.dart';
export 'core.dart';

import 'src/exit.dart' as exit;
import 'src/keys.dart' as keys;
import 'src/terminal.dart' as term;
import 'src/terminal.dart' show Color;
export 'src/terminal.dart' show Color;

const _bold = '\x1b[1m';
const _dim = '\x1b[2m';
const _reset = '\x1b[0m';

/// Entry point: prompts and progress, all on stderr.
abstract final class Console {
  /// Colour of live lines (spinners, bars) and the `choose` selection;
  /// null (default) stays monochrome. `Color.orange` is the old look.
  static Color? accent;

  static String get _accentOn =>
      _styled && accent != null ? '\x1b[38;5;${accent!.code}m' : '';

  static _Live? _live;

  static void _claim(_Live live) {
    if (_live != null) {
      throw StateError('only one live spinner or bar at a time');
    }
    _live = live;
  }

  static void _release(_Live live) {
    if (identical(_live, live)) _live = null;
  }

  /// Color codes when the terminal capabilities say styled: a terminal, or
  /// `FORCE_COLOR=1`/`true`/`always` even when piped; `NO_COLOR` (any value)
  /// always wins. See `TerminalCaps` in `src/terminal.dart`.
  static bool get _styled => term.TerminalCaps.current.styled;

  /// Live redraw (spinners, bars, menu repaints): needs a terminal to draw
  /// on, plus styling. Implies [_styled].
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

  /// Read one line. An empty line gives [or] when it is set (shown as
  /// `[or]` after the question) and `''` otherwise. A closed stdin gives
  /// [or], or null without it. With [secret], echo is turned off
  /// (passwords) and [or] is not shown.
  /// Asynchronous: timers, downloads and bars keep running while one waits.
  /// Ctrl-C restores the terminal and exits with 130. While a state-driven
  /// [Tui.run] is active, shows as a popup (Escape closes it like EOF).
  ///
  /// The cooked, echoed modes this prompt needs are established up front
  /// instead of trusting the inherited ones: a run killed mid-menu can
  /// leave echo off, which makes typing invisible while Enter still
  /// submits. The captured modes are restored afterwards.
  static Future<String?> ask(
    String question, {
    bool secret = false,
    String? or,
  }) async {
    final shown = or == null || secret ? question : '$question [$or]';
    final String? line;
    try {
      line = await _ask(shown, secret: secret);
    } on io.StdinException {
      return or;
    }
    if (line == null) return or;
    return line.isEmpty && or != null ? or : line;
  }

  /// One prompt and one line: null when the Tui popup was cancelled; throws
  /// [io.StdinException] on a closed stdin.
  static Future<String?> _ask(String question, {required bool secret}) async {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.promptAsk(question, secret: secret);
    io.stderr.writeln(term.safeText(question));
    final modes = term.captureModes();
    try {
      io.stdin.echoMode = !secret;
    } catch (_) {}
    try {
      io.stdin.lineMode = true;
    } catch (_) {}
    // Terminal restore on signals (first), via the single owner in
    // src/exit.dart; browsers registered earlier run after us.
    final token = exit.onExit(() => term.restoreModes(modes));
    try {
      return await _readLine(secret: secret);
    } finally {
      exit.offExit(token);
      term.restoreModes(modes);
      if (secret) io.stderr.writeln();
    }
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
      final answer = ((await ask('$question $hint')) ?? '').trim().toLowerCase();
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
  /// [Console.accent] (bold by default) with a scrolling window when the items outnumber the
  /// rows. [keys] maps bindings to values that return immediately without
  /// Enter (`{'b escape': Next.back, 'q': Next.quit}` — one typed map for
  /// shortcuts and Escape together); each binding holds space-separated
  /// alternatives matched with `keys.matchesBinding` (case-insensitive for
  /// named keys, either case for single characters), canonicalized up front
  /// so an unknown name is an [ArgumentError] here, not a dead menu entry.
  /// Bindings win over movement keys. An unbound Escape gives [or]. Where raw mode is unavailable (or piped), a numbered list
  /// and a number instead, so the menu always works. Empty [items] is an
  /// [ArgumentError]. While a state-driven `Tui.run` is active, shows as a
  /// popup (the popup speaks labels and the answer is mapped back, so
  /// duplicate labels resolve to their first item; [keys] is the console
  /// menu's own and does not apply there).
  ///
  /// To clear first, call [clear] explicitly: there is one way to
  /// clear, not a `clear:` parameter on every prompt.
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
    final labels = [
      for (final item in items) term.plainLabel(label == null ? '$item' : label(item)),
    ];
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
      if (!io.stdin.hasTerminal || !io.stderr.hasTerminal || !_rawKeys()) {
        return await _chooseNumbered(question, items, labels);
      }
      return await _chooseInteractive(question, items, labels, selected, bindings, or);
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
      out[keys.splitBinding(binding).map(keys.canonicalize).join(' ')] =
          value;
    });
    return out;
  }

  /// Numbered choose: print the list, read a number. Used piped and
  /// wherever raw single-key mode is unavailable. Restores cooked, echoed
  /// input first (best effort), so typing stays visible and line-buffered.
  static Future<T> _chooseNumbered<T>(
    String question,
    List<T> items,
    List<String> labels,
  ) async {
    _cooked();
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

  /// Best-effort cooked, echoed input: undoes a half-applied raw mode so
  /// fallback prompts stay visible and line-buffered.
  static void _cooked() {
    try {
      io.stdin.echoMode = true;
    } catch (_) {}
    try {
      io.stdin.lineMode = true;
    } catch (_) {}
  }

  /// True when single keypresses (arrows included) will actually arrive:
  /// raw mode engages and sticks. Restores the terminal modes either way.
  /// A half-applied raw mode (echo off, line buffering still on) is the
  /// worst case — invisible typing that only arrives on Enter — so that
  /// counts as unavailable too.
  static bool _rawKeys() {
    final modes = term.captureModes();
    term.setRawModes();
    try {
      if (io.stdin.lineMode) return false;
    } catch (_) {
      return false;
    } finally {
      term.restoreModes(modes);
    }
    return true;
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
  static Future<String> key({String? prompt}) async {
    if (!io.stdin.hasTerminal || !io.stderr.hasTerminal || !_rawKeys()) {
      _cooked();
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

  /// Clear the terminal screen. Everything [Console] draws goes to stderr,
  /// so this clears exactly that. No-op without a terminal. The one way to
  /// clear: prompts take no `clear:` parameter.
  static void clear() {
    try {
      if (io.stderr.hasTerminal) io.stderr.write('\x1b[2J\x1b[H');
    } catch (_) {}
  }

  /// Print [line] to stderr above a live spinner or bar, which redraws
  /// beneath it. While a state-driven `Tui.run` is active it goes to the
  /// status row.
  static void log(String line) {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.log(line);
    final live = _animated ? _live : null;
    if (live != null) io.stderr.write('\r\x1b[K');
    io.stderr.writeln(term.safeText(line));
    live?._repaint();
  }

  /// Animate `⠋ label` until [work] completes, then `✓ label` and its result,
  /// or `✗ label` and a rethrow. The live line always fits the width (the
  /// width is re-read on each frame, so no resize subscription is needed).
  /// While a state-driven `Tui.run` is active, draws in its status row
  /// instead (several at once).
  static Future<T> spin<T>(String label, Future<T> work) {
    label = term.plainLabel(label);
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      final id = bridge.spinStarted(label);
      return work.then((v) {
        bridge.spinEnded(id, true);
        return v;
      }, onError: (Object e, StackTrace st) {
        bridge.spinEnded(id, false);
        throw e;
      });
    }
    final _Live live = _Spinner(label);
    try {
      _claim(live);
    } catch (_) {
      work.then<void>((_) {}, onError: (_) {});
      rethrow;
    }
    String fit(String prefix, String text) {
      final cols = _columns();
      final line = '$prefix $text';
      if (term.displayWidth(line) <= cols) return line;
      final room = cols - term.displayWidth(prefix) - 1;
      if (room <= 0) return prefix;
      return '$prefix ${term.truncateWidth(text, room)}';
    }

    if (!_animated) {
      return work.then((v) {
        live._free();
        io.stderr.writeln('$_okMark $label');
        return v;
      }, onError: (Object e, StackTrace st) {
        live._free();
        io.stderr.writeln('$_failMark $label');
        throw e;
      });
    }
    var i = 0;
    final frames = _ascii
        ? const ['-', '\\', '|', '/']
        : const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      io.stderr.write('\r${fit(frames[i % frames.length], label)}\x1b[K');
      i++;
    });

    return work.then((v) async {
      timer.cancel();
      live._free();
      io.stderr.writeln('\r${fit(_okMark, label)}\x1b[K');
      return v;
    }, onError: (Object e, StackTrace st) async {
      timer.cancel();
      live._free();
      io.stderr.writeln('\r${fit(_failMark, label)}\x1b[K');
      throw e;
    });
  }

  /// A progress bar over [total] items or bytes (`null` or 0 means unknown).
  /// As a [Pipe] it counts bytes; with [tick] it counts items. While a
  /// state-driven `Tui.run` is active, draws in its status row instead
  /// (several at once).
  static Bar bar(int? total, {String? label}) {
    if (label != null) label = term.plainLabel(label);
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      return Bar._bridged(
          bridge, bridge.barStarted(total, label), total,
          label: label);
    }
    final bar = Bar._(total, label: label);
    // Claim before the first draw, so a second bar throws before it can
    // draw over the live line.
    _claim(bar);
    try {
      bar._render();
    } catch (_) {
      _release(bar);
      rethrow;
    }
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
  static Future<String> _readLine({required bool secret}) {
    // Piped stdin reads synchronously while nothing has subscribed to it:
    // a subscription drops lines that arrive between prompts and keeps the
    // script alive until the writer closes the pipe.
    if (!io.stdin.hasTerminal && term.stdinUnclaimed && (_linePushback?.isEmpty ?? true)) {
      final line = io.stdin.readLineSync(encoding: const Utf8Codec(allowMalformed: true));
      if (line == null) return Future.error(const io.StdinException('stdin is closed'));
      return Future.value(line);
    }
    final result = Completer<String>();
    final buf = <int>[...? _linePushback];
    _linePushback = null;
    if (_afterCr && buf.isNotEmpty) {
      if (buf.first == 0x0a) buf.removeAt(0);
      _afterCr = false;
    }
    // A pushback that already holds a full line resolves immediately.
    final pushNewline = buf.indexWhere((b) => b == 0x0a || b == 0x0d);
    late final StreamSubscription<List<int>> sub;
    void finish([List<int>? rest]) {
      if (rest != null && rest.isNotEmpty) _linePushback = rest;
      sub.cancel().then((_) {
        if (!result.isCompleted) {
          result.complete(utf8.decode(buf, allowMalformed: true));
        }
      }, onError: (_) {
        if (!result.isCompleted) {
          result.complete(utf8.decode(buf, allowMalformed: true));
        }
      });
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
          result.completeError(
            e is io.IOException
                ? e
                : const io.StdinException('stdin is closed'),
          );
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
      var painted = 0;
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
  static Future<T> _withKeys<T>(
    Future<T> Function(_KeyReader keys) body,
  ) async {
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
  /// each choice cut to fit. The selection draws in [accent] (bold by default).
  /// Returns the rows painted (for the next repaint's move-up).
  static int _paintChoices(
    List<String> choices,
    int selected,
    int painted,
  ) {
    final cols = _columns();
    final rows = _lines() - 3; // question, hint, and a spare row
    final visible = rows.clamp(1, choices.length);
    var start = selected - visible ~/ 2;
    if (start < 0) start = 0;
    if (start + visible > choices.length) start = choices.length - visible;
    if (painted > 0) io.stderr.write('\x1b[${painted}A');
    final width = cols - 2 > 0 ? cols - 2 : 0;
    var n = 0;
    for (var r = 0; r < visible; r++) {
      final current = start + r == selected;
      final choice = term.truncateWidth(choices[start + r], width);
      final row =
          '${current ? (_ascii ? '>' : '❯') : ' '}${choice.isEmpty ? '' : ' $choice'}';
      if (_styled && current) {
        io.stderr.writeln(accent == null
            ? '$_bold$row$_reset\x1b[K'
            : '$_accentOn$row$_reset\x1b[K');
      } else {
        io.stderr.writeln('$row\x1b[K');
      }
      n++;
    }
    const hint = 'w/s or ↑↓ move · 1-9 jump · enter select · esc cancel';
    final hintRow = term.truncateWidth(hint, cols > 0 ? cols : hint.length);
    if (_styled) {
      io.stderr.writeln('$_dim$hintRow$_reset\x1b[K');
    } else {
      io.stderr.writeln('$hintRow\x1b[K');
    }
    return n + 1;
  }

  /// Emphasize [text] (bold) when styling is on.
  static String _emph(String text) => _styled ? '$_bold$text$_reset' : text;
}

/// Decoded-key source for [Console._withKeys]: stdin bytes accumulate from
/// the listener, and each wait parks on a completer the listener completes —
/// no polling loop, no per-pump buffer copy. One 150 ms timer resolves a lone
/// ESC; a split multi-byte sequence simply waits for its sequel (or stdin
/// closing) with no timer at all.
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
  /// keys and are skipped. A lone ESC that gains no sequel within 150 ms
  /// counts as `escape` (it is not held forever, and it never swallows the
  /// next key). `null` when stdin closed with nothing left to decode.
  Future<String?> nextKey() => _pump((event) => switch (event) {
        term.TermKey(:final name) => name,
        term.TermType(text: final text, paste: false)
            when text.runes.length == 1 =>
          text,
        _ => null,
      });

  /// The next decoded input event that counts as a keypress (a [term.TermKey]
  /// or non-paste [term.TermType]); mouse, focus and paste events are
  /// skipped. Same waiting semantics as [nextKey].
  Future<term.TermEvent?> nextEvent() =>
      _pump((event) => switch (event) {
        term.TermKey() || term.TermType(paste: false) => event,
        _ => null,
      });

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
        if (parsed.consumed == 0 &&
            _pending.length == 1 &&
            _pending[0] == 0x1b) {
          // A lone ESC: hold briefly for its sequel; on quiet, it is Escape.
          if (await _escQuiet()) {
            _pending.clear();
            // Surface it as a key event for the caller to take (or skip,
            // when its picker wants nothing of it).
            final esc = pick(term.TermKey('escape'));
            if (esc != null) return esc;
          }
          continue;
        }
        // A split sequence or split UTF-8: the sequel arrives via [_add].
      } else if (_done) {
        return null;
      }
      final wake = _wake ??= Completer<void>();
      await wake.future;
    }
  }

  /// True when the quiet period elapsed with no new bytes (a lone Escape);
  /// false when bytes arrived or stdin closed first.
  Future<bool> _escQuiet() async {
    final wake = _wake = Completer<void>();
    var timedOut = false;
    final timer = Timer(const Duration(milliseconds: 150), () {
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

abstract final class _Live {
  void _free();

  /// Redraw the live line (after [Console.log] wrote above it).
  void _repaint() {}
}

/// Format a byte count as humans read it: `0 B`, `200 KB`, `12.1 MB`.
String _fmtSize(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// A progress bar: a [Pipe] counting the bytes that pass, [Closeable] at end.
///
/// A bar used in a pipe counts bytes and shows sizes and a rate
/// (`12.1/40 MB  1.2 MB/s`); used with [tick], it counts items
/// (`12/40  3.1/s`). Once piped, it stays in bytes. A `null` total shows a
/// count and a rate with no bar, so `Console.bar(res.size())`
/// just works.
final class Bar extends _Live implements Pipe, Closeable {
  Bar._(this._total, {this._label})
      : _bridge = null,
        _bridgeId = null;

  Bar._bridged(this._bridge, this._bridgeId, this._total,
      {this._label});

  int? _total;
  final String? _label;
  final term.TuiBridge? _bridge;
  final Object? _bridgeId;
  var _done = 0;
  var _closed = false;
  var _piped = false;
  var _lastDraw = 0;
  var _cols = 0;

  /// Rate clock: started at the first tick, so setup time never dilutes the
  /// displayed speed.
  final Stopwatch _clock = Stopwatch();

  /// Add [count] (1 by default; non-positive is ignored). Counts past the
  /// total are kept (the length may be the compressed size); the bar fills
  /// and stays full. Returns this bar.
  Bar tick([int count = 1]) {
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      if (_closed) return this;
      if (!_clock.isRunning) _clock.start();
      if (count > 0) _done += count;
      bridge.barTick(id, count);
      return this;
    }
    if (_closed) return this;
    if (!_clock.isRunning) _clock.start();
    if (count > 0) _done += count;
    _render();
    return this;
  }

  /// Set the total once it is known (a download's length arrives with its
  /// headers). Returns this bar.
  Bar setTotal(int? total) {
    _total = total;
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      if (!_closed) bridge.barTotal(id, total);
    } else if (!_closed) {
      _render();
    }
    return this;
  }

  /// Print the final line. Call it in `finally`.
  @override
  Future<void> close() async {
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      if (_closed) return;
      _closed = true;
      bridge.barEnded(id, true);
      _free();
      return;
    }
    if (_closed) return;
    _closed = true;
    if (Console._animated) {
      _render(force: true);
      io.stderr.writeln();
    } else {
      final label = _label == null ? '' : '$_label ';
      final total = _total;
      final secs = _clock.elapsed.inMilliseconds / 1000;
      if (_piped) {
        final rate = secs > 0 ? _done / secs : 0.0;
        if (total != null && total > 0) {
          io.stderr.writeln(
              '$label${_fmtSize(_done)}/${_fmtSize(total)}  ${_fmtRate(rate)}');
        } else {
          io.stderr.writeln('$label${_fmtSize(_done)}  ${_fmtRate(rate)}');
        }
      } else if (total != null && total > 0) {
        io.stderr.writeln('$label$_done/$total');
      } else {
        final rate = secs > 0 ? _done / secs : 0.0;
        io.stderr.writeln('$label$_done  ${_fmtCount(rate)}/s');
      }
    }
    _free();
  }

  @override
  void _free() => Console._release(this);

  @override
  void _repaint() => _render(force: true);

  /// [Pipe.abort]: the run failed (possibly before this stage was ever
  /// read). Print ✗ and release the live line without starting anything.
  /// Covers broadcast sources too. Synchronous: the line is free before
  /// [Reader.to] rethrows, so the next bar builds (K2).
  @override
  void abort(Object error) {
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      if (_closed) return;
      _closed = true;
      bridge.barEnded(id, false);
      Console._release(this);
      return;
    }
    if (_closed) return;
    _closed = true;
    if (Console._animated) {
      io.stderr.writeln('${'\r${Console._failMark} ${_label ?? ''}'.trimRight()}\x1b[K');
    } else {
      io.stderr.writeln('${Console._failMark} ${_label ?? ''}'.trimRight());
    }
    Console._release(this);
  }

  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
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
        tick(chunk.length);
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

  void _render({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastDraw < 80) return;
    _lastDraw = now;
    if (!Console._animated) return;
    // Re-read the width on every redraw (throttled to 80 ms): resizes fit.
    _cols = Console._columns();
    final label = _label == null ? '' : '$_label ';
    final line = _line(_cols, label);
    // The live line draws in [Console.accent]. Wrapping happens here at the
    // write point so every width fit above keeps measuring the plain line.
    // Only reached when animated, which implies styling is on; piped output
    // stays plain.
    final on = Console._accentOn;
    // cols - 1: a line that fills the last column leaves a pending wrap, and
    // the next '\r' would return to the wrapped row (stacking lines).
    final fitted = term.truncateWidth(line, _cols - 1);
    io.stderr.write('\r$on$fitted${on.isEmpty ? '' : _reset}\x1b[K');
  }

  /// One live line for byte and item bars alike: `label bar counts rate`.
  /// The bar width falls out of the fixed part (`width = cols − fixed`,
  /// capped at 20) in O(1) instead of probing up to 10 widths per frame.
  String _line(int cols, String label) {
    final total = _total;
    final secs = _clock.elapsed.inMilliseconds / 1000;
    final rate = secs > 0 ? _done / secs : 0.0;
    final String counts;
    final String rateText;
    if (_piped) {
      counts = total != null && total > 0
          ? '${_fmtSize(_done)}/${_fmtSize(total)}'
          : _fmtSize(_done);
      rateText = _fmtRate(rate);
    } else {
      counts = total != null && total > 0 ? '$_done/$total' : '$_done';
      rateText = '${_fmtCount(rate)}/s';
    }
    if (total == null || total <= 0) {
      // Unknown total: count and rate, no bar.
      var line = '$label$counts  $rateText';
      if (term.displayWidth(line) > cols) {
        final room = cols - term.displayWidth('$counts  $rateText') - 1;
        if (room <= 0) {
          line = '$counts  $rateText';
        } else {
          line =
              '${term.truncateWidth(label.trimRight(), room)} $counts  $rateText';
        }
      }
      return line;
    }
    var width = cols - term.displayWidth('$label  $counts  $rateText');
    if (width > 20) width = 20;
    if (width < 0) width = 0;
    final cells = _bar(width);
    var line = '$label$cells  $counts  $rateText';
    if (term.displayWidth(line) > cols) {
      final room = cols - term.displayWidth('$cells  $counts  $rateText') - 1;
      if (room <= 0) {
        line = '$cells  $counts  $rateText';
        if (term.displayWidth(line) > cols) {
          // Even the bar alone doesn't fit: drop to count+rate.
          line = '$counts  $rateText';
        }
      } else {
        line =
            '${term.truncateWidth(label.trimRight(), room)} $cells  $counts  $rateText';
      }
    }
    return line;
  }

  String _bar(int width) {
    final total = _total;
    final frac = total == null || total <= 0
        ? 0.0
        : (_done / total).clamp(0.0, 1.0);
    final cells = frac * width;
    final full = cells.floor();
    final half = cells - full >= 0.5 && full < width;
    final (on, mid, off) = Console._ascii ? ('#', '>', '-') : ('━', '╸', '─');
    return '${on * full}${half ? mid : ''}${off * (width - full - (half ? 1 : 0))}';
  }

  static String _fmtRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  static String _fmtCount(double perSec) {
    if (perSec < 100) return perSec.toStringAsFixed(1);
    return perSec.toStringAsFixed(0);
  }
}

final class _Spinner extends _Live {
  _Spinner(this.label);

  final String label;

  @override
  void _free() => Console._release(this);
}
