/// Immediate-mode terminal apps. In-house on `dart:io`
/// (ANSI output, raw stdin, `SIGWINCH`).
///
/// ```dart
/// await Tui.run((screen) async {
///   var count = 0;
///   while (!screen.pressed('escape')) {
///     await screen.frame((r) {
///       final [head, body] = r.rows([3, 0]);
///       head.box('Counter').write('count = $count', bold: true);
///       if (body.button('+1')) count++;
///     });
///   }
/// });
/// ```
///
/// Public surface is exactly: [Tui], [Screen], [Region].
/// - `Tui.run()` runs an app on the alternate screen.
/// - [Screen] supports `frame` `pressed` `typed` `width` `height`.
/// - [Region] supports `write` `box` `rows` `cols` `button`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

/// Entry point: run an immediate-mode app.
abstract final class Tui {
  /// Enter raw mode, the alternate screen and mouse reporting; always restore
  /// the terminal when [app] returns or throws. Throws [io.StdoutException]
  /// when stdout is not a terminal. `^C` is just `pressed('ctrl+c')`.
  static Future<void> run(Future<void> Function(Screen screen) app) async {
    final out = io.stdout;
    if (!out.hasTerminal) {
      throw const io.StdoutException('no terminal for the TUI');
    }
    final screen = Screen._();
    await screen._enter();
    try {
      await app(screen);
    } finally {
      await screen._leave();
    }
  }
}

/// The terminal: per-frame input state plus the screen size.
final class Screen {
  Screen._();

  var _width = 80;
  var _height = 24;
  final _pressed = <String>{};
  final _typed = StringBuffer();
  final _clicks = <_Cell>[];
  final _pending = <int>[];
  var _escHeld = false;
  StreamSubscription<List<int>>? _sub;
  StreamSubscription<io.ProcessSignal>? _sigwinchSub;
  var _lastFrame = 0;
  var _entered = false;

  List<List<_Cell>>? _last;
  List<_Button> _buttons = const [];
  List<_Button> _nextButtons = [];
  var _focus = 0;
  var _mouse = false;

  /// This frame's width in cells.
  int width() => _width;

  /// This frame's height in cells.
  int height() => _height;

  /// True when [key] was pressed since the last frame. Names are shared with
  /// `Page.press`: `'a'`, `'A'`, `'enter'`, `'tab'`, `'backspace'`,
  /// `'escape'`, `'up'`, `'down'`, `'left'`, `'right'`, `'home'`, `'end'`,
  /// `'pageup'`, `'pagedown'`, `'delete'`, `'f1'`…`'f12'`, `'ctrl+c'`,
  /// `'alt+x'`.
  bool pressed(String key) => _pressed.contains(key);

  /// Printable text typed since the last frame.
  String typed() => _typed.toString();

  /// One tick: wait for the next frame slot (~60 fps), collect input, run
  /// [build] on the whole screen, and write only the changed cells.
  /// Returns this screen.
  Future<Screen> frame(void Function(Region region) build) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = 16 - (now - _lastFrame);
    if (wait > 0) {
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
    _lastFrame = DateTime.now().millisecondsSinceEpoch;
    _poll();
    _width = io.stdout.terminalColumns;
    _height = io.stdout.terminalLines;
    final grid = List.generate(
      _height,
      (_) => List.generate(_width, (_) => const _Cell(' ')),
    );
    _nextButtons = [];
    build(Region._(grid, 0, 0, _width, _height, this));
    _buttons = _nextButtons;
    if (_buttons.isEmpty) {
      _focus = 0;
    } else if (_focus >= _buttons.length) {
      _focus = 0;
    }
    _paint(grid);
    _pressed.clear();
    _typed.clear();
    _clicks.clear();
    return this;
  }

