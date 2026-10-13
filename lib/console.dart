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
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'core.dart';
export 'core.dart';

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

  /// Read one line. With [secret], echo is turned off (passwords).
  /// A closed stdin throws [io.StdinException].
  static Future<String> ask(String question, {bool secret = false}) async {
    io.stderr.writeln(question);
    if (secret) {
      try {
        io.stdin.echoMode = false;
      } catch (_) {}
    }
    String? line;
    try {
      line = io.stdin.readLineSync(
        encoding: utf8,
        retainNewlines: false,
      );
    } finally {
      if (secret) {
        try {
          io.stdin.echoMode = true;
        } catch (_) {}
        io.stderr.writeln();
      }
    }
    if (line == null) throw const io.StdinException('stdin is closed');
    return line;
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

  /// Pick one of [choices]. Arrow keys + Enter on a terminal; piped, a
  /// numbered list and a number. Empty [choices] is an [ArgumentError].
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
  /// or `✗ label` and a rethrow.
  static Future<T> spin<T>(String label, Future<T> Function() work) {
    final live = _Spinner(label);
    _claim(live);
    Future<T> fut;
    try {
      fut = work();
    } catch (e, st) {
      _release(live);
      io.stderr.writeln('✗ $label');
      return Future.error(e, st);
    }
    if (!_animated) {
      return fut.then((v) {
        _release(live);
        io.stderr.writeln('✓ $label');
        return v;
      }, onError: (Object e, StackTrace st) {
        _release(live);
        io.stderr.writeln('✗ $label');
        throw e;
      });
    }
    var i = 0;
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      io.stderr.write('\r${frames[i % frames.length]} $label');
      i++;
    });
    return fut.then((v) {
      timer.cancel();
      _release(live);
      io.stderr.writeln('\r✓ $label');
      return v;
    }, onError: (Object e, StackTrace st) {
      timer.cancel();
      _release(live);
      io.stderr.writeln('\r✗ $label');
      throw e;
    });
  }

  /// A progress bar over [total] items or bytes. A [total] of 0 means unknown.
  static Bar bar(int total, {String? label}) {
    final bar = Bar._(total, label: label);
    _claim(bar);
    return bar;
  }

  static Future<String> _chooseInteractive(
    String question,
    List<String> choices,
  ) async {
    var selected = 0;
    final stdin = io.stdin;
    final oldEcho = stdin.echoMode;
    final oldLine = stdin.lineMode;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      io.stderr.writeln(question);
      while (true) {
        for (var i = 0; i < choices.length; i++) {
          io.stderr.writeln(
            '${i == selected ? '❯' : ' '} ${choices[i]}',
          );
        }
        final byte = stdin.readByteSync();
        if (byte < 0) {
          throw const io.StdinException('stdin is closed');
        }
        if (byte == 27) {
          // Escape sequence: arrows are ESC [ A/B.
          if (stdin.readByteSync() == 91) {
            final dir = stdin.readByteSync();
            if (dir == 65) {
              selected = (selected - 1 + choices.length) % choices.length;
            } else if (dir == 66) {
              selected = (selected + 1) % choices.length;
            }
          }
        } else if (byte == 10 || byte == 13) {
          return choices[selected];
        }
        // Repaint: move up one line per choice.
        io.stderr.write('\x1b[${choices.length}A');
      }
    } finally {
      try {
        stdin.echoMode = oldEcho;
      } catch (_) {}
      try {
        stdin.lineMode = oldLine;
      } catch (_) {}
    }
  }
}

abstract final class _Live {
  void release();
}

/// A progress bar: a [Pipe] counting the bytes that pass, [Closeable] at end.
final class Bar extends _Live implements Pipe, Closeable {
  Bar._(this._total, {this._label}) {
    _render();
  }

  final int _total;
  final String? _label;
  var _done = 0;
  var _closed = false;
  var _lastDraw = 0;
  final _start = DateTime.now();

  /// Add [count] (1 by default), stopping at the total. Returns this bar.
  Bar tick([int count = 1]) {
    if (_closed) return this;
    _done += count;
    if (_total > 0 && _done > _total) _done = _total;
    _render(force: false);
    return this;
  }

  /// Print the final line. Call it in `finally`.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (Console._animated) {
      _render(force: true);
      io.stderr.writeln();
    } else {
      final label = _label == null ? '' : '$_label ';
      if (_total > 0) {
        io.stderr.writeln('$label$_done/$_total');
      } else if (_label != null) {
        io.stderr.writeln('$label$_done');
      } else {
        io.stderr.writeln('$_done');
      }
    }
    release();
  }

  @override
  void release() => Console._release(this);

  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    // async* (not a hand-rolled controller) so the stream's backpressure
    // survives: a slow writer pauses this loop at yield, keeping memory at
    // a few chunks whatever the size of the data.
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
    io.stderr.writeln('\n✗ ${_label ?? ''}'.trimRight());
    Console._release(this);
  }

  void _render({bool force = true}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastDraw < 80) return;
    _lastDraw = now;
    final label = _label == null ? '' : '$_label ';
    if (!Console._animated) return;
    if (_total <= 0) {
      final secs = DateTime.now().difference(_start).inMilliseconds / 1000;
      final rate = secs > 0 ? _done / secs : 0.0;
      io.stderr.write('\r$label$_done ${_fmtRate(rate)}');
      return;
    }
    const width = 20;
    final frac = (_done / _total).clamp(0.0, 1.0);
    final filled = (frac * width).round();
    final bar =
        '█' * filled + '░' * (width - filled);
    final secs = DateTime.now().difference(_start).inMilliseconds / 1000;
    final rate = secs > 0 ? _done / secs : 0.0;
    io.stderr.write(
      '\r$label$bar  $_done/$_total  ${_fmtRate(rate)}',
    );
  }

  static String _fmtRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}

final class _Spinner extends _Live {
  _Spinner(this.label);

  final String label;

  @override
  void release() => Console._release(this);
}
