import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../tui/buffer.dart';

part '../testing/cli_fake.dart';

/// ANSI colour and weight for terminal text: `'Done!'.green`, `'Error!'.red.bold`.
///
/// Plain text when `NO_COLOR` is set or stdout isn't an ANSI terminal. Nested
/// colours restore the outer colour after an inner reset.
extension AnsiText on String {
  /// Foreground colours.
  String get black => _paint(this, TuiColor.black);
  String get red => _paint(this, TuiColor.red);
  String get green => _paint(this, TuiColor.green);
  String get yellow => _paint(this, TuiColor.yellow);
  String get blue => _paint(this, TuiColor.blue);
  String get magenta => _paint(this, TuiColor.magenta);
  String get cyan => _paint(this, TuiColor.cyan);
  String get white => _paint(this, TuiColor.white);
  String get grey => _paint(this, TuiColor.brightBlack);

  /// Weights and decorations.
  String get bold => _paint(this, null, const CellStyle(bold: true));
  String get dim => _paint(this, null, const CellStyle(dim: true));
  String get italic => _paint(this, null, const CellStyle(italic: true));
  String get underline => _paint(this, null, const CellStyle(underline: true));
}

/// The colour level [AnsiText] and the console paint: `NO_COLOR`/`dumb` or a
/// stdout that isn't an ANSI terminal means none (a [CliFake.capture] level
/// overrides all of it).
ColorLevel _cliLevel() {
  if (Cli._fakeLevel != null) return Cli._fakeLevel!;
  final env = Platform.environment;
  if (env.containsKey('NO_COLOR') || env['TERM'] == 'dumb') return ColorLevel.none;
  if (!stdout.supportsAnsiEscapes) return ColorLevel.none;
  final colorterm = (env['COLORTERM'] ?? '').toLowerCase();
  if (colorterm.contains('truecolor') || colorterm.contains('24bit')) return ColorLevel.truecolor;
  if ((env['TERM'] ?? '').contains('256color')) return ColorLevel.ansi256;
  return ColorLevel.ansi16;
}

/// Whether the terminal draws Unicode (`✓`/`✗`/`❯` and the line glyphs);
/// elsewhere the ASCII words (`ok`/`failed`) and [BarGlyphs.ascii] stand in.
bool _unicode() {
  if (Cli._fakeUnicode != null) return Cli._fakeUnicode!;
  if (Platform.environment['TERM'] == 'dumb') return false;
  return !Platform.isWindows;
}

