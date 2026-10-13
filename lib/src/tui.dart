/// Engine behind `package:dart_toolkit/tui.dart`, which exports only [Tui],
/// [Screen], [Region] and the Future mirror. Tests import this file to drive
/// a [Screen] without a terminal ([testScreen], [testInput]).
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;

import 'terminal.dart' as term;

/// Entry point: run an immediate-mode app.
abstract final class Tui {
  /// Enter raw mode, the alternate screen and mouse reporting, run [app],
  /// and restore the terminal when it returns or throws, on Ctrl-C (which
  /// is just `pressed('ctrl+c')` while running), on SIGTERM/SIGHUP, and on
  /// an uncaught error in work the app started without awaiting (that error
  /// is rethrown from [run]). Throws [io.StdoutException] when stdout is not
  /// a terminal. [run] can be called again in the same process.
  static Future<void> run(Future<void> Function(Screen screen) app) async {
    if (!io.stdout.hasTerminal) {
      throw const io.StdoutException('no terminal for the TUI');
    }
    final screen = Screen._(io.stdout.write, _terminalSize);
    await screen._enter();
    final done = Completer<void>();
    void fail(Object e, StackTrace st) {
      if (done.isCompleted) {
        io.stderr.writeln('Uncaught after Tui.run: $e\n$st');
      } else {
        done.completeError(e, st);
      }
    }

    runZonedGuarded(() {
      app(screen).then((_) {
        if (!done.isCompleted) done.complete();
      }, onError: fail);
    }, fail);
    try {
      await done.future;
    } finally {
      await screen._leave();
    }
  }
}

(int, int) _terminalSize() =>
    (io.stdout.terminalColumns, io.stdout.terminalLines);

/// A [Screen] that writes to [out] and is [width]×[height] (or whatever
/// [size] answers each frame), for tests: no terminal, no signals. Feed it
/// input with [testInput].
Screen testScreen(void Function(String) out, int width, int height,
        {(int, int) Function()? size}) =>
    Screen._(out, size ?? () => (width, height));

/// Queue raw input [bytes] for the next `frame` of [screen].
void testInput(Screen screen, List<int> bytes) => screen._pending.addAll(bytes);

/// The terminal: per-frame input state plus the screen size.
final class Screen {
  Screen._(this._out, this._size);

  final void Function(String) _out;
  final (int, int) Function() _size;

  var _width = 80;
  var _height = 24;

  // Input of the current frame, valid from `frame` until the next `frame`.
  final _pressed = <String>{};
  final _events = <_Input>[];
  final _typed = StringBuffer();
  final _clicks = <(int, int)>[];

  // Raw input not yet decoded, and signals turned into keys.
  final _pending = <int>[];
  final _signals = <String>[];
  int? _heldSince;
  var _heldLength = 0;

  // Render state.
  List<List<_Cell>> _grid = const [];
  List<List<_Cell>>? _shown;
  var _repaint = true;
  var _lastFrame = 0;

  // Widget state carried from one frame to the next, keyed by draw order.
  var _buttons = 0;
  var _nextButtons = 0;
  var _focus = 0;
  List<int> _scrolls = const [];
  var _nextScrolls = <int>[];

  // Terminal session.
  final _subs = <StreamSubscription<Object?>>[];
  term.TermModes? _modes;
  var _entered = false;

  /// This frame's width in cells.
  int width() => _width;

  /// This frame's height in cells.
  int height() => _height;

  /// True when [key] was pressed in this frame's input. Names are shared
  /// with `Page.press`: printable characters as themselves (`'a'`, `'A'`,
  /// `'1'`, plus `'space'`), `'enter'` `'tab'` `'shift+tab'` `'backspace'`
  /// `'escape'` `'insert'` `'delete'`, `'up'` `'down'` `'left'` `'right'`
  /// `'home'` `'end'` `'pageup'` `'pagedown'`, `'f1'`…`'f12'`, `'ctrl+c'`
  /// `'alt+x'` `'ctrl+up'`, `'wheelup'` `'wheeldown'`. Unknown sequences
  /// are ignored, never reported as `escape`.
  bool pressed(String key) => _pressed.contains(key);

