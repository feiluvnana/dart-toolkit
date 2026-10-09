/// # Testing
///
/// The fakes a test needs beyond the ones each module ships on its own types (`Client.fake`,
/// `Runner.fake`, `Clock.fake`): [FakeTerminal], the screen and keyboard `Console` and `Tui` draw
/// on under `Io.scope(terminal:)`. Its own import, so a program that never tests compiles none of it.
///
/// {@category CLI}
library;

import 'dart:async';
import 'dart:convert';

import 'src/core.dart';
import 'src/keys.dart';

export 'core.dart';
export 'src/keys.dart' show KeyPress, PointerKind;

/// A terminal in memory for tests: [type] or [press] keys, [resize] it, report [focus] and
/// [blur], [resume] it after ^Z, and read the [screen] it shows: a small VT emulator keeps it,
/// alternate screen and all. It answers a cursor position query, and the kitty keyboard query
/// when [kitty] is set. Use it under `Io.scope(terminal:)`, for `Console`'s live region and
/// pickers (`cli`) and `Tui` apps (`tui`).
///
/// ```dart
/// final term = FakeTerminal(width: 40, height: 10);
/// final done = Io.scope(terminal: term, () => Tui.run(0, draw: (n) => Label('$n'),
///     update: (n, e) => switch (e) { KeyPress.up => n + 1, KeyPress.esc => Tui.quit(n), _ => n }));
/// Future<void> pump() async { for (var i = 0; i < 3; i++) await Future<void>.delayed(Duration.zero); }
/// await pump(); term.press(KeyPress.up); await pump();
/// expect(term.screen, '1');
/// ```
///
/// {@category CLI}
final class FakeTerminal implements Terminal {
  int _width, _height;

  @override
  final int colors;

  @override
  final bool unicode;

  /// Whether it speaks the kitty keyboard protocol: it answers the query, and [press] then
  /// encodes Shift+Enter as that protocol does.
  final bool kitty;

  /// Every [write], in order: what a frame cost, byte for byte.
  final List<String> writes = [];

  bool isOpen = false,
      isAltScreen = false,
      isCursorVisible = true,
      isPointer = false,
      isMotion = false,
      isPaste = false;

  /// Whether focus reports are on (`?1004h`), and whether the app has stopped itself on ^Z
  /// until [resume].
  bool isFocusReport = false, isSuspended = false;
  Completer<void>? _stopped;

  /// Whether the kitty keyboard protocol is on.
  bool isKitty = false;

  final StreamController<List<int>> _input = StreamController.broadcast();
  final StreamController<void> _resized = StreamController.broadcast();
  late List<List<String>> _main = _grid(), _alt = _grid();
  int _cx = 0, _cy = 0;

  List<List<String>> get _g => isAltScreen ? _alt : _main;

  FakeTerminal({int width = 80, int height = 24, this.colors = 256, this.unicode = true, this.kitty = false})
    : _width = width,
      _height = height;

  @override
  int get width => _width;

  @override
  int get height => _height;

  /// Where the cursor is: column and row, 0-based.
  (int, int) get cursor => (_cx, _cy);

  List<List<String>> _grid() => [for (var y = 0; y < height; y++) List.filled(width, ' ')];

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  @override
  Future<void> open() async => isOpen = true;

  @override
  void close() => isOpen = false;

  @override
  Future<void> suspend() {
    isSuspended = true;
    return (_stopped = Completer<void>()).future;
  }

  /// Runs the app again after it stopped on ^Z, as SIGCONT does.
  void resume() {
    isSuspended = false;
    _stopped?.complete();
    _stopped = null;
  }

  /// Reports that the window gained the focus (`ESC [ I`).
  void focus() => type('\x1b[I');

  /// Reports that the window lost the focus (`ESC [ O`).
  void blur() => type('\x1b[O');

  /// Sends [text] as typed: `'hi'`, or raw sequences like `'\x1b[A'`.
  void type(String text) => _input.add(utf8.encode(text));

  /// Sends raw [bytes]: a sequence cut mid-character, or malformed input.
  void send(List<int> bytes) => _input.add(bytes);

  /// Sends [key] as a terminal encodes it.
  void press(KeyPress key) => type(_encode(key));

  /// Clicks, moves or scrolls at [x], [y] of the screen (SGR encoding).
  void pointer(int x, int y, [PointerKind kind = PointerKind.press]) {
    final b = switch (kind) {
      PointerKind.wheelUp => 64,
      PointerKind.wheelDown => 65,
      PointerKind.drag => 32,
      PointerKind.move => 35,
      _ => 0,
    };
    type('\x1b[<$b;${x + 1};${y + 1}${kind == PointerKind.release ? 'm' : 'M'}');
  }

  void resize(int width, int height) {
    List<List<String>> fit(List<List<String>> g) => [
      for (var y = 0; y < height; y++)
        [for (var x = 0; x < width; x++) y < g.length && x < g[y].length ? g[y][x] : ' '],
    ];
    _width = width;
    _height = height;
    _main = fit(_main);
    _alt = fit(_alt);
    _resized.add(null);
  }

  /// What the screen shows, rows joined by newlines, trailing blanks and blank rows dropped.
  String get screen {
    final rows = [for (final r in isAltScreen ? _alt : _main) r.join().trimRight()];
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    return rows.join('\n');
  }

