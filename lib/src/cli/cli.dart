import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../tui/buffer.dart';

part '../testing/cli_fake.dart';

/// ANSI colour and weight for terminal text: `'Done!'.green`, `'Error!'.red.bold`.
extension AnsiText on String {
  String get _on => '\x1b[0m';

  /// Foreground colours.
  String get black => '\x1b[30m$this$_on';
  String get red => '\x1b[31m$this$_on';
  String get green => '\x1b[32m$this$_on';
  String get yellow => '\x1b[33m$this$_on';
  String get blue => '\x1b[34m$this$_on';
  String get magenta => '\x1b[35m$this$_on';
  String get cyan => '\x1b[36m$this$_on';
  String get white => '\x1b[37m$this$_on';
  String get grey => '\x1b[90m$this$_on';

  /// Weights and decorations.
  String get bold => '\x1b[1m$this$_on';
  String get dim => '\x1b[2m$this$_on';
  String get italic => '\x1b[3m$this$_on';
  String get underline => '\x1b[4m$this$_on';
}

/// Terminal output, prompts and progress, all one word.
///
/// Prompts are async and never block the event loop: while a `Tui` or a pipe
/// is active they keep resolving from queued input.
///
/// ```dart
/// Cli.print('Done!'.green);
/// final name = await Cli.ask('Your name?');
/// final ok   = await Cli.confirm('Proceed?');
/// final bar  = Cli.bar(100);
/// ```
abstract final class Cli {
  static final Queue<String> _pending = Queue<String>();
  static final Queue<Completer<String?>> _waiters = Queue<Completer<String?>>();
  static StreamSubscription<String>? _sub;
  static bool _inputDone = false;

  /// Points the line source at [lines] (`null` restores `stdin`).
  static void _useLines(Stream<String>? lines) {
    _sub?.cancel();
    _sub = null;
    _pending.clear();
    _inputDone = false;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(null);
    }
    if (lines != null) _subscribe(lines);
  }

  static void _subscribe(Stream<String> lines) {
    _sub = lines.listen(
      (line) {
        if (_waiters.isNotEmpty) {
          _waiters.removeFirst().complete(line);
        } else {
          _pending.add(line);
        }
      },
      onDone: () {
        _inputDone = true;
        while (_waiters.isNotEmpty) {
          _waiters.removeFirst().complete(null);
        }
      },
    );
  }

  static void _ensureInput() {
    if (_sub != null) return;
    _subscribe(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  }

  /// Reads one input line without blocking the event loop.
  static Future<String?> _readLine() {
    _ensureInput();
    if (_pending.isNotEmpty) return Future.value(_pending.removeFirst());
    if (_inputDone) return Future.value(null);
    final c = Completer<String?>();
    _waiters.add(c);
    return c.future;
  }

  /// Writes [msg] and a newline.
  static void print(String msg) => stdout.writeln(msg);

  /// Asks a question and answers the line the user types.
  static Future<String> ask(String msg) async {
    stderr.write('$msg ');
    return await _readLine() ?? '';
  }

  /// Asks a yes/no question. Answers `true` for `y`/`yes`.
  static Future<bool> confirm(String msg, {bool or = false}) async {
    stderr.write('$msg [y/n] ');
    final line = (await _readLine())?.trim().toLowerCase();
    if (line == null || line.isEmpty) return or;
    return line == 'y' || line == 'yes';
  }

  /// Asks the user to pick one of [options], by number. Answers the index.
  static Future<int> choose(String msg, List<String> options, {int or = 0}) async {
    stderr.writeln(msg);
    for (var i = 0; i < options.length; i++) {
      stderr.writeln('  ${i + 1}) ${options[i]}');
    }
    stderr.write('Choice [${or + 1}] ');
    final n = int.tryParse((await _readLine())?.trim() ?? '');
    if (n == null || n < 1 || n > options.length) return or;
    return n - 1;
  }

  /// A determinate progress [Bar] of [max] units ([glyphs] picks the set;
  /// [BarGlyphs.ascii] where the terminal cannot draw Unicode).
  static Bar bar(int max, {String? label, String? unit, int size = 24, BarGlyphs glyphs = BarGlyphs.line}) =>
      Bar(max, label: label, unit: unit, size: size, glyphs: glyphs);

  /// Shows [label] while [fn] runs, then clears it.
  static Future<T> spin<T>(String label, Future<T> Function() fn) async {
    final live = stderr.hasTerminal;
    if (live) stderr.write('\r$label ');
    try {
      return await fn();
    } finally {
      if (live) stderr.write('\r\x1b[K');
    }
  }
}