  /// Printable text typed since the last frame (pasted text included).
  String typed() => _typed.toString();

  /// One tick: wait for the next frame slot (~60 fps), collect input, run
  /// [build] on the whole screen, and write only the changed cells. Input
  /// stays readable after `frame` returns, until the next `frame`, so
  /// `while (!screen.pressed('escape')) await screen.frame(…)` works.
  /// Returns this screen.
  Future<Screen> frame(void Function(Region region) build) async {
    final wait = 16 - (_now() - _lastFrame);
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    final now = _now();
    // A long gap (a suspend with Ctrl-Z, a slow build) may have left other
    // output on the screen: repaint everything once.
    if (_lastFrame != 0 && now - _lastFrame > 500) _repaint = true;
    _lastFrame = now;
    _poll();
    var (w, h) = (_width, _height);
    try {
      (w, h) = _size();
    } catch (_) {
      // Keep the previous size when the terminal won't answer mid-resize.
    }
    w = math.max(1, w);
    h = math.max(1, h);
    if (w != _width || h != _height) _repaint = true;
    _width = w;
    _height = h;
    _clear();
    _nextButtons = 0;
    _nextScrolls = <int>[];
    build(Region._(this, 0, 0, w, h));
    _buttons = _nextButtons;
    _scrolls = _nextScrolls;
    if (_focus >= _buttons) _focus = 0;
    _paint();
    return this;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> _enter() async {
    try {
      final (w, h) = _size();
      _width = math.max(1, w);
      _height = math.max(1, h);
    } catch (_) {}
    _modes = term.captureModes();
    term.setRawModes();
    _subs.add(term.sharedStdin().listen(_pending.addAll, onError: (_) {}));
    void watch(io.ProcessSignal signal, void Function() onSignal) {
      try {
        _subs.add(signal.watch().listen((_) => onSignal()));
      } catch (_) {
        // Not every signal can be watched on every platform.
      }
    }

    watch(io.ProcessSignal.sigwinch, () => _repaint = true);
    // While a SIGINT listener exists Dart does not exit on Ctrl-C: it
    // becomes just another key.
    watch(io.ProcessSignal.sigint, () => _signals.add('ctrl+c'));
    watch(io.ProcessSignal.sigterm, () => _quit(143));
    watch(io.ProcessSignal.sighup, () => _quit(129));
    // Alternate screen, hidden cursor, autowrap off (a misjudged width can
    // never wrap or scroll), SGR mouse, bracketed paste.
    _out('\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1006h\x1b[?2004h');
    _repaint = true;
    _entered = true;
  }

  Future<void> _quit(int code) async {
    await _leave();
    io.exit(code);
  }

  Future<void> _leave() async {
    if (!_entered) return;
    _entered = false;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _out('\x1b[0m\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[?7h\x1b[?25h'
        '\x1b[?1049l');
    final modes = _modes;
    if (modes != null) term.restoreModes(modes);
    try {
      await io.stdout.flush();
    } catch (_) {}
  }

  // --- input ---------------------------------------------------------------

  void _poll() {
    _pressed.clear();
    _events.clear();
    _typed.clear();
    _clicks.clear();
    for (final name in _signals) {
      _key(name);
    }
    _signals.clear();
    _decode();
    if (_pending.isEmpty) {
      _heldSince = null;
      return;
    }
    // An undecodable prefix is held for a split sequence's next bytes. When
    // nothing arrives for 30 ms, a lone ESC was the Escape key and ESC + one
    // byte was Alt+key; anything longer that never completes is dropped.
    final now = _now();
    if (_heldSince == null || _pending.length != _heldLength) {
      _heldSince = now;
      _heldLength = _pending.length;
      return;
    }
    final waited = now - _heldSince!;
    if (_pending.length <= 2 && waited >= 30) {
      if (_pending.length == 1 || _pending[1] == 0x1b) {
        _key('escape');
      } else if (_pending[1] < 0x80) {
        _key('alt+${String.fromCharCode(_pending[1])}');
      }
    } else if (waited < 1000) {
      return; // keep holding
    }
    _pending.clear();
    _heldSince = null;
  }

  void _decode() {
    if (_pending.isEmpty) return;
    final parsed = term.decodeKeys(_pending);
    _pending.removeRange(0, parsed.consumed);
    for (final event in parsed.events) {
      switch (event) {
        case term.TermKey(:final name):
          _key(name);
        case term.TermType(:final text, :final paste):
          _typed.write(text);
          _events.add(_Input(null, text));
          if (!paste) {
            for (final rune in text.runes) {
              _pressed.add(rune == 0x20 ? 'space' : String.fromCharCode(rune));
            }
          }
        case term.TermClick(:final x, :final y):
          _clicks.add((x, y));
      }
    }
  }

  void _key(String name) {
    _pressed.add(name);
    _events.add(_Input(name, null));
    if (_buttons == 0) return;
    if (name == 'tab') _focus = (_focus + 1) % _buttons;
    if (name == 'shift+tab') _focus = (_focus - 1 + _buttons) % _buttons;
  }

  bool _clickedIn(int x, int end, int y) =>
      _clicks.any((c) => c.$2 == y && c.$1 >= x && c.$1 < end);

  // --- rendering -----------------------------------------------------------

  void _clear() {
    if (_grid.length != _height || _grid.first.length != _width) {
      _grid = List.generate(
          _height, (_) => List.filled(_width, _Cell.blank),
          growable: false);
      return;
    }
    for (final row in _grid) {
      row.fillRange(0, row.length, _Cell.blank);
    }
  }

  /// Write what changed since the last paint, or everything after a resize.
  /// The terminal cursor is tracked only across writes: after a non-ASCII
  /// cell its advance is never trusted, so a char whose width we misjudge
  /// can only damage itself, never the cells after it.
  void _paint() {
    final grid = _grid;
    var shown = _shown;
    if (_repaint || shown == null) {
      shown = _shown = List.generate(
          grid.length, (_) => List.filled(_width, _Cell.unknown),
          growable: false);
      _repaint = false;
    }
    final buf = StringBuffer();
    var style = 0;
    for (var y = 0; y < grid.length; y++) {
      final row = grid[y];
      final was = shown[y];
      var cx = -1;
      for (var x = 0; x < row.length; x++) {
        final c = row[x];
        if (c.width == 0 || c == was[x]) continue;
        if (x != cx) buf.write('\x1b[${y + 1};${x + 1}H');
        if (c.style != style) {
          buf.write(_sgr(c.style));
          style = c.style;
        }
        buf.write(c.ch);
        was[x] = c;
        if (c.width == 2 && x + 1 < row.length) was[x + 1] = row[x + 1];
        cx = c.isAscii ? x + 1 : -1;
      }
    }
    if (buf.isEmpty) return;
    if (style != 0) buf.write('\x1b[0m');
    // Synchronized output: the terminal shows the frame all at once.
    _out('\x1b[?2026h$buf\x1b[?2026l');
  }

  static final _sgrCache = <int, String>{};

  /// SGR for a packed style, always from a reset so nothing leaks.
  static String _sgr(int style) => _sgrCache.putIfAbsent(style, () {
        if (style == 0) return '\x1b[0m';
        final b = StringBuffer('\x1b[0');
        if (style & _bold != 0) b.write(';1');
        if (style & _inverse != 0) b.write(';7');
        final color = (style & _colorMask) - 1;
        if (color >= 0) b.write(';38;5;$color');
        b.write('m');
        return b.toString();
      });
}

const _colorMask = 0x1ff; // colour index + 1; 0 = default
const _bold = 0x200;
const _inverse = 0x400;

int _styleOf(int? color, {bool bold = false, bool inverse = false}) {
  if (color != null && (color < 0 || color > 255)) {
    throw RangeError.range(color, 0, 255, 'color');
  }
  return (color == null ? 0 : color + 1) |
      (bold ? _bold : 0) |
      (inverse ? _inverse : 0);
}

/// A rectangle with a cursor at its top-left. Every method draws or splits
/// *below the cursor* and clips to the region.
final class Region {
  Region._(this._s, this._x, this._y, this._w, this._h);