  @override
  void write(String data) {
    writes.add(data);
    final runes = data.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      final r = runes[i];
      if (r == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        if (j >= runes.length) break;
        _csi(String.fromCharCodes(runes, i + 2, j), runes[j]);
        i = j;
      } else if (r == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5d) {
        // OSC (a hyperlink, a title): nothing drawn, up to BEL or ESC \.
        var j = i + 2;
        while (j < runes.length && runes[j] != 0x07 && runes[j] != 0x1b) {
          j++;
        }
        i = j < runes.length && runes[j] == 0x1b ? j + 1 : j;
      } else if (r == 0x0d) {
        _cx = 0;
      } else if (r == 0x0a) {
        if (++_cy >= height) {
          _g
            ..removeAt(0)
            ..add(List.filled(width, ' '));
          _cy = height - 1;
        }
      } else if (r >= 0x20) {
        final w = IoBridge.runeWidth(r);
        if (w == 0) continue;
        if (_cx + w <= width && _cy < height) {
          _g[_cy][_cx] = String.fromCharCode(r);
          if (w == 2) _g[_cy][_cx + 1] = '';
        }
        _cx = (_cx + w).clamp(0, width);
      }
    }
  }

  void _csi(String params, int fin) {
    if (params == '6' && fin == 0x6e) return _reply('\x1b[${_cy + 1};${_cx + 1}R');
    if (params == '?' && fin == 0x75) return kitty ? _reply('\x1b[?${isKitty ? 1 : 0}u') : null;
    if (fin == 0x75 && (params.startsWith('>') || params.startsWith('<'))) {
      if (kitty) isKitty = params.startsWith('>');
      return;
    }
    if (params.startsWith('?')) {
      final on = fin == 0x68;
      for (final p in params.substring(1).split(';')) {
        switch (p) {
          case '1049':
            if (on) _alt = _grid();
            isAltScreen = on;
          case '25':
            isCursorVisible = on;
          case '2004':
            isPaste = on;
          case '1000' || '1002' || '1006':
            isPointer = on;
          case '1003':
            isMotion = on;
          case '1004':
            isFocusReport = on;
        }
      }
      return;
    }
    final ps = params.split(';').map((p) => int.tryParse(p)).toList();
    int n([int i = 0, int or = 1]) => i < ps.length && ps[i] != null ? ps[i]! : or;
    final g = _g;
    void clear(int y, int from, int to) {
      for (var x = from; x < to && x < width; x++) {
        g[y][x] = ' ';
      }
    }

    switch (String.fromCharCode(fin)) {
      case 'A':
        _cy = (_cy - n()).clamp(0, height - 1);
      case 'B':
        _cy = (_cy + n()).clamp(0, height - 1);
      case 'C':
        _cx = (_cx + n()).clamp(0, width - 1);
      case 'D':
        _cx = (_cx - n()).clamp(0, width - 1);
      case 'H' || 'f':
        _cy = (n(0) - 1).clamp(0, height - 1);
        _cx = (n(1) - 1).clamp(0, width - 1);
      case 'J':
        final mode = n(0, 0);
        for (var y = 0; y < height; y++) {
          if (mode == 2 || y > _cy) clear(y, 0, width);
        }
        if (mode != 2) clear(_cy, _cx, width);
      case 'K':
        final mode = n(0, 0);
        clear(_cy, mode == 2 ? 0 : _cx, width);
    }
  }

  /// A terminal's answer, as it would arrive: after the write that asked for it.
  void _reply(String text) => scheduleMicrotask(() => type(text));

  String _encode(KeyPress k) {
    if (isKitty && k.name == 'enter' && (k.shift || k.ctrl)) {
      return '\x1b[13;${1 + (k.shift ? 1 : 0) + (k.ctrl ? 4 : 0)}u';
    }
    const csi = {
      'up': 'A',
      'down': 'B',
      'right': 'C',
      'left': 'D',
      'home': 'H',
      'end': 'F',
      'f1': 'P',
      'f2': 'Q',
      'f3': 'R',
      'f4': 'S',
    };
    const tilde = {
      'insert': 2,
      'delete': 3,
      'pageUp': 5,
      'pageDown': 6,
      'f5': 15,
      'f6': 17,
      'f7': 18,
      'f8': 19,
      'f9': 20,
      'f10': 21,
      'f11': 23,
      'f12': 24,
    };
    final mod = 1 + (k.shift ? 1 : 0) + (k.alt ? 2 : 0) + (k.ctrl ? 4 : 0);
    if (k == KeyPress.backTab) return '\x1b[Z';
    if (csi[k.name] case final c?) return mod == 1 ? '\x1b[$c' : '\x1b[1;$mod$c';
    if (tilde[k.name] case final t?) return mod == 1 ? '\x1b[$t~' : '\x1b[$t;$mod~';
    final alt = k.alt ? '\x1b' : '';
    return alt +
        switch (k.name) {
          'enter' => '\r',
          'tab' => '\t',
          'backspace' => '\x7f',
          'esc' => '\x1b',
          final c when k.ctrl && c.length == 1 => String.fromCharCode(c.codeUnitAt(0) & 0x1f),
          final c => c,
        };
  }
}
