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
/// - `Console.ask/confirm/choose/spin/bar()` prompt or show progress.
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

  static bool get _animated =>
      io.stderr.hasTerminal && io.Platform.environment['NO_COLOR'] == null;

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
  /// terminal and exits with 130.
  static Future<String> ask(String question, {bool secret = false}) async {
    io.stderr.writeln(question);
    final modes = term.captureModes();
    final sigs = _trapSignals(modes);
    try {
      if (secret) {
        try {
          io.stdin.echoMode = false;
        } catch (_) {}
      }
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
  static Future<bool> confirm(String question) async {
    for (;;) {
      final answer =
          (await ask('$question [y/n]')).trim().toLowerCase();
      if (answer == 'y' || answer == 'yes') return true;
      if (answer == 'n' || answer == 'no' || answer.isEmpty) return false;
    }
  }

  /// Pick one of [choices]. Arrow keys + Enter on a terminal (scrolling when
  /// the choices outnumber the rows); piped, a numbered list and a number.
  /// Escape accepts the current selection. Empty [choices] is an
  /// [ArgumentError].
  static Future<String> choose(
    String question,
    List<String> choices,
  ) async {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    if (!io.stdin.hasTerminal || !io.stderr.hasTerminal) {
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
    return _chooseInteractive(question, choices);
  }

  /// Animate `⠋ label` until [work] completes, then `✓ label` and its result,
  /// or `✗ label` and a rethrow. The live line always fits the width.
  static Future<T> spin<T>(String label, Future<T> Function() work) {
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
  /// As a [Pipe] it counts bytes; with [tick] it counts items.
  static Bar bar(int? total, {String? label}) {
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
      try {
        subs.add(signal.watch().listen((_) {
          term.restoreModes(modes);
          io.exit(code);
        }));
      } catch (_) {}
    }

    trap(io.ProcessSignal.sigint, 130);
    trap(io.ProcessSignal.sigterm, 143);
    try {
      // SIGHUP may not exist on all platforms.
      subs.add(io.ProcessSignal.sighup.watch().listen((_) {
        term.restoreModes(modes);
        io.exit(129);
      }));
    } catch (_) {}
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
  ) async {
    var selected = 0;
    final modes = term.captureModes();
    term.setRawModes();
    final sigs = _trapSignals(modes);
    StreamSubscription<List<int>>? sub;
    final pending = <int>[];
    var painted = 0;
    var stdinDone = false;
    try {
      io.stderr.writeln(question);
      sub = term.sharedStdin().listen(
        pending.addAll,
        onError: (_) {},
        onDone: () => stdinDone = true,
        cancelOnError: false,
      );
      for (;;) {
        painted = _paintChoices(choices, selected, painted);
        final key = await _nextKey(pending, () => stdinDone);
        if (key == null) {
          throw const io.StdinException('stdin is closed');
        }
        switch (key) {
          case 'up':
            selected = (selected - 1 + choices.length) % choices.length;
          case 'down':
            selected = (selected + 1) % choices.length;
          case 'wheelup':
            selected = (selected - 1 + choices.length) % choices.length;
          case 'wheeldown':
            selected = (selected + 1) % choices.length;
          case 'home':
            selected = 0;
          case 'end':
            selected = choices.length - 1;
          case 'enter' || 'escape':
            io.stderr.writeln();
            return choices[selected];
          default:
            // Typed text and anything else: ignore while choosing.
            break;
        }
      }
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

  /// Paint the scrolling window around [selected]; each choice cut to fit.
  /// Returns the rows painted (for the next repaint's move-up).
  static int _paintChoices(
    List<String> choices,
    int selected,
    int painted,
  ) {
    final cols = _columns();
    final rows = _lines() - 2;
    final visible = rows.clamp(1, choices.length);
    var start = selected - visible ~/ 2;
    if (start < 0) start = 0;
    if (start + visible > choices.length) start = choices.length - visible;
    if (painted > 0) io.stderr.write('\x1b[${painted}A');
    final width = cols - 2 > 0 ? cols - 2 : 0;
    var n = 0;
    for (var r = 0; r < visible; r++) {
      final choice = term.truncateWidth(choices[start + r], width);
      io.stderr.writeln(
        '${start + r == selected ? '❯' : ' '}${choice.isEmpty ? '' : ' $choice'}\x1b[K',
      );
      n++;
    }
    return n;
  }

  /// The next decoded key name, waiting for bytes as needed. A lone ESC
  /// that gains no sequel within 150 ms counts as `escape` (it is not held
  /// forever, and it never swallows the next key). `null` when stdin closed
  /// with nothing left to decode.
  static Future<String?> _nextKey(
    List<int> pending,
    bool Function() stdinDone,
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
          switch (event) {
            case term.TermKey(:final name):
              quiet?.cancel();
              return name;
            case term.TermType():
              // Typed or pasted text: ignore while choosing.
              break;
            case term.TermClick():
              // Clicks are for the TUI; ignore while choosing.
              break;
          }
        }
        // Incomplete trailing sequence (or a lone ESC): wait briefly; a
        // real lone Escape resolves on the quiet timer.
        if (pending.isNotEmpty && pending[0] == 0x1b) {
          quiet?.cancel();
          final done = Completer<String?>();
          quiet = Timer(const Duration(milliseconds: 150), () {
            pending.clear();
            if (!done.isCompleted) done.complete('escape');
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
            return await done.future;
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
  Bar._(this._total, {this._label});

  final int? _total;
  final String? _label;
  var _done = 0;
  var _closed = false;
  var _piped = false;
  var _lastDraw = 0;
  var _cols = 0;
  StreamSubscription<io.ProcessSignal>? _sigwinch;
  final _start = DateTime.now();

  /// Add [count] (1 by default), stopping at the total. Returns this bar.
  Bar tick([int count = 1]) {
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
    io.stderr.write('\r$line\x1b[K');
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
    final filled = (frac * width).round().clamp(0, width);
    return '█' * filled + '░' * (width - filled);
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