  final Screen _s;
  final int _x;
  final int _y;
  final int _w;
  final int _h;
  var _cursor = 0;

  /// This region's width in cells.
  int width() => _w;

  /// This region's height in cells.
  int height() => _h;

  /// Draw [text] at the cursor and move the cursor down past the lines it
  /// used. `\n` starts the next line, `\t` expands to the next multiple of
  /// 8 columns, ANSI colour codes are dropped, other control characters
  /// show as `�`, and anything past the edge is clipped. Wide CJK/emoji take
  /// two cells; combining marks join the previous char. [color] is a
  /// 256-colour index. Returns this region.
  Region write(String text, {int? color, bool bold = false}) {
    final style = _styleOf(color, bold: bold);
    for (final line in text.split('\n')) {
      if (_cursor < _h) _text(_y + _cursor, _x, _x + _w, line, style);
      _cursor++;
    }
    return this;
  }

  /// Draw a border with [title] around the rest of the region (below the
  /// cursor) and return the inside. Consumes the region, like [rows]/[cols].
  Region box(String title) {
    final top = _y + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    if (_w <= 0 || h <= 0) return Region._(_s, _x, top, 0, 0);
    final right = _x + _w - 1;
    final bottom = top + h - 1;
    for (var x = _x; x <= right; x++) {
      _put(top, x, '─', 1, 0);
      _put(bottom, x, '─', 1, 0);
    }
    for (var y = top; y <= bottom; y++) {
      _put(y, _x, '│', 1, 0);
      _put(y, right, '│', 1, 0);
    }
    _put(top, _x, '┌', 1, 0);
    _put(top, right, '┐', 1, 0);
    _put(bottom, _x, '└', 1, 0);
    _put(bottom, right, '┘', 1, 0);
    if (title.isNotEmpty && _w > 5) _text(top, _x + 2, right, ' $title ', 0);
    if (_w < 3 || h < 3) return Region._(_s, _x, top, 0, 0);
    return Region._(_s, _x + 1, top + 1, _w - 2, h - 2);
  }