/// [s] through [fg]/[attrs] at the current level, plain when there is none.
/// An inner reset re-emits the outer style, so nesting keeps the outer colour.
String _paint(String s, TuiColor? fg, [CellStyle attrs = const CellStyle()]) {
  final level = _cliLevel();
  if (level == ColorLevel.none || s.isEmpty) return s;
  final sgr = sgrFor(fg, null, level, attrs);
  if (sgr.isEmpty) return s;
  return '\x1b[${sgr}m${s.replaceAll('\x1b[0m', '\x1b[0m\x1b[${sgr}m')}\x1b[0m';
}

/// The accent: 256-colour 173 (`TuiColor.rgb(217, 119, 87)` on truecolor).
String _accent(String s) => _paint(s, const TuiColor.rgb(217, 119, 87));
String _green(String s) => _paint(s, TuiColor.green);
String _red(String s) => _paint(s, TuiColor.red);
String _dim(String s) => _paint(s, null, const CellStyle(dim: true));

const _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

int _unitScale(num v) {
  var scale = 0;
  var x = v.toDouble();
  while (x >= 1000 && scale < _byteUnits.length - 1) {
    x /= 1000;
    scale++;
  }
  return scale;
}

double _atScale(num v, int scale) {
  var x = v.toDouble();
  for (var i = 0; i < scale; i++) {
    x /= 1000;
  }
  return x;
}

String _fmtScaled(double v, int scale) {
  if (scale == 0) return v.toInt().toString();
  // Three significant figures: `50.0`, `100`, `12.3`.
  if (v >= 100) return v.toStringAsFixed(0);
  if (v >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}

/// `50.0/100 MB`: both ends at the total's scale, the unit named once.
String _humanPair(num value, num max) {
  final scale = _unitScale(max);
  return '${_fmtScaled(_atScale(value, scale), scale)}/${_fmtScaled(_atScale(max, scale), scale)} ${_byteUnits[scale]}';
}

/// `100 MB` for a single byte count.
String _humanSingle(num value) {
  final scale = _unitScale(value);
  return '${_fmtScaled(_atScale(value, scale), scale)} ${_byteUnits[scale]}';
}

/// Terminal output, prompts and progress, all one word.
///
/// Prompts are async and never block the event loop: while a `Tui` or a pipe
/// is active they keep resolving from queued input.
///
/// Prompts, bars and spinners write to stderr; [print] writes to stdout, so
/// `app | jq` gets only data. While bars are live, every one of these goes
/// through the live region (bars clear, the text writes, bars redraw), so a
/// log line never lands under a stale bar.
///
/// ```dart
/// Cli.print('Done!'.green);
/// final name = await Cli.ask('Your name?');
/// final ok   = await Cli.confirm('Proceed?');
/// final bar  = Cli.bar(max: 100);
/// try {
///   bar.set(50);
/// } finally {
///   bar.close();
/// }
/// ```
abstract final class Cli {
  static final Queue<String> _pending = Queue<String>();
  static final Queue<Completer<String?>> _waiters = Queue<Completer<String?>>();
  static StreamSubscription<String>? _sub;
  static bool _inputDone = false;

  // Test hooks, set by CliFake (same library): a captured sink, the live,
  // colour and Unicode overrides. Null means the real stdio.
  static StringSink? _fakeSink;
  static bool? _fakeLive;
  static ColorLevel? _fakeLevel;
  static bool? _fakeUnicode;

  /// Whether bars draw live: a terminal on stderr, without `NO_COLOR`.
  static bool get _liveRegion {
    if (_fakeSink != null) return _fakeLive ?? false;
    final env = Platform.environment;
    if (env.containsKey('NO_COLOR') || env['TERM'] == 'dumb') return false;
    return stderr.hasTerminal;
  }

  static void _resetFake() {
    _fakeSink = null;
    _fakeLive = null;
    _fakeLevel = null;
    _fakeUnicode = null;
    _LiveRegion._reset();
    _useLines(null);
  }

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

  /// Prompts with [text] (no newline) and reads one line, the bars clearing
  /// while the answer is awaited.
  static Future<String?> _prompt(String text) async {
    if (_fakeSink != null) {
      _fakeSink!.write(text);
      return _readLine();
    }
    _LiveRegion._clearBars();
    stderr.write(text);
    try {
      return await _readLine();
    } finally {
      _LiveRegion._draw();
    }
  }

  /// Writes [msg] and a newline to stdout (through the live region: live
  /// bars clear first and redraw after, so the line never lands under one).
  static void print(String msg) {
    if (_fakeSink != null) {
      _LiveRegion._printFake(msg);
      return;
    }
    _LiveRegion._writeThrough(() => stdout.writeln(msg));
  }

  /// Asks a question and answers the line the user types.
  static Future<String> ask(String msg) async => await _prompt('${_accent('?')} $msg ') ?? '';

  /// Asks a yes/no question, showing the default (`(y/N)` or `(Y/n)`).
  /// Answers `true` for `y`/`yes`, `false` for `n`/`no`, else the default.
  static Future<bool> confirm(String msg, {bool or = false}) async {
    final line = (await _prompt('${_accent('?')} $msg ${_dim(or ? '(Y/n)' : '(y/N)')} '))?.trim().toLowerCase();
    if (line == null || line.isEmpty) return or;
    if (line == 'y' || line == 'yes') return true;
    if (line == 'n' || line == 'no') return false;
    return or;
  }

  /// Asks the user to pick one of [options], answering the index ([or] is the
  /// default). On a terminal the arrow keys move `❯` and Enter picks;
  /// piped, a numbered list is read instead: invalid input re-asks once,
  /// then the default answers.
  static Future<int> choose(String msg, List<String> options, {int or = 0}) async {
    if (options.isEmpty) throw ArgumentError.value(options, 'options', 'Invalid options: none');
    if (or < 0 || or >= options.length) throw ArgumentError.value(or, 'or', 'Invalid default: out of range');
    if (_liveRegion && (_fakeSink != null || stdin.hasTerminal)) {
      return _chooseInteractive(msg, options, or);
    }
    return _chooseNumbered(msg, options, or);
  }

  /// Answers the chosen index, or `null` when the input was invalid (the
  /// caller re-asks once). An empty answer takes the default at once.
  static Future<int?> _readChoice(int count, int or) async {
    final line = await _readLine();
    if (line == null || line.trim().isEmpty) return or;
    final n = int.tryParse(line.trim());
    if (n == null || n < 1 || n > count) return null;
    return n - 1;
  }

  static Future<int> _chooseNumbered(String msg, List<String> options, int or) async {
    final head = StringBuffer('$msg\n');
    for (var i = 0; i < options.length; i++) {
      head.writeln('  ${i + 1}) ${options[i]}');
    }
    head.write('Choice [${or + 1}] ');
    if (_fakeSink != null) {
      _fakeSink!.write(head.toString());
      final first = await _readChoice(options.length, or);
      if (first != null) return first;
      _fakeSink!.write('Choice [${or + 1}] ');
      return await _readChoice(options.length, or) ?? or;
    }
    _LiveRegion._clearBars();
    stderr.write(head.toString());
    try {
      final first = await _readChoice(options.length, or);
      if (first != null) return first;
      stderr.write('Choice [${or + 1}] ');
      return await _readChoice(options.length, or) ?? or;
    } finally {
      _LiveRegion._draw();
    }
  }

  static Future<int> _chooseInteractive(String msg, List<String> options, int or) async {
    if (_fakeSink != null) return _chooseFakeKeys(msg, options, or);
    _LiveRegion._clearBars();
    var selected = or;
    void render() {
      final buf = StringBuffer('${_accent('?')} $msg\n');
      final marker = _unicode() ? '❯' : '>';
      for (var i = 0; i < options.length; i++) {
        buf.writeln(i == selected ? '  ${_accent(marker)} ${options[i]}' : '    ${options[i]}');
      }
      stderr.write(buf.toString());
    }

    render();
    _sub?.cancel();
    _sub = null;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } catch (_) {
      // Raw stdin refused us: fall back to the numbered read.
      try {
        return await _chooseNumbered(msg, options, or);
      } finally {
        _LiveRegion._draw();
      }
    }
    try {
      final pending = <int>[];
      await for (final chunk in stdin) {
        for (final byte in chunk) {
          final key = _pushKey(pending, byte);
          if (key == null) continue;
          if (key == 'enter') return selected;
          if (key == 'up') selected = (selected - 1).clamp(0, options.length - 1);
          if (key == 'down') selected = (selected + 1).clamp(0, options.length - 1);
          stderr.write('\x1b[${options.length + 1}A');
          render();
        }
      }
      return selected;
    } finally {
      try {
        stdin.echoMode = true;
        stdin.lineMode = true;
      } catch (_) {
        // The terminal is going away; the modes die with it.
      }
      _LiveRegion._draw();
    }
  }

  /// One raw-mode key byte through the escape parser: `up`, `down`, `enter`,
  /// or `null` (more bytes needed, or a key we ignore).
  static String? _pushKey(List<int> pending, int byte) {
    if (pending.isEmpty) {
      if (byte == 27) {
        pending.add(byte);
        return null;
      }
      if (byte == 13 || byte == 10) return 'enter';
      return null;
    }
    pending.add(byte);
    if (pending.length == 2) {
      if (pending[1] != 91) pending.clear();
      return null;
    }
    pending.clear();
    if (byte == 65) return 'up';
    if (byte == 66) return 'down';
    return null;
  }

  /// The interactive menu against faked input: each queued line is a key
  /// (`\x1b[A` up, `\x1b[B` down, empty for Enter).
  static Future<int> _chooseFakeKeys(String msg, List<String> options, int or) async {
    var selected = or;
    void render() {
      final buf = StringBuffer('${_accent('?')} $msg\n');
      final marker = _unicode() ? '❯' : '>';
      for (var i = 0; i < options.length; i++) {
        buf.writeln(i == selected ? '  ${_accent(marker)} ${options[i]}' : '    ${options[i]}');
      }
      _fakeSink!.write(buf.toString());
    }

    render();
    while (true) {
      final line = await _readLine();
      if (line == null || line.isEmpty || line == '\r' || line == '\n' || line == 'enter') return selected;
      if (line == '\x1b[A' || line == 'up') {
        selected = (selected - 1).clamp(0, options.length - 1);
        render();
      } else if (line == '\x1b[B' || line == 'down') {
        selected = (selected + 1).clamp(0, options.length - 1);
        render();
      }
    }
  }

  /// A progress [Bar] of [max] units, 0 while unknown: `set(done, total)` learns it,
  /// so `onProgress: Cli.bar(label: 'Saving').set` draws any job ([glyphs] picks the set;
  /// [BarGlyphs.ascii] where the terminal cannot draw Unicode). With `unit: 'B'` the
  /// values read human (`50.0/100 MB`, with a speed and an ETA); with other units they
  /// read raw (`50/100 items`). The bar closes itself on reaching [max].
  ///
  /// Close a bar that may stop short in a `finally`: the live region keeps drawing each
  /// bar still open, so a bar an exception leaves live goes stale on screen.
  static Bar bar({int max = 0, String? label, String? unit, int size = 24, BarGlyphs glyphs = BarGlyphs.line}) =>
      Bar(max: max, label: label, unit: unit, size: size, glyphs: glyphs);

  /// [items], ticking a [Bar] of their count as the loop moves past each; the bar
  /// closes when the loop ends: `for (final url in Cli.each(urls, label: 'Pages'))`.
  static Iterable<T> each<T>(Iterable<T> items, {String? label, String? unit}) sync* {
    final list = items.toList();
    final bar = Bar(max: list.length, label: label, unit: unit);
    try {
      for (final item in list) {
        yield item;
        bar.tick();
      }
    } finally {
      bar.close();
    }
  }

  /// Shows [label] with [SpinGlyphs.dots] (80 ms) on stderr while [fn] runs,
  /// ending `✓ label 1.2s` — or `✗ label failed: <error>`, rethrowing.
  /// Without a live region there is no animation, only the end line.
  static Future<T> spin<T>(String label, Future<T> Function() fn) async {
    final uni = _unicode();
    final tickMark = uni ? '✓' : 'ok';
    final crossMark = uni ? '✗' : 'failed';
    if (!_liveRegion || _fakeSink != null) {
      final sw = Stopwatch()..start();
      try {
        final value = await fn();
        _LiveRegion._finish('${_green(tickMark)} $label ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
        return value;
      } catch (e) {
        _LiveRegion._finish('${_red(crossMark)} $label ${_red('failed: $e')}');
        rethrow;
      }
    }
    _LiveRegion._clearBars();
    final sw = Stopwatch()..start();
    final frames = uni ? SpinGlyphs.dots : SpinGlyphs.ascii;
    void paint() => stderr.write('\r\x1b[K${_accent(frames.frame())} $label ');
    paint();
    final timer = Timer.periodic(frames.every, (_) => paint());
    try {
      final value = await fn();
      timer.cancel();
      stderr.write('\r\x1b[K');
      stderr.writeln('${_green(tickMark)} $label ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      _LiveRegion._draw();
      return value;
    } catch (e) {
      timer.cancel();
      stderr.write('\r\x1b[K');
      stderr.writeln('${_red(crossMark)} $label ${_red('failed: $e')}');
      _LiveRegion._draw();
      rethrow;
    }
  }
}

/// The shared live region: every live [Bar] owns one line of it, so multiple
/// bars redraw without corrupting each other. Text on `stdout` is untouched;
/// bars draw on `stderr` only. Only bars still open redraw, so the next print
/// or prompt never lands under a stale (closed) bar.
final class _LiveRegion {
  static final List<Bar> _bars = [];
  static final List<String> _done = [];
  static var _drawn = 0;

  static bool get _live => Cli._liveRegion;

  /// Finished and printed lines first, then one line per open bar: the fake
  /// screen the live-region tests assert on.
  static List<String> get screen => [..._done, for (final bar in _bars) bar._render(_labelWidth)];

  static int get _labelWidth {
    var w = 0;
    for (final bar in _bars) {
      final n = bar.label?.length ?? 0;
      if (n > w) w = n;
    }
    return w;
  }

  static void _reset() {
    _bars.clear();
    _done.clear();
    _drawn = 0;
  }

  static void _attach(Bar bar) {
    if (!bar._live) return;
    _bars.add(bar);
    if (Cli._fakeSink != null) return;
    _draw();
  }

  static void _draw() {
    if (Cli._fakeSink != null) return;
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

  /// Blanks the live lines, leaving the cursor where the bars were: the
  /// next write lands above them, and [_draw] paints them back below it.
  static void _clearBars() {
    if (Cli._fakeSink != null) return;
    if (!_live || _drawn == 0) return;
    stderr.write('\x1b[${_drawn}A');
    for (var i = 0; i < _drawn; i++) {
      stderr.write('\r\x1b[K\n');
    }
    stderr.write('\x1b[${_drawn}A');
    _drawn = 0;
  }

  /// Runs [write] above the live bars (clearing them first, redrawing after).
  static void _writeThrough(void Function() write) {
    if (!_live || _bars.isEmpty) {
      write();
      return;
    }
    _clearBars();
    write();
    _draw();
  }

  static void _detach(Bar bar, String doneLine) {
    if (!bar._live) {
      _finish(doneLine);
      return;
    }
    _bars.remove(bar);
    if (Cli._fakeSink != null) {
      _finishFake(doneLine);
      return;
    }
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

  /// One completion line where no live region watches: stderr, or the fake
  /// sink under test.
  static void _finish(String line) {
    if (line.isEmpty) return;
    if (Cli._fakeSink != null) {
      _finishFake(line);
      return;
    }
    stderr.writeln(line);
  }

  static void _finishFake(String line) {
    _done.add(line);
    Cli._fakeSink!.writeln(line);
  }

  static void _printFake(String msg) {
    _done.add(msg);
    Cli._fakeSink!.writeln(msg);
  }
}

/// A speed meter over the last 3 s (an EWMA): each [sample] folds its
/// instantaneous rate in with `1 - e^(-dt/3)`, so bursts fade within seconds.
final class _Meter {
  double rate = 0;
  num _last = 0;
  DateTime? _at;

  void sample(num value) {
    final now = DateTime.now();
    final prev = _at;
    if (prev != null) {
      final dt = now.difference(prev).inMicroseconds / 1e6;
      if (dt > 0) {
        final instant = (value - _last).toDouble() / dt;
        rate += (1 - exp(-dt / 3)) * (instant - rate);
      }
    }
    _last = value;
    _at = now;
  }
}

/// A live progress bar; [set] advances it, [close] finishes the line.
///
/// Each bar owns one line of the shared live region, so several bars tick
/// side by side without corruption. The live line reads
/// `label  bar  pct  details`, like `ui.bar`; without a terminal (or with
/// `NO_COLOR`) each bar prints one line when it ends instead.
///
/// ```dart
/// final bar = Cli.bar(max: 100, label: 'Downloading');
/// try {
///   bar.set(50);
/// } finally {
///   bar.close();
/// }
/// ```
final class Bar {
  /// The total; [set] may move it as a progress callback learns it.
  int get max => _max;
  int _max;
  final String? label;
  final String? unit;

  /// The bar width in cells.
  final int size;

  /// The glyph set ([BarGlyphs.ascii] where the terminal cannot draw Unicode).
  final BarGlyphs glyphs;
  final Stopwatch _clock = Stopwatch()..start();
  final _Meter _meter = _Meter();
  int _value = 0;
  int _drawnValue = -1;
  String _drawnLine = '';
  int _lastDrawMs = -1000;
  bool _live = false;
  bool _done = false;

  Bar({int max = 0, this.label, this.unit, this.size = 24, this.glyphs = BarGlyphs.line}) : _max = max {
    _live = Cli._liveRegion;
    _meter.sample(0);
    _LiveRegion._attach(this);
  }

  /// The value shown.
  int get value => _value;

  /// Sets the completed amount to [value] (clamped to `[0, max]` once max is known), and
  /// the total to [max] when it is known (above 0): `bar.set` fits every
  /// `onProgress: (done, total)`. Reaching the total closes the bar; an empty job
  /// (`set(0, 0)` on a bar of no total) closes it at once.
  void set(int value, [int? max]) {
    if (_done) return;
    if (max != null && max > 0) _max = max;
    _value = value < 0 ? 0 : (_max > 0 && value > _max ? _max : value);
    _meter.sample(_value);
    _draw();
    if (_value == _max) close();
  }

  /// Adds one unit.
  void tick() => set(_value + 1);

  String get _line => _render(_LiveRegion._labelWidth);

  /// The live line: spinner frame, padded label, bar, percent, details.
  String _render(int labelWidth) {
    final ratio = max <= 0 ? 0.0 : _value / max;
    final g = _unicode() ? glyphs : BarGlyphs.ascii;
    final frame = _unicode() ? SpinGlyphs.dots.frame() : SpinGlyphs.ascii.frame();
    final done = (ratio * size + 1e-9).floor().clamp(0, size);
    // At 0% the bar is all track: no head.
    final head = ratio > 0 && done < size && g.head.isNotEmpty;
    final fills = g.fill * done + (head ? g.head : '');
    final track = g.empty * (size - done - (head ? 1 : 0));
    final pct = '${(ratio * 100).toStringAsFixed(0)}%';
    final details = _details();
    final labelPart = label == null ? '' : '${label!.padRight(labelWidth)}  ';
    final bar = '${fills.isEmpty ? '' : _accent(fills)}${track.isEmpty ? '' : _dim(track)}';
    return '${_accent(frame)} $labelPart$bar  $pct${details.isEmpty ? '' : '  ${_dim(details)}'}';
  }

  String _details() {
    if (max <= 0) return unit == 'B' ? _humanSingle(_value) : (unit == null ? '$_value' : '$_value $unit');
    if (unit == 'B') {
      var s = _humanPair(_value, max);
      if (_meter.rate > 0 && _value < max) {
        final eta = ((max - _value) / _meter.rate).ceil();
        s += ' · ${_humanSingle(_meter.rate)}/s · ${eta}s left';
      }
      return s;
    }
    return unit == null ? '$_value/$max' : '$_value/$max $unit';
  }

  void _draw() {
    if (!_live || _done) return;
    if (_value == _drawnValue) return;
    _drawnValue = _value;
    // One redraw per rendered line, at most every 80 ms: 200k sets write
    // kilobytes, not megabytes. close() always draws the final line.
    final line = _render(_LiveRegion._labelWidth);
    if (line == _drawnLine) return;
    final now = _clock.elapsedMilliseconds;
    if (now - _lastDrawMs < 80) return;
    _drawnLine = line;
    _lastDrawMs = now;
    _LiveRegion._draw();
  }

  /// Finishes the bar, leaving a completion line: `✓` only when
  /// `value >= max`, else `✗ label stopped at 50/100`.
  void close() {
    if (_done) return;
    _done = true;
    final line = _doneLine(_LiveRegion._labelWidth, _clock.elapsedMilliseconds / 1000);
    if (_live) {
      _LiveRegion._detach(this, line);
    } else {
      _LiveRegion._finish(line);
    }
  }

  String _doneLine(int labelWidth, double secs) {
    final t = '${secs.toStringAsFixed(1)}s';
    final uni = _unicode();
    final pad = label == null ? '' : '${label!.padRight(labelWidth)}  ';
    if (max <= 0 || _value >= max) {
      final n = max <= 0 ? _value : max;
      final what = unit == 'B' ? _humanSingle(n) : (unit == null ? '$n/$n' : '$n/$n $unit');
      return '${_green(uni ? '✓' : 'ok')} $pad$what in $t';
    }
    final at = unit == 'B' ? _humanPair(_value, max) : '$_value/$max';
    return '${_red(uni ? '✗' : 'failed')} $pad${_red('stopped at $at')}';
  }
}