/// The shared live region: every live [Bar] owns one line of it, so multiple
/// bars redraw without corrupting each other. Text on `stdout` is untouched;
/// bars draw on `stderr` only.
final class _LiveRegion {
  static final List<Bar> _bars = [];
  static var _drawn = 0;

  static bool get _live => stderr.hasTerminal;

  static void _attach(Bar bar) {
    if (!bar._live) return;
    _bars.add(bar);
    _draw();
  }

  static void _draw() {
    if (!_live || _bars.isEmpty) return;
    final buf = StringBuffer();
    if (_drawn > 0) buf.write('\x1b[${_drawn}A');
    var i = 0;
    for (final bar in _bars) {
      buf.write('\r\x1b[K${bar._line}');
      if (i < _bars.length - 1 || _drawn <= _bars.length) buf.write('\n');
      i++;
    }
    if (_bars.length < _drawn) {
      // Fewer bars than lines drawn: blank the leftover lines.
      for (var k = _bars.length; k < _drawn; k++) {
        buf.write('\r\x1b[K\n');
      }
      buf.write('\x1b[${_drawn - _bars.length}A');
    }
    stderr.write(buf.toString());
    _drawn = _bars.length;
  }

  static void _detach(Bar bar, String doneLine) {
    if (!bar._live) {
      if (doneLine.isNotEmpty) stderr.writeln(doneLine);
      return;
    }
    _bars.remove(bar);
    if (_drawn > 0) {
      // Rewind over the drawn lines, clear them, print the completion above
      // the remaining bars.
      stderr.write('\x1b[${_drawn}A\r\x1b[K$doneLine\n');
      _drawn = 0;
      _draw();
      if (_bars.isEmpty) _drawn = 0;
    } else if (doneLine.isNotEmpty) {
      stderr.writeln(doneLine);
    }
  }
}

/// A live progress bar; [set] advances it, [close] finishes the line.
///
/// Each bar owns one line of the shared live region, so several bars tick
/// side by side without corruption:
///
/// ```dart
/// final bar = Cli.bar(100, label: 'Downloading');
/// bar.set(50);
/// bar.close();
/// ```
final class Bar {
  final int max;
  final String? label;
  final String? unit;

  /// The bar width in cells.
  final int size;

  /// The glyph set ([BarGlyphs.ascii] where the terminal cannot draw Unicode).
  final BarGlyphs glyphs;
  final Stopwatch _clock = Stopwatch()..start();
  int _value = 0;
  int _drawn = -1;
  bool _live = false;
  bool _done = false;

  Bar(this.max, {this.label, this.unit, this.size = 24, this.glyphs = BarGlyphs.line}) {
    _live = stderr.hasTerminal;
    _LiveRegion._attach(this);
  }

  /// The value shown.
  int get value => _value;

  /// Sets the completed amount to [value] (clamped to `[0, max]`).
  void set(int value) {
    if (_done) return;
    _value = value < 0 ? 0 : (value > max ? max : value);
    _draw();
  }

  /// Adds one unit.
  void tick() => set(_value + 1);

  String get _line {
    final ratio = max <= 0 ? 1.0 : _value / max;
    final bar = glyphs.draw(ratio, size);
    final prefix = label == null ? '' : '$label ';
    final suffix = unit == null ? '' : ' $_value/$max $unit';
    return '$prefix[$bar] ${(ratio * 100).toStringAsFixed(0)}%$suffix';
  }

  void _draw() {
    if (!_live || _done) return;
    if (_value == _drawn) return;
    _drawn = _value;
    _LiveRegion._draw();
  }

  /// Finishes the bar, leaving a completion line.
  void close() {
    if (_done) return;
    _done = true;
    final secs = _clock.elapsedMilliseconds / 1000;
    final prefix = label == null ? '' : '$label ';
    final line = '$prefix done ($_value/$max) in ${secs.toStringAsFixed(1)}s';
    if (_live) {
      _LiveRegion._detach(this, line);
    } else if (label != null) {
      stderr.writeln(line);
    }
  }
}
