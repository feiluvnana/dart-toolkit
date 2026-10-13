/// Prompts and progress. Everything writes to stderr.
///
/// ```dart
/// if (!await Console.confirm('Delete ${files.length} files?')) return;
/// final me = await Console.spin('Signing in', () => Http.get(api).json());
/// final bar = Console.bar(urls.length, label: 'Pages');
/// await Pool.map(urls, fetch, onResult: (_) => bar.tick());
/// await bar.close();
/// ```
///
/// Public surface is exactly: [Console], [Bar].
/// - `Console.ask/confirm/choose/key/spin/bar/clear()` prompt, read keys,
///   or show progress.
/// - [Bar] supports `tick` (plus [Pipe]/[Closeable]).
/// Key decoding, broadcast stdin and terminal modes are shared with `tui`
/// through `src/terminal.dart` (imported relatively, never exported).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'core.dart';
export 'core.dart';

import 'src/terminal.dart' as term;

/// Entry point: prompts and progress, all on stderr.
abstract final class Console {
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

  /// Force styled output on (`true`) or off (`false`). Null (default)
  /// follows the terminal: styled when stderr is a terminal without
  /// `NO_COLOR` set. Set to `true` for terminals misdetected as pipes or
  /// plain output (e.g. a `NO_COLOR` export you don't want to unset
  /// globally); motion (live spinners/bars, menu repaints) still needs a
  /// real terminal, while color codes are emitted wherever styling is on.
  static bool? forceColor;

  /// Color codes when [forceColor] ?? automatic (terminal + no `NO_COLOR`).
  static bool get _styled {
    final force = forceColor;
    if (force != null) return force;
    return io.stderr.hasTerminal &&
        io.Platform.environment['NO_COLOR'] == null;
  }

  /// Live redraw (spinners, bars, menu repaints): needs a terminal to draw
  /// on, plus styling. Implies [_styled].
  static bool get _animated => io.stderr.hasTerminal && _styled;

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

  /// Read one line. With [secret], echo is turned off (passwords).
  /// Asynchronous: timers, downloads and bars keep running while one waits.
  /// A closed stdin throws [io.StdinException]. Ctrl-C restores the
  /// terminal and exits with 130. With [clear], the screen is cleared first.
  /// While a state-driven [Tui.run] is active, shows as a popup.
  ///
  /// The cooked, echoed modes this prompt needs are established up front
  /// instead of trusting the inherited ones: a run killed mid-menu can
  /// leave echo off, which makes typing invisible while Enter still
  /// submits. The captured modes are restored afterwards.
  static Future<String> ask(
    String question, {
    bool secret = false,
    bool clear = false,
  }) async {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.promptAsk(question, secret: secret);
    if (clear) Console.clear();
    io.stderr.writeln(question);
    final modes = term.captureModes();
    try {
      io.stdin.echoMode = !secret;
    } catch (_) {}
    try {
      io.stdin.lineMode = true;
    } catch (_) {}
    final sigs = _trapSignals(modes);
    try {
      return await _readLine(secret: secret);
    } finally {
      for (final s in sigs) {
        try {
          await s.cancel();
        } catch (_) {}
      }
      term.restoreModes(modes);
      if (secret) io.stderr.writeln();
    }
  }

  /// Yes/no. Enter means no. Asks again on anything else.
  /// With [clear], the screen is cleared first. While a state-driven
  /// `Tui.run` is active, shows as a popup.
  static Future<bool> confirm(String question, {bool clear = false}) async {
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.promptConfirm(question);
    for (;;) {
      final answer =
          (await ask('$question [y/n]', clear: clear)).trim().toLowerCase();
      // Only clear before the first prompt; retries keep their context.
      clear = false;
      if (answer == 'y' || answer == 'yes') return true;
      if (answer == 'n' || answer == 'no' || answer.isEmpty) return false;
    }
  }