  /// Split what is below the cursor into rows. A size above 0 is fixed
  /// cells; 0 shares what is left equally. A negative size is an
  /// [ArgumentError].
  List<Region> rows(List<int> sizes) => _split(sizes, horizontal: true);

  /// Split what is below the cursor into columns, the same way as [rows].
  List<Region> cols(List<int> sizes) => _split(sizes, horizontal: false);

  /// Draw a button at the cursor. True in the frame it is clicked (left
  /// button), or when it has focus and Enter is pressed. Tab and Shift+Tab
  /// move the focus (the first button has it at the start), drawn
  /// inverted. A button below the region's edge is neither drawn nor
  /// focusable.
  bool button(String label) {
    if (_cursor >= _h || _w <= 0) {
      _cursor++;
      return false;
    }
    final row = _y + _cursor++;
    final focused = _s._nextButtons++ == _s._focus;
    final end = _text(row, _x, _x + _w, '[ $label ]',
        _styleOf(null, inverse: focused));
    return _s._clickedIn(_x, end, row) ||
        (focused && _s._pressed.contains('enter'));
  }

  /// A scrolling list of [items] with [selected] highlighted and kept in
  /// view; returns the new selection. Handles `up` `down` `pageup`
  /// `pagedown` `home` `end` (each press counts), the wheel, and clicks.
  /// Scrolls by the least needed. Consumes the region. An empty list draws
  /// nothing and returns 0.
  int list(List<String> items, int selected) {
    final top = _y + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    final slot = _s._nextScrolls.length;
    final before = slot < _s._scrolls.length ? _s._scrolls[slot] : 0;
    if (items.isEmpty || h <= 0 || _w <= 0) {
      _s._nextScrolls.add(0);
      return 0;
    }
    final last = items.length - 1;
    var start = math.min(math.max(0, before), math.max(0, items.length - h));
    var sel = math.min(math.max(0, selected), last);
    // A click picks the row that was on screen where it landed.
    for (final (cx, cy) in _s._clicks) {
      if (cy >= top && cy < top + h && cx >= _x && cx < _x + _w) {
        sel = math.min(start + cy - top, last);
      }
    }
    for (final e in _s._events) {
      sel = switch (e.key) {
        'up' || 'wheelup' => sel - 1,
        'down' || 'wheeldown' => sel + 1,
        'pageup' => sel - h,
        'pagedown' => sel + h,
        'home' => 0,
        'end' => last,
        _ => sel,
      };
      sel = math.min(math.max(0, sel), last);
    }
    if (sel < start) start = sel;
    if (sel >= start + h) start = sel - h + 1;
    _s._nextScrolls.add(start);
    for (var r = 0; r < h && start + r <= last; r++) {
      final style = _styleOf(null, inverse: start + r == sel);
      if (style != 0) {
        for (var x = _x; x < _x + _w; x++) {
          _put(top + r, x, ' ', 1, style);
        }
      }
      _text(top + r, _x, _x + _w, items[start + r], style);
    }
    return sel;
  }