  Future<void> _enter() async {
    _width = io.stdout.terminalColumns;
    _height = io.stdout.terminalLines;
    final stdin = io.stdin;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } catch (_) {}
    _sub = stdin.listen(
      _pending.addAll,
      onError: (_) {},
      cancelOnError: false,
    );
    try {
      _sigwinchSub = io.ProcessSignal.sigwinch.watch().listen((_) {
        _last = null;
      });
    } catch (_) {}
    final out = io.stdout;
    out.write('\x1b[?1049h\x1b[?25l');
    try {
      out.write('\x1b[?1000h\x1b[?1006h');
      _mouse = true;
    } catch (_) {}
    _lastFrame = DateTime.now().millisecondsSinceEpoch;
    _entered = true;
  }

  Future<void> _leave() async {
    if (!_entered) return;
    _entered = false;
    await _sub?.cancel();
    _sub = null;
    await _sigwinchSub?.cancel();
    _sigwinchSub = null;
    final stdin = io.stdin;
    try {
      stdin.echoMode = true;
      stdin.lineMode = true;
    } catch (_) {}
    final out = io.stdout;
    if (_mouse) out.write('\x1b[?1000l\x1b[?1006l');
    out.write('\x1b[?25h\x1b[?1049l');
    try {
      await out.flush();
    } catch (_) {}
  }

  void _poll() {
    _pressed.clear();
    _typed.clear();
    _clicks.clear();
    if (_pending.isEmpty) return;
    if (_escHeld && _pending.length == 1 && _pending[0] == 0x1b) {
      // The held ESC got no sequel: it was a real Escape press.
      _escHeld = false;
      _pending.clear();
      _pressed.add('escape');
      return;
    }
    _escHeld = false;
    final bytes = List<int>.of(_pending);
    final parsed = _parse(bytes);
    // Keep an incomplete trailing sequence (split ESC/CSI/SS3, or a UTF-8
    // char cut across reads) for the next frame instead of dropping it.
    final rest = bytes.sublist(parsed.consumed);
    if (rest.length == 1 && rest[0] == 0x1b) {
      // Maybe a split sequence's first byte: hold it one frame; a real
      // lone Escape is emitted on the next poll if nothing follows.
      _escHeld = true;
    }
    _pending
      ..clear()
      ..addAll(rest);
    for (final event in parsed.events) {
      switch (event) {
        case _Key(:final name):
          _pressed.add(name);
          if (name == 'tab') {
            if (_buttons.isNotEmpty) {
              _focus = (_focus + 1) % _buttons.length;
            }
          }
        case _Type(:final text):
          _typed.write(text);
        case _Click(:final x, :final y):
          _clicks.add(_Cell('', x: x, y: y));
      }
    }
  }

  bool _clicked(int x, int y, int w) {
    for (final c in _clicks) {
      if (c.y == y && c.x >= x && c.x < x + w) return true;
    }
    return false;
  }

  void _paint(List<List<_Cell>> grid) {
    final out = io.stdout;
    final buf = StringBuffer();
    if (_last == null ||
        _last!.length != grid.length ||
        _last!.any((row) => row.length != grid[0].length)) {
      buf.write('\x1b[2J\x1b[H');
      _last = List.generate(
        grid.length,
        (y) => List.of(grid[y]),
      );
      _paintFull(buf, grid);
      out.write(buf.toString());
      return;
    }
    final last = _last!;
    var cy = -1;
    var cx = -1;
    var style = '';
    for (var y = 0; y < grid.length; y++) {
      for (var x = 0; x < grid[y].length; x++) {
        final c = grid[y][x];
        if (c == last[y][x]) continue;
        last[y][x] = _Cell(c.ch, color: c.color, bold: c.bold);
        if (y != cy || x != cx) {
          buf.write('\x1b[${y + 1};${x + 1}H');
          cy = y;
          cx = x;
        }
        final s = _style(c);
        if (s != style) {
          buf.write(s.isEmpty ? '\x1b[0m' : s);
          style = s;
        }
        buf.write(c.ch.isEmpty ? ' ' : c.ch);
        cx++;
      }
    }
    if (style.isNotEmpty) buf.write('\x1b[0m');
    out.write(buf.toString());
  }

  void _paintFull(StringBuffer buf, List<List<_Cell>> grid) {
    var style = '';
    for (final row in grid) {
      for (final c in row) {
        final s = _style(c);
        if (s != style) {
          buf.write(s.isEmpty ? '\x1b[0m' : s);
          style = s;
        }
        buf.write(c.ch.isEmpty ? ' ' : c.ch);
      }
    }
    if (style.isNotEmpty) buf.write('\x1b[0m');
  }

  static String _style(_Cell c) {
    final buf = StringBuffer();
    if (c.bold) buf.write('\x1b[1m');
    if (c.color != null) buf.write('\x1b[38;5;${c.color}m');
    return buf.toString();
  }
}