  /// Pick one of [choices]. On a terminal with working raw mode, `↑`/`↓`
  /// arrows (or `w`/`s`, `j`/`k` where arrows don't reach, e.g. Windows
  /// consoles where arrow keys never arrive at all) move, `1`-`9` jump to
  /// that row, and Enter picks, in accent color with a scrolling window
  /// when the choices outnumber the rows. [shortcuts] adds single keys
  /// that return immediately without Enter (`{'b': 'back'}` — the value
  /// need not be one of [choices], just like [escapeValue]); matched
  /// case-insensitively and taking precedence over movement keys. Where
  /// raw mode is unavailable (or piped), a numbered list and a number
  /// instead, so the menu always works. Escape accepts the current
  /// selection, or returns [escapeValue] when given (handy for
  /// back-navigation). [initial] preselects an entry. With [clear], the
  /// screen is cleared first. Empty [choices] is an [ArgumentError].
  /// While a state-driven `Tui.run` is active, shows as a popup
  /// (Escape cancels with [StdinException]).
  static Future<String> choose(
    String question,
    List<String> choices, {
    bool clear = false,
    int initial = 0,
    String? escapeValue,
    Map<String, String>? shortcuts,
  }) async {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    final bridge = term.TuiBridge.current;
    if (bridge != null) return bridge.promptChoose(question, choices);
    if (clear) Console.clear();
    if (!io.stdin.hasTerminal || !io.stderr.hasTerminal || !_rawKeys()) {
      return _chooseNumbered(question, choices);
    }
    return _chooseInteractive(
      question,
      choices,
      initial,
      escapeValue,
      shortcuts,
    );
  }