  /// A one-line text field showing [value] and a cursor; returns the edited
  /// text. Applies this frame's typing, pastes and `backspace` (one
  /// grapheme per press) in the order they happened. Newlines and tabs in a
  /// paste become spaces. Consumes one row; a long value shows its tail.
  String input(String value) {
    var v = value;
    for (final e in _s._events) {
      if (e.text != null) {
        v += _oneLine(e.text!);
      } else if (e.key == 'backspace') {
        v = _dropLast(v);
      }
    }
    if (_cursor >= _h || _w <= 0) {
      _cursor++;
      return v;
    }
    final row = _y + _cursor++;
    final end = _text(row, _x, _x + _w - 1, _tail(v, _w - 1), 0);
    _put(row, end, ' ', 1, _inverse);
    return v;
  }

  static String _oneLine(String text) => text
      .replaceAll('\r\n', ' ')
      .replaceAll(RegExp('[\r\n\t]'), ' ')
      .replaceAll(RegExp('[\x00-\x1f\x7f]'), '');

  /// [v] without its last grapheme (base char plus combining marks).
  static String _dropLast(String v) {
    final runes = v.runes.toList();
    var end = runes.length;
    while (end > 0 && term.isZeroWidth(runes[end - 1])) {
      end--;
    }
    return String.fromCharCodes(runes.sublist(0, math.max(0, end - 1)));
  }

  /// The longest tail of [v] that fits in [cells].
  static String _tail(String v, int cells) {
    final runes = v.runes.toList();
    var used = 0;
    var i = runes.length;
    while (i > 0) {
      final r = runes[i - 1];
      final w = term.isZeroWidth(r) ? 0 : term.cellWidth(r);
      if (used + w > cells) break;
      used += w;
      i--;
    }
    // Never start on a combining mark.
    while (i < runes.length && term.isZeroWidth(runes[i])) {
      i++;
    }
    return String.fromCharCodes(runes.sublist(i));
  }

  List<Region> _split(List<int> sizes, {required bool horizontal}) {
    for (final s in sizes) {
      if (s < 0) {
        throw ArgumentError.value(
            sizes, 'sizes', 'negative size $s: use 0 for a flex share');
      }
    }
    final total = horizontal ? _h - _cursor : _w;
    final fixed = sizes.fold(0, (a, b) => a + b);
    final flex = sizes.where((s) => s == 0).length;
    final rest = math.max(0, total - fixed);
    final each = flex == 0 ? 0 : rest ~/ flex;
    var extra = flex == 0 ? 0 : rest % flex;
    final end = horizontal ? _y + _h : _x + _w;
    var off = horizontal ? _y + _cursor : _x;
    final out = <Region>[];
    for (final s in sizes) {
      var size = s > 0 ? s : each + (extra-- > 0 ? 1 : 0);
      size = math.min(size, math.max(0, end - off));
      out.add(horizontal
          ? Region._(_s, _x, off, _w, size)
          : Region._(_s, off, _y + _cursor, size, _h - _cursor));
      off += size;
    }
    _cursor = _h;
    return out;
  }