/// A rectangle with a cursor at its top-left.
final class Region {
  Region._(this._grid, this._x, this._y, this._w, this._h, this._screen)
      : _cursor = 0;

  final List<List<_Cell>> _grid;
  final int _x;
  final int _y;
  final int _w;
  final int _h;
  final Screen _screen;
  int _cursor;

  /// Draw [text] at the cursor, move the cursor to the next line, clip at
  /// the edge. Wide characters count two cells. Returns this region.
  Region write(String text, {int? color, bool bold = false}) {
    final row = _y + _cursor;
    if (row < _y + _h && row < _grid.length) {
      var col = _x;
      for (final rune in text.runes) {
        final ch = String.fromCharCode(rune);
        if (ch == '\n') break;
        final w = _cellWidth(rune);
        if (col + w > _x + _w) break;
        if (col < _grid[row].length && col >= 0) {
          _grid[row][col] = _Cell(ch, color: color, bold: bold);
          if (w == 2 && col + 1 < _grid[row].length) {
            _grid[row][col + 1] = _Cell('', color: color, bold: bold);
          }
        }
        col += w;
      }
    }
    _cursor++;
    return this;
  }

  /// Draw a border with [title]; returns the inner region.
  Region box(String title) {
    _drawBorder(title);
    if (_w < 3 || _h < 3) {
      return Region._(_grid, _x, _y, 0, 0, _screen);
    }
    return Region._(_grid, _x + 1, _y + 1, _w - 2, _h - 2, _screen);
  }

  /// Split what is below the cursor into rows. A size above 0 is fixed
  /// cells; 0 shares what is left equally.
  List<Region> rows(List<int> sizes) => _split(sizes, horizontal: true);

  /// Split what is below the cursor into columns.
  List<Region> cols(List<int> sizes) => _split(sizes, horizontal: false);

  /// Draw a button at the cursor. True in the frame it is clicked, or when
  /// it has focus and Enter is pressed. Tab moves focus in drawing order.
  bool button(String label) {
    final text = '[ $label ]';
    final row = _y + _cursor;
    final index = _screen._nextButtons.length;
    _screen._nextButtons.add(_Button(row, _x, text.length));
    final isFocused = (_screen._buttons.isEmpty && index == 0) ||
        (index == _screen._focus);
    _drawButton(row, _x, text, isFocused);
    _cursor++;
    if (_screen._clicked(_x, row, text.length)) return true;
    if (isFocused && _screen._pressed.contains('enter')) return true;
    return false;
  }

  List<Region> _split(List<int> sizes, {required bool horizontal}) {
    final total = horizontal ? _h - _cursor : _w;
    final fixed = sizes.where((s) => s > 0).fold(0, (a, b) => a + b);
    final flex = sizes.where((s) => s <= 0).length;
    var rest = total - fixed;
    if (rest < 0) rest = 0;
    final each = flex == 0 ? 0 : rest ~/ flex;
    var extra = flex == 0 ? 0 : rest % flex;
    final out = <Region>[];
    var off = horizontal ? _y + _cursor : _x;
    for (final s in sizes) {
      var size = s > 0 ? s : each + (extra > 0 ? 1 : 0);
      if (s <= 0 && extra > 0) extra--;
      if (off + size > (horizontal ? _y + _h : _x + _w)) {
        size = (horizontal ? _y + _h : _x + _w) - off;
      }
      if (size < 0) size = 0;
      out.add(
        horizontal
            ? Region._(_grid, _x, off, _w, size, _screen)
            : Region._(_grid, off, _y + _cursor, size, _h - _cursor, _screen),
      );
      off += size;
    }
    _cursor = _h;
    return out;
  }