  /// Numbered choose: print the list, read a number. Used piped and
  /// wherever raw single-key mode is unavailable. Restores cooked, echoed
  /// input first (best effort), so typing stays visible.
  static Future<String> _chooseNumbered(
    String question,
    List<String> choices,
  ) async {
    _cooked();
    io.stderr.writeln(question);
    for (var i = 0; i < choices.length; i++) {
      io.stderr.writeln('  ${i + 1}. ${choices[i]}');
    }
    for (;;) {
      final line = await ask('Enter a number (1-${choices.length}):');
      final n = int.tryParse(line.trim());
      if (n != null && n >= 1 && n <= choices.length) {
        return choices[n - 1];
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
  /// the terminal and exits with 130. With [clear], the screen is cleared
  /// first.
  ///
  /// ```dart
  /// stderr.writeln('Downloaded. Press q to quit, any other key for more.');
  /// if ((await Console.key()).toLowerCase() == 'q') return;
  /// ```
  ///
  /// Where raw mode is unavailable (or piped), a line is read instead and
  /// its first character counts as the key (an empty line counts as Enter).
  static Future<String> key({String? prompt, bool clear = false}) async {
    if (clear) Console.clear();
    if (!io.stdin.hasTerminal || !io.stderr.hasTerminal || !_rawKeys()) {
      _cooked();
      final line = await ask(prompt ?? 'Press a key, then Enter:');
      if (line.isEmpty) return 'enter';
      return String.fromCharCode(line.runes.first);
    }
    if (prompt != null) io.stderr.writeln(prompt);
    return _withKeys((pending, isDone) async {
      for (;;) {
        final event = await _nextEvent(pending, isDone);
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
  /// so this clears exactly that. No-op without a terminal.
  static void clear() {
    try {
      if (io.stderr.hasTerminal) io.stderr.write('\x1b[2J\x1b[H');
    } catch (_) {}
  }

  /// Animate `⠋ label` until [work] completes, then `✓ label` and its result,
  /// or `✗ label` and a rethrow. The live line always fits the width.
  /// While a state-driven `Tui.run` is active, draws in its status row
  /// instead (several at once).
  static Future<T> spin<T>(String label, Future<T> Function() work) {
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      final id = bridge.spinStarted(label);
      Future<T> fut;
      try {
        fut = work();
      } catch (e, st) {
        bridge.spinEnded(id, false);
        return Future.error(e, st);
      }
      return fut.then((v) {
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

    Future<T> fut;
    try {
      fut = work();
    } catch (e, st) {
      live._free();
      io.stderr.writeln('✗ $label');
      return Future.error(e, st);
    }
    if (!_animated) {
      return fut.then((v) {
        live._free();
        io.stderr.writeln('✓ $label');
        return v;
      }, onError: (Object e, StackTrace st) {
        live._free();
        io.stderr.writeln('✗ $label');
        throw e;
      });
    }
    var i = 0;
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    StreamSubscription<io.ProcessSignal>? winch;
    try {
      winch = io.ProcessSignal.sigwinch.watch().listen((_) {});
    } catch (_) {
      winch = null;
    }
    final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      io.stderr.write('\r${fit(frames[i % frames.length], label)}\x1b[K');
      i++;
    });
    Future<void> cancelWinch() async {
      try {
        await winch?.cancel();
      } catch (_) {}
    }

    return fut.then((v) async {
      timer.cancel();
      await cancelWinch();
      live._free();
      io.stderr.writeln('\r${fit('✓', label)}\x1b[K');
      return v;
    }, onError: (Object e, StackTrace st) async {
      timer.cancel();
      await cancelWinch();
      live._free();
      io.stderr.writeln('\r${fit('✗', label)}\x1b[K');
      throw e;
    });
  }

  /// A progress bar over [total] items or bytes (`null` or 0 means unknown).
  /// As a [Pipe] it counts bytes; with [tick] it counts items. While a
  /// state-driven `Tui.run` is active, draws in its status row instead
  /// (several at once).
  static Bar bar(int? total, {String? label}) {
    final bridge = term.TuiBridge.current;
    if (bridge != null) {
      return Bar._bridged(bridge, bridge.barStarted(total, label), total,
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

  /// Trap signals for a prompt: restore the terminal modes, then exit.
  /// SIGINT exits 130; SIGTERM/SIGHUP restore then exit 143/129.
  /// Returns the subscriptions (cancel them when the prompt ends). While a
  /// SIGINT listener exists Dart does not terminate on SIGINT by itself.
  static List<StreamSubscription<io.ProcessSignal>> _trapSignals(
    term.TermModes modes,
  ) {
    final subs = <StreamSubscription<io.ProcessSignal>>[];
    void trap(io.ProcessSignal signal, int code) {
      if (io.Platform.isWindows && signal != io.ProcessSignal.sigint) return;
      try {
        subs.add(signal.watch().listen((_) {
          term.restoreModes(modes);
          io.exit(code);
        }, onError: (_) {}));
      } catch (_) {}
    }

    trap(io.ProcessSignal.sigint, 130);
    trap(io.ProcessSignal.sigterm, 143);
    if (!io.Platform.isWindows) {
      try {
        // SIGHUP may not exist on all platforms.
        subs.add(io.ProcessSignal.sighup.watch().listen((_) {
          term.restoreModes(modes);
          io.exit(129);
        }, onError: (_) {}));
      } catch (_) {}
    }
    return subs;
  }

  /// Leftover bytes after a `\n` in one `_readLine` chunk, for the next call.
  /// Piped `2\n3\n` in one chunk must not lose `3`.
  static List<int>? _linePushback;

  /// One cooked line from the shared broadcast stdin, without blocking the
  /// event loop. Handles `\n` and `\r`; in secret mode backspace edits by
  /// grapheme (not byte, so multibyte passwords survive).
  static Future<String> _readLine({required bool secret}) {
    final result = Completer<String>();
    final buf = <int>[...? _linePushback];
    _linePushback = null;
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
      final rest = buf.sublist(pushNewline + 1);
      buf
        ..clear()
        ..addAll(line);
      // Defer to let sub be assigned (finish cancels sub).
      sub = term.sharedStdin().listen((_) {}, onDone: () {});
      finish(rest);
      return result.future;
    }

    sub = term.sharedStdin().listen(
      (chunk) {
        var i = 0;
        while (i < chunk.length) {
          final b = chunk[i];
          if (b == 0x0a || b == 0x0d) {
            finish(chunk.sublist(i + 1));
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

  static Future<String> _chooseInteractive(
    String question,
    List<String> choices,
    int initial,
    String? escapeValue,
    Map<String, String>? shortcuts,
  ) async {
    var selected = initial.clamp(0, choices.length - 1);
    return _withKeys((pending, isDone) async {
      var painted = 0;
      io.stderr.writeln(_emph(question));
      for (;;) {
        painted = _paintChoices(choices, selected, painted);
        final keyName = await _nextKey(pending, isDone);
        if (keyName == null) {
          throw const io.StdinException('stdin is closed');
        }
        // Single-key shortcuts return at once, no Enter needed. They win
        // over movement keys, so consoles without arrows/escape stay fully
        // operable from letters alone.
        final shortcut =
            shortcuts?[keyName] ?? shortcuts?[keyName.toLowerCase()];
        if (shortcut != null) {
          io.stderr.writeln();
          return shortcut;
        }
        switch (keyName) {
          case 'up' || 'w' || 'W' || 'k' || 'K':
            selected = (selected - 1 + choices.length) % choices.length;
          case 'down' || 's' || 'S' || 'j' || 'J':
            selected = (selected + 1) % choices.length;
          case 'wheelup':
            selected = (selected - 1 + choices.length) % choices.length;
          case 'wheeldown':
            selected = (selected + 1) % choices.length;
          case 'home':
            selected = 0;
          case 'end':
            selected = choices.length - 1;
          case 'pageup':
            selected = (selected - 10).clamp(0, choices.length - 1);
          case 'pagedown':
            selected = (selected + 10).clamp(0, choices.length - 1);
          case 'enter':
            io.stderr.writeln();
            return choices[selected];
          case 'escape':
            io.stderr.writeln();
            return escapeValue ?? choices[selected];
          default:
            // `1`-`9` jump straight to that row (still needs Enter);
            // anything else is ignored while choosing.
            final n = int.tryParse(keyName);
            if (n != null && n >= 1 && n <= 9 && n <= choices.length) {
              selected = n - 1;
            }
            break;
        }
      }
    });
  }

  /// Run [body] with stdin in raw mode (no echo, no line buffering) and the
  /// Ctrl-C traps armed; restores the terminal modes afterwards. Shared by
  /// the interactive [choose] menu and [key].
  static Future<T> _withKeys<T>(
    Future<T> Function(List<int> pending, bool Function() isDone) body,
  ) async {
    final modes = term.captureModes();
    term.setRawModes();
    final sigs = _trapSignals(modes);
    StreamSubscription<List<int>>? sub;
    final pending = <int>[];
    var stdinDone = false;
    try {
      sub = term.sharedStdin().listen(
        pending.addAll,
        onError: (_) {},
        onDone: () => stdinDone = true,
        cancelOnError: false,
      );
      return await body(pending, () => stdinDone);
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      for (final s in sigs) {
        try {
          await s.cancel();
        } catch (_) {}
      }
      term.restoreModes(modes);
    }
  }

  /// Paint the scrolling window around [selected] plus a dim key-hint row;
  /// each choice cut to fit. The selection draws in the [Bar] accent.
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
          '${current ? '❯' : ' '}${choice.isEmpty ? '' : ' $choice'}';
      if (_styled && current) {
        io.stderr.writeln('$_accent$row$_reset\x1b[K');
      } else {
        io.stderr.writeln('$row\x1b[K');
      }
      n++;
    }
    const hint = 'w/s or ↑↓ move · 1-9 jump · enter select · esc accept';
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

  /// Selection accent: Claude Code orange (#D97757, xterm-256 index 173),
  /// the same accent [Bar] draws its live line in.
  static const _accent = '\x1b[38;5;173m';
  static const _bold = '\x1b[1m';
  static const _dim = '\x1b[2m';
  static const _reset = '\x1b[0m';

  /// The next decoded key name, waiting for bytes as needed: special keys
  /// by name (`'up'`, `'enter'` …), single typed characters as themselves
  /// (`'w'`). Longer typed runs, pastes and mouse/focus reports are not
  /// keys and are skipped. A lone ESC that gains no sequel within 150 ms
  /// counts as `escape` (it is not held forever, and it never swallows the
  /// next key). `null` when stdin closed with nothing left to decode.
  static Future<String?> _nextKey(
    List<int> pending,
    bool Function() stdinDone,
  ) =>
      _pumpKeys<String>(pending, stdinDone, (event) => switch (event) {
            term.TermKey(:final name) => name,
            term.TermType(text: final text, paste: false)
                when text.runes.length == 1 =>
              text,
            _ => null,
          });

  /// The next decoded input event that counts as a keypress (a [term.TermKey]
  /// or non-paste [term.TermType]); mouse, focus and paste events are
  /// skipped. Same waiting semantics as [_nextKey].
  static Future<term.TermEvent?> _nextEvent(
    List<int> pending,
    bool Function() stdinDone,
  ) =>
      _pumpKeys<term.TermEvent>(pending, stdinDone, (event) => switch (event) {
            term.TermKey() || term.TermType(paste: false) => event,
            _ => null,
          });

  /// Pull decoded events off [pending], returning the first one [pick]
  /// accepts. Bytes arrive in chunks, so a trailing incomplete sequence (or
  /// a lone ESC) is held briefly for its sequel instead of being emitted
  /// as mojibake. `null` when stdin closed with nothing left to decode.
  static Future<T?> _pumpKeys<T>(
    List<int> pending,
    bool Function() stdinDone,
    T? Function(term.TermEvent event) pick,
  ) async {
    Timer? quiet;
    for (;;) {
      if (pending.isNotEmpty) {
        final bytes = List<int>.of(pending);
        final parsed = term.decodeKeys(bytes);
        final rest = bytes.sublist(parsed.consumed);
        pending
          ..clear()
          ..addAll(rest);
        for (final event in parsed.events) {
          final hit = pick(event);
          if (hit != null) {
            quiet?.cancel();
            return hit;
          }
        }
        // Incomplete trailing sequence (or a lone ESC): wait briefly; a
        // real lone Escape resolves on the quiet timer.
        if (pending.isNotEmpty && pending[0] == 0x1b) {
          quiet?.cancel();
          final done = Completer<void>();
          quiet = Timer(const Duration(milliseconds: 150), () {
            pending.clear();
            if (!done.isCompleted) done.complete();
          });
          // Either more bytes arrive (outer loop re-pumps first), the
          // timer fires, or stdin closes mid-sequence.
          while (!done.isCompleted) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            if (done.isCompleted) break;
            if (stdinDone()) {
              final q = quiet;
              quiet = null;
              q?.cancel();
              pending.clear();
              return null;
            }
            if (pending.length > 1) break;
          }
          if (done.isCompleted) {
            quiet = null;
            // A lone Escape: surface it as a key event for the caller to
            // take (or skip, when its picker wants nothing of it).
            final esc = pick(term.TermKey('escape'));
            if (esc != null) return esc;
            continue;
          }
          final q = quiet;
          quiet = null;
          q?.cancel();
          continue;
        }
      }
      if (stdinDone()) {
        quiet?.cancel();
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

abstract final class _Live {
  void _free();
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
/// count and a rate with no bar, so `Console.bar(res.size())` just works.
final class Bar extends _Live implements Pipe, Closeable {
  Bar._(this._total, {this._label})
      : _bridge = null,
        _bridgeId = null;

  Bar._bridged(this._bridge, this._bridgeId, this._total, {this._label});

  /// Primary accent for the live line: Claude Code orange (#D97757,
  /// xterm-256 index 173). Shared with the TUI selection accent.
  static const _accent = '\x1b[38;5;173m';
  static const _reset = '\x1b[0m';

  final int? _total;
  final String? _label;
  final term.TuiBridge? _bridge;
  final Object? _bridgeId;
  var _done = 0;
  var _closed = false;
  var _piped = false;
  var _lastDraw = 0;
  var _cols = 0;
  StreamSubscription<io.ProcessSignal>? _sigwinch;
  final _start = DateTime.now();

  /// Add [count] (1 by default), stopping at the total. Returns this bar.
  Bar tick([int count = 1]) {
    final bridge = _bridge;
    final id = _bridgeId;
    if (bridge != null && id != null) {
      if (_closed) return this;
      _done += count;
      final total = _total;
      if (total != null && total > 0 && _done > total) _done = total;
      bridge.barTick(id, count);
      return this;
    }
    if (_closed) return this;
    _done += count;
    final total = _total;
    if (total != null && total > 0 && _done > total) _done = total;
    _render();
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
    try {
      await _sigwinch?.cancel();
    } catch (_) {}
    _sigwinch = null;
    if (Console._animated) {
      _render(force: true);
      io.stderr.writeln();
    } else {
      final label = _label == null ? '' : '$_label ';
      final total = _total;
      final secs = DateTime.now().difference(_start).inMilliseconds / 1000;
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
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    // async* (not a hand-rolled controller) so the stream's backpressure
    // survives: a slow writer pauses this loop at yield, keeping memory at
    // a few chunks whatever the size of the data.
    // A pipeline that fails before this pipe is ever listened to still
    // releases the line: core's writer-error path listens-then-cancels the
    // stream, which starts this generator and tears it down, running the
    // finally below.
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
      await _fail();
      rethrow;
    } finally {
      // A downstream cancel tears the generator down without an error:
      // still print ✗ and release the live line (§2).
      if (!ok && !_closed) await _fail();
    }
  }

  Future<void> _fail() async {
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
    try {
      await _sigwinch?.cancel();
    } catch (_) {}
    _sigwinch = null;
    if (Console._animated) {
      io.stderr.writeln('${'\r✗ ${_label ?? ''}'.trimRight()}\x1b[K');
    } else {
      io.stderr.writeln('✗ ${_label ?? ''}'.trimRight());
    }
    Console._release(this);
  }

  void _render({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastDraw < 80) return;
    _lastDraw = now;
    if (!Console._animated) return;
    _sigwinch ??= _watchWinch();
    // Re-read the width on every redraw (throttled to 80 ms): resizes fit
    // immediately, and SIGWINCH forces a redraw past the throttle.
    _cols = Console._columns();
    final label = _label == null ? '' : '$_label ';
    final line = _piped ? _byteLine(_cols) : _itemLine(_cols, label);
    // The live line draws in the primary accent (Claude orange, xterm 173).
    // Wrapping happens here at the write point so every width fit above
    // keeps measuring the plain line. Only reached when animated, which
    // implies styling is on; piped output stays plain.
    io.stderr.write('\r$_accent$line$_reset\x1b[K');
  }

  StreamSubscription<io.ProcessSignal>? _watchWinch() {
    try {
      return io.ProcessSignal.sigwinch.watch().listen((_) {
        _lastDraw = 0;
        _render();
      });
    } catch (_) {
      return null;
    }
  }

  String _byteLine(int cols) {
    final label = _label == null ? '' : '$_label ';
    final total = _total;
    final secs = DateTime.now().difference(_start).inMilliseconds / 1000;
    final rate = secs > 0 ? _done / secs : 0.0;
    final counts = total != null && total > 0
        ? '${_fmtSize(_done)}/${_fmtSize(total)}'
        : _fmtSize(_done);
    var width = 20;
    while (width > 10) {
      final line = '$label${_bar(width)}  $counts  ${_fmtRate(rate)}';
      if (term.displayWidth(line) <= cols || total == null || total <= 0) {
        break;
      }
      width--;
    }
    if (total != null && total > 0) {
      var line = '$label${_bar(width)}  $counts  ${_fmtRate(rate)}';
      if (term.displayWidth(line) > cols) {
        final room = cols -
            term.displayWidth(
              '${_bar(width)}  $counts  ${_fmtRate(rate)}',
            ) -
            1;
        if (room <= 0) {
          line = '${_bar(width)}  $counts  ${_fmtRate(rate)}';
          if (term.displayWidth(line) > cols) {
            // Even the bar alone doesn't fit: drop to count+rate.
            line = '$counts  ${_fmtRate(rate)}';
          }
        } else {
          line =
              '${term.truncateWidth(label.trimRight(), room)} ${_bar(width)}  $counts  ${_fmtRate(rate)}';
        }
      }
      return line;
    }
    // Unknown total: count and rate, no bar.
    var line = '$label$counts  ${_fmtRate(rate)}';
    if (term.displayWidth(line) > cols) {
      final room =
          cols - term.displayWidth('$counts  ${_fmtRate(rate)}') - 1;
      if (room <= 0) {
        line = '$counts  ${_fmtRate(rate)}';
      } else {
        line = '${term.truncateWidth(label.trimRight(), room)} $counts  ${_fmtRate(rate)}';
      }
    }
    return line;
  }

  String _itemLine(int cols, String label) {
    final total = _total;
    final secs = DateTime.now().difference(_start).inMilliseconds / 1000;
    final rate = secs > 0 ? _done / secs : 0.0;
    final counts =
        total != null && total > 0 ? '$_done/$total' : '$_done';
    final rateText = '${_fmtCount(rate)}/s';
    var width = 20;
    while (width > 10) {
      final line = '$label${_bar(width)}  $counts  $rateText';
      if (term.displayWidth(line) <= cols || total == null || total <= 0) {
        break;
      }
      width--;
    }
    if (total != null && total > 0) {
      var line = '$label${_bar(width)}  $counts  $rateText';
      if (term.displayWidth(line) > cols) {
        final room =
            cols - term.displayWidth('${_bar(width)}  $counts  $rateText') - 1;
        if (room <= 0) {
          line = '${_bar(width)}  $counts  $rateText';
          if (term.displayWidth(line) > cols) line = '$counts  $rateText';
        } else {
          line =
              '${term.truncateWidth(label.trimRight(), room)} ${_bar(width)}  $counts  $rateText';
        }
      }
      return line;
    }
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

  String _bar(int width) {
    final total = _total;
    final frac = total == null || total <= 0
        ? 0.0
        : (_done / total).clamp(0.0, 1.0);
    final cells = frac * width;
    final full = cells.floor();
    final half = cells - full >= 0.5 && full < width;
    const on = '━', mid = '╸', off = '─';
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