  /// Draw one line of [text] on grid row [row] from column [from] up to
  /// (not including) [end]; returns the column after the last cell drawn.
  int _text(int row, int from, int end, String text, int style) {
    final grid = _s._grid;
    if (row < _y || row >= _y + _h || row >= grid.length) return from;
    end = math.min(end, grid[row].length);
    final runes = text.runes.toList();
    var col = from;
    var i = 0;
    while (i < runes.length && col < end) {
      final rune = runes[i++];
      if (rune == 0x1b && i < runes.length && runes[i] == 0x5b) {
        // An ANSI sequence (colours from other tools): drop it whole.
        i++;
        while (i < runes.length && (runes[i] < 0x40 || runes[i] > 0x7e)) {
          i++;
        }
        i++;
        continue;
      }
      if (rune == 0x09) {
        final next = col + 8 - (col - _x) % 8;
        while (col < next && col < end) {
          _put(row, col++, ' ', 1, style);
        }
        continue;
      }
      if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
        _put(row, col++, '�', 1, style);
        continue;
      }
      if (term.isZeroWidth(rune)) continue; // a stray mark with no base
      final cluster = StringBuffer()..writeCharCode(rune);
      while (i < runes.length && term.isZeroWidth(runes[i])) {
        cluster.writeCharCode(runes[i++]);
      }
      final w = term.cellWidth(rune);
      if (col + w > end) {
        _put(row, col++, ' ', 1, style); // a wide char cut at the edge
        break;
      }
      _put(row, col, cluster.toString(), w, style);
      col += w;
    }
    return col;
  }

  /// Place one cell, keeping wide chars whole: overwriting either half of a
  /// wide char blanks its other half.
  void _put(int row, int col, String ch, int width, int style) {
    final grid = _s._grid;
    if (row < 0 || row >= grid.length) return;
    final cells = grid[row];
    if (col < 0 || col + width > cells.length) return;
    if (cells[col].width == 0 && col > 0) cells[col - 1] = _Cell.blank;
    final after = col + width;
    if (after < cells.length && cells[after].width == 0) {
      cells[after] = _Cell.blank;
    }
    cells[col] = _Cell(ch, style, width);
    if (width == 2) cells[col + 1] = _Cell('', style, 0);
  }
}

/// Future mirrors (rule 4). The extension name is import-only; never
/// reference it.
extension ScreenFuture on Future<Screen> {
  Future<Screen> frame(void Function(Region region) build) async =>
      (await this).frame(build);
  Future<bool> pressed(String key) async => (await this).pressed(key);
  Future<String> typed() async => (await this).typed();
  Future<int> width() async => (await this).width();
  Future<int> height() async => (await this).height();
}

/// One input event in arrival order: a key name or typed text.
final class _Input {
  const _Input(this.key, this.text);

  final String? key;
  final String? text;
}

final class _Cell {
  const _Cell(this.ch, [this.style = 0, this.width = 1]);

  static const blank = _Cell(' ');

  /// What the screen holds before a full repaint: equal to no real cell.
  static const unknown = _Cell('', -1, -1);

  final String ch;
  final int style;

  /// 1 or 2 for a char, 0 for the right half of a wide char.
  final int width;

  bool get isAscii => ch.length == 1 && ch.codeUnitAt(0) < 0x7f;

  @override
  bool operator ==(Object other) =>
      other is _Cell &&
      other.ch == ch &&
      other.style == style &&
      other.width == width;

  @override
  int get hashCode => Object.hash(ch, style, width);
}