  void _drawBorder(String title) {
    if (_w <= 0 || _h <= 0) return;
    const tl = '┌', tr = '┐', bl = '└', br = '┘', h = '─', v = '│';
    _put(_x, _y, tl);
    _put(_x + _w - 1, _y, tr);
    _put(_x, _y + _h - 1, bl);
    _put(_x + _w - 1, _y + _h - 1, br);
    for (var x = _x + 1; x < _x + _w - 1; x++) {
      _put(x, _y, h);
      _put(x, _y + _h - 1, h);
    }
    for (var y = _y + 1; y < _y + _h - 1; y++) {
      _put(_x, y, v);
      _put(_x + _w - 1, y, v);
    }
    var col = _x + 2;
    for (final rune in ' $title '.runes) {
      if (col >= _x + _w - 1) break;
      _put(col, _y, String.fromCharCode(rune));
      col += _cellWidth(rune);
    }
  }

  void _drawButton(int row, int x, String text, bool focused) {
    if (row < 0 || row >= _grid.length) return;
    var col = x;
    for (final rune in text.runes) {
      if (col >= x + _w || col >= _grid[row].length) break;
      if (col >= 0) {
        _grid[row][col] =
            _Cell(String.fromCharCode(rune), bold: focused);
      }
      col++;
    }
  }

  void _put(int x, int y, String ch) {
    if (y < 0 || y >= _grid.length) return;
    if (x < 0 || x >= _grid[y].length) return;
    _grid[y][x] = const _Cell(' ').copy(ch);
  }
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension ScreenFuture on Future<Screen> {
  Future<Screen> frame(void Function(Region region) build) async =>
      (await this).frame(build);
  Future<bool> pressed(String key) async => (await this).pressed(key);
  Future<String> typed() async => (await this).typed();
  Future<int> width() async => (await this).width();
  Future<int> height() async => (await this).height();
}

final class _Cell {
  const _Cell(this.ch, {this.color, this.bold = false, this.x = -1, this.y = -1});

  final String ch;
  final int? color;
  final bool bold;
  final int x;
  final int y;

  _Cell copy(String ch) => _Cell(ch, color: color, bold: bold);

  @override
  bool operator ==(Object other) =>
      other is _Cell &&
      other.ch == ch &&
      other.color == color &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(ch, color, bold);
}

final class _Button {
  _Button(this.row, this.col, this.width);

  final int row;
  final int col;
  final int width;
}

sealed class _Event {}

final class _Key extends _Event {
  _Key(this.name);

  final String name;
}

final class _Type extends _Event {
  _Type(this.text);

  final String text;
}

final class _Click extends _Event {
  _Click(this.x, this.y);

  final int x;
  final int y;
}

int _cellWidth(int rune) {
  if (rune < 0x1100) return 1;
  if (rune <= 0x115f) return 2;
  if (rune == 0x2329 || rune == 0x232a) return 2;
  if (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) return 2;
  if (rune >= 0xac00 && rune <= 0xd7a3) return 2;
  if (rune >= 0xf900 && rune <= 0xfaff) return 2;
  if (rune >= 0xfe10 && rune <= 0xfe19) return 2;
  if (rune >= 0xfe30 && rune <= 0xfe4f) return 2;
  if (rune >= 0xff00 && rune <= 0xff60) return 2;
  if (rune >= 0xffe0 && rune <= 0xffe6) return 2;
  if (rune >= 0x20000 && rune <= 0x3fffd) return 2;
  return 1;
}

({List<_Event> events, int consumed}) _parse(List<int> bytes) {
  final out = <_Event>[];
  var i = 0;
  final text = StringBuffer();
  void flush() {
    if (text.isNotEmpty) {
      out.add(_Type(text.toString()));
      text.clear();
    }
  }

  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1b) {
      // Mouse SGR: ESC [ < btn ; x ; y M/m.
      if (i + 2 < bytes.length &&
          bytes[i + 1] == 0x5b &&
          bytes[i + 2] == 0x3c) {
        var j = i + 3;
        while (j < bytes.length &&
            bytes[j] != 0x4d &&
            bytes[j] != 0x6d) {
          j++;
        }
        if (j < bytes.length) {
          flush();
          final parts = ascii.decode(bytes.sublist(i + 3, j)).split(';');
          final btn = int.tryParse(parts[0]) ?? -1;
          final x = (int.tryParse(parts[1]) ?? 1) - 1;
          final y = (int.tryParse(parts[2]) ?? 1) - 1;
          if (bytes[j] == 0x4d && (btn & 64) == 0) {
            out.add(_Click(x, y));
          }
          i = j + 1;
          continue;
        }
        break;
      }
      if (i + 1 >= bytes.length) {
        // Lone trailing ESC: hold for the next frame (a split sequence's
        // first byte?) rather than emitting or dropping it here.
        break;
      }
      final n1 = bytes[i + 1];
      if (n1 == 0x5b) {
        // CSI sequence.
        var j = i + 2;
        while (j < bytes.length &&
            (bytes[j] < 0x40 || bytes[j] > 0x7e)) {
          j++;
        }
        if (j >= bytes.length) break;
        flush();
        final params = ascii.decode(bytes.sublist(i + 2, j));
        final fin = bytes[j];
        out.add(_Key(_csiName(params, fin)));
        i = j + 1;
        continue;
      }
      if (n1 == 0x4f) {
        // SS3: F1-F4.
        if (i + 2 >= bytes.length) break;
        flush();
        out.add(_Key(switch (bytes[i + 2]) {
          0x50 => 'f1',
          0x51 => 'f2',
          0x52 => 'f3',
          0x53 => 'f4',
          _ => 'escape',
        }));
        i += 3;
        continue;
      }
      // Alt+x: ESC followed by a char.
      flush();
      out.add(_Key('alt+${String.fromCharCode(n1)}'));
      i += 2;
      continue;
    }
    if (b == 0x09) {
      flush();
      out.add(_Key('tab'));
      i++;
      continue;
    }
    if (b == 0x0d || b == 0x0a) {
      flush();
      out.add(_Key('enter'));
      // Swallow a paired LF after CR.
      if (b == 0x0d && i + 1 < bytes.length && bytes[i + 1] == 0x0a) {
        i += 2;
      } else {
        i++;
      }
      continue;
    }
    if (b == 0x7f || b == 0x08) {
      flush();
      out.add(_Key('backspace'));
      i++;
      continue;
    }
    if (b < 0x20) {
      flush();
      // Ctrl+letter: 0x01..0x1A → a..z.
      final letter = String.fromCharCode(b + 0x60);
      out.add(_Key('ctrl+$letter'));
      i++;
      continue;
    }
    // Printable run: decode UTF-8 up to the next control/ESC.
    var j = i;
    while (j < bytes.length &&
        bytes[j] >= 0x20 &&
        bytes[j] != 0x1b &&
        bytes[j] != 0x7f) {
      j++;
    }
    if (j > i && j == bytes.length) {
      // The run hits the buffer end: hold back a trailing UTF-8 char split
      // across reads instead of emitting mojibake.
      j = _utf8Split(bytes, i, j);
      if (j == i) break;
    }
    flush();
    out.add(_Type(utf8.decode(bytes.sublist(i, j), allowMalformed: true)));
    i = j;
  }
  flush();
  return (events: out, consumed: i);
}

/// Pull [end] back past a trailing UTF-8 sequence split across reads.
int _utf8Split(List<int> bytes, int start, int end) {
  var k = end - 1;
  while (k >= start && bytes[k] & 0xc0 == 0x80) {
    k--;
  }
  if (k < start) return start; // all continuation bytes: hold everything
  final lead = bytes[k];
  final want = lead < 0x80
      ? 1
      : lead < 0xe0
          ? 2
          : lead < 0xf0
              ? 3
              : 4;
  if (end - k < want) return k; // incomplete: hold from the lead byte
  return end;
}

String _csiName(String params, int fin) {
  if (fin == 0x41) return 'up';
  if (fin == 0x42) return 'down';
  if (fin == 0x43) return 'right';
  if (fin == 0x44) return 'left';
  if (fin == 0x48) return 'home';
  if (fin == 0x46) return 'end';
  if (fin != 0x7e) return 'escape';
  return switch (params) {
    '1' || '7' => 'home',
    '2' => 'enter',
    '3' => 'delete',
    '4' || '8' => 'end',
    '5' => 'pageup',
    '6' => 'pagedown',
    '11' || '12' || '13' || '14' || '15' => 'f${int.parse(params) - 10}',
    '17' || '18' || '19' || '20' || '21' => 'f${int.parse(params) - 11}',
    '23' || '24' => 'f${int.parse(params) - 12}',
    _ => 'escape',
  };
}
