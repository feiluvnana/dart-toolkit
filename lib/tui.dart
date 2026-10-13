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
/// - [Region] supports `width` `height` `write` `box` `rows` `cols`
///   `button` `list` `input`.
/// Everything else is private. Key decoding, broadcast stdin and terminal
/// modes are shared with `console` through `src/terminal.dart` (imported
/// relatively, never exported).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'src/terminal.dart' as term;

/// Entry point: run an immediate-mode app.
abstract final class Tui {
  /// Enter raw mode, the alternate screen and mouse reporting; always restore
  /// the terminal when [app] returns or throws. Throws [io.StdoutException]
  /// when stdout is not a terminal. `^C` is just `pressed('ctrl+c')`.
  /// [run] can be called again in the same process.
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
  final _signals = <String>[];
  var _quietFrames = 0;
  StreamSubscription<List<int>>? _sub;
  StreamSubscription<io.ProcessSignal>? _sigwinchSub;
  StreamSubscription<io.ProcessSignal>? _sigintSub;
  StreamSubscription<io.ProcessSignal>? _sigtermSub;
  StreamSubscription<io.ProcessSignal>? _sighupSub;
  var _lastFrame = 0;
  var _entered = false;
  var _exiting = false;
  term.TermModes? _savedModes;

  List<List<_Cell>>? _last;
  List<List<_Cell>>? _gridA;
  List<List<_Cell>>? _gridB;
  var _useA = true;
  List<_Button> _buttons = const [];
  List<_Button> _nextButtons = [];
  var _focus = 0;
  var _mouse = false;
  var _paste = false;

  /// This frame's width in cells.
  int width() => _width;

  /// This frame's height in cells.
  int height() => _height;

  /// True when [key] was pressed since the last frame. Names are shared with
  /// `Page.press`: printable characters as themselves (`'a'`, `'A'`, `'1'`,
  /// plus `'space'`), `'enter'` `'tab'` `'shift+tab'` `'backspace'`
  /// `'escape'` `'insert'` `'delete'`, `'up'` `'down'` `'left'` `'right'`
  /// `'home'` `'end'` `'pageup'` `'pagedown'`, `'f1'`…`'f12'`,
  /// `'ctrl+c'` `'alt+x'` `'ctrl+up'`, `'wheelup'` `'wheeldown'`.
  /// Unknown sequences are ignored, never reported as `escape`.
  bool pressed(String key) => _pressed.contains(key);

  /// Printable text typed since the last frame (pasted text included).
  String typed() => _typed.toString();

  /// One tick: wait for the next frame slot (~60 fps), collect input, run
  /// [build] on the whole screen, and write only the changed cells.
  /// Input stays available after `frame` returns, until the next `frame`,
  /// so `while (!screen.pressed('escape')) await screen.frame(…)` works,
  /// and so does `screen.frame(…).pressed('q')`.
  /// Returns this screen.
  Future<Screen> frame(void Function(Region region) build) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = 16 - (now - _lastFrame);
    if (wait > 0) {
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
    _lastFrame = DateTime.now().millisecondsSinceEpoch;
    _poll();
    try {
      _width = io.stdout.terminalColumns;
      _height = io.stdout.terminalLines;
    } catch (_) {
      // Keep the previous size when the terminal won't answer mid-resize.
    }
    if (_width < 1) _width = 1;
    if (_height < 1) _height = 1;
    final grid = _gridFor(_width, _height);
    _nextButtons = [];
    build(Region._(grid, 0, 0, _width, _height, this));
    _buttons = _nextButtons;
    if (_buttons.isEmpty) {
      _focus = 0;
    } else if (_focus >= _buttons.length) {
      _focus = 0;
    }
    _paint(grid);
    return this;
  }

  Future<void> _enter() async {
    _width = io.stdout.terminalColumns;
    _height = io.stdout.terminalLines;
    if (_width < 1) _width = 1;
    if (_height < 1) _height = 1;
    _savedModes = term.captureModes();
    term.setRawModes();
    _sub = term.sharedStdin().listen(
      _pending.addAll,
      onError: (_) {},
      cancelOnError: false,
    );
    try {
      _sigwinchSub = io.ProcessSignal.sigwinch.watch().listen((_) {
        // A resize repaints everything, row by row, on the next frame.
        _last = null;
      });
    } catch (_) {}
    // While a SIGINT listener exists Dart does not terminate on Ctrl-C:
    // it becomes just another key.
    try {
      _sigintSub = io.ProcessSignal.sigint.watch().listen((_) {
        _signals.add('ctrl+c');
      });
    } catch (_) {}
    try {
      _sigtermSub = io.ProcessSignal.sigterm.watch().listen((_) async {
        await _leave();
        io.exit(143);
      });
    } catch (_) {}
    try {
      _sighupSub = io.ProcessSignal.sighup.watch().listen((_) async {
        await _leave();
        io.exit(129);
      });
    } catch (_) {}
    final out = io.stdout;
    out.write('\x1b[?1049h\x1b[?25l\x1b[?7l');
    try {
      out.write('\x1b[?1000h\x1b[?1006h');
      _mouse = true;
    } catch (_) {}
    try {
      out.write('\x1b[?2004h');
      _paste = true;
    } catch (_) {}
    _lastFrame = DateTime.now().millisecondsSinceEpoch;
    _entered = true;
  }

  Future<void> _leave() async {
    if (!_entered || _exiting) return;
    _exiting = true;
    try {
      // Our own subscriptions only; the broadcast stdin source is shared
      // and never closed, so a later run (or a prompt) still works.
      await _sub?.cancel();
      _sub = null;
      await _sigwinchSub?.cancel();
      _sigwinchSub = null;
      await _sigintSub?.cancel();
      _sigintSub = null;
      await _sigtermSub?.cancel();
      _sigtermSub = null;
      await _sighupSub?.cancel();
      _sighupSub = null;
      final saved = _savedModes;
      if (saved != null) term.restoreModes(saved);
      final out = io.stdout;
      if (_paste) out.write('\x1b[?2004l');
      if (_mouse) out.write('\x1b[?1000l\x1b[?1006l');
      out.write('\x1b[?7h\x1b[?25h\x1b[?1049l');
      try {
        await out.flush();
      } catch (_) {}
    } finally {
      _entered = false;
      _exiting = false;
    }
  }

  void _poll() {
    _pressed.clear();
    _typed.clear();
    _clicks.clear();
    for (final s in _signals) {
      _pressed.add(s);
    }
    _signals.clear();
    if (_pending.isEmpty) return;
    final had = _pending.length;
    final bytes = List<int>.of(_pending);
    final parsed = term.decodeKeys(bytes);
    var rest = bytes.sublist(parsed.consumed);
    if (rest.isNotEmpty && rest.length == had) {
      // No progress and no new bytes: a lone ESC (or ESC-prefixed unit) the
      // user actually finished typing. Force-decode one unit so a lone
      // Escape doesn't wait forever; a split sequence keeps arriving and
      // keeps making progress, so it is never forced.
      _quietFrames++;
      if (_quietFrames >= 1) {
        _quietFrames = 0;
        rest = _forceOne(rest);
      }
    } else {
      _quietFrames = 0;
    }
    _pending
      ..clear()
      ..addAll(rest);
    for (final event in parsed.events) {
      _apply(event);
    }
  }

  /// Force-decode one leading ESC unit from held [rest]; return the rest.
  List<int> _forceOne(List<int> rest) {
    if (rest.isEmpty || rest[0] != 0x1b) return rest;
    if (rest.length == 1) {
      _apply(term.TermKey('escape'));
      return const [];
    }
    if (rest[1] == 0x1b) {
      _apply(term.TermKey('escape'));
      return rest.sublist(2);
    }
    var width = 1;
    final b = rest[1];
    if (b >= 0x80) {
      if (b < 0xc2) {
        width = 1;
      } else if (b < 0xe0) {
        width = 2;
      } else if (b < 0xf0) {
        width = 3;
      } else {
        width = 4;
      }
      if (1 + width > rest.length) return rest; // still split: keep holding.
      _apply(term.TermKey(
        'alt+${utf8.decode(rest.sublist(1, 1 + width), allowMalformed: true)}',
      ));
      return rest.sublist(1 + width);
    }
    _apply(term.TermKey('alt+${String.fromCharCode(b)}'));
    return rest.sublist(2);
  }

  void _apply(term.TermEvent event) {
    switch (event) {
      case term.TermKey(:final name):
        _pressed.add(name);
        if (name == 'tab') {
          if (_buttons.isNotEmpty) {
            _focus = (_focus + 1) % _buttons.length;
          }
        } else if (name == 'shift+tab') {
          if (_buttons.isNotEmpty) {
            _focus = (_focus - 1 + _buttons.length) % _buttons.length;
          }
        }
      case term.TermType(:final text, :final paste):
        _typed.write(text);
        if (!paste) {
          // Printable keys are also `pressed` ('a', 'A', '1'; 'space').
          for (final rune in text.runes) {
            _pressed.add(
              rune == 0x20 ? 'space' : String.fromCharCode(rune),
            );
          }
        }
      case term.TermClick(:final x, :final y):
        _clicks.add(_Cell('', x: x, y: y));
    }
  }

  bool _clicked(int x, int y, int w) {
    for (final c in _clicks) {
      if (c.y == y && c.x >= x && c.x < x + w) return true;
    }
    return false;
  }

  /// The build grid for this frame, reused across frames (swapped each
  /// frame, cleared with `fillRange`) instead of allocated per frame.
  List<List<_Cell>> _gridFor(int width, int height) {
    _useA = !_useA;
    var grid = _useA ? _gridA : _gridB;
    if (grid == null || grid.length != height) {
      grid = List.generate(
        height,
        (_) => List.filled(width, const _Cell(' '), growable: true),
        growable: false,
      );
      if (_useA) {
        _gridA = grid;
      } else {
        _gridB = grid;
      }
      // A resized grid may also have a new width: fix every row.
      for (var y = 0; y < grid.length; y++) {
        if (grid[y].length != width) {
          grid[y] = List.filled(width, const _Cell(' '), growable: true);
        } else {
          grid[y].fillRange(0, grid[y].length, const _Cell(' '));
        }
      }
      return grid;
    }
    for (var y = 0; y < grid.length; y++) {
      final row = grid[y];
      if (row.length != width) {
        grid[y] = List.filled(width, const _Cell(' '), growable: true);
      } else {
        row.fillRange(0, row.length, const _Cell(' '));
      }
    }
    return grid;
  }

  void _paint(List<List<_Cell>> grid) {
    if (grid.isEmpty) return;
    final out = io.stdout;
    final buf = StringBuffer();
    if (_last == null ||
        _last!.length != grid.length ||
        _last!.any((row) => row.length != grid[0].length)) {
      buf.write('\x1b[2J\x1b[H');
      _last = List.generate(
        grid.length,
        (y) => List.of(grid[y], growable: true),
        growable: false,
      );
      _paintFull(buf, grid);
      out.write(buf.toString());
      return;
    }
    final last = _last!;
    var cy = -1;
    var cx = -1;
    var style = '\x1b[0m';
    for (var y = 0; y < grid.length; y++) {
      final row = grid[y];
      final lastRow = last[y];
      for (var x = 0; x < row.length; x++) {
        final c = row[x];
        if (c.width == 0) {
          // Continuation half of a wide char: never emitted on its own.
          cx++;
          continue;
        }
        final l = lastRow[x];
        final continuationChanged =
            c.width == 2 && lastRow[x + 1].width != 0;
        if (c == l && !continuationChanged) {
          cx += c.width;
          continue;
        }
        lastRow[x] = _Cell(c.ch,
            color: c.color, bold: c.bold, inverse: c.inverse, width: c.width);
        if (y != cy || x != cx) {
          buf.write('\x1b[${y + 1};${x + 1}H');
          cy = y;
          cx = x;
        }
        final s = _style(c);
        if (s != style) {
          buf.write(s);
          style = s;
        }
        buf.write(c.ch.isEmpty ? ' ' : c.ch);
        if (c.width == 2) {
          lastRow[x + 1] = const _Cell('', width: 0);
          cx = x + 2;
        } else {
          // A narrowed cell orphans its old continuation half: blank it.
          if (x + 1 < row.length && lastRow[x + 1].width == 0) {
            buf.write(' ');
            lastRow[x + 1] = const _Cell(' ');
            cx = x + 2;
          } else {
            cx = x + 1;
          }
        }
      }
    }
    if (style != '\x1b[0m') buf.write('\x1b[0m');
    out.write(buf.toString());
  }

  void _paintFull(StringBuffer buf, List<List<_Cell>> grid) {
    // Autowrap is off, so every row is addressed explicitly: one cell whose
    // width we misjudged can only damage its own row, never the screen.
    var style = '\x1b[0m';
    for (var y = 0; y < grid.length; y++) {
      buf.write('\x1b[${y + 1};1H');
      for (final c in grid[y]) {
        if (c.width == 0) continue;
        final s = _style(c);
        if (s != style) {
          buf.write(s);
          style = s;
        }
        buf.write(c.ch.isEmpty ? ' ' : c.ch);
      }
    }
    if (style != '\x1b[0m') buf.write('\x1b[0m');
  }

  /// Always from a reset, so a style never leaks into the next cell.
  static String _style(_Cell c) {
    if (!c.bold && !c.inverse && c.color == null) return '\x1b[0m';
    final buf = StringBuffer('\x1b[0');
    if (c.bold) buf.write(';1');
    if (c.inverse) buf.write(';7');
    if (c.color != null) buf.write(';38;5;${c.color}');
    buf.write('m');
    return buf.toString();
  }
}

/// A rectangle with a cursor at its top-left. Every method draws or splits
/// *below the cursor* and clips to the region.
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

  /// This region's width in cells.
  int width() => _w;

  /// This region's height in cells.
  int height() => _h;

  /// Draw [text] at the cursor and move the cursor down past the lines it
  /// used. `\n` starts the next line, `\t` expands to spaces (tab stops
  /// every 8 columns), other control characters show as `�`, and anything
  /// past the edge is clipped. Wide CJK/emoji take two cells; a wide char
  /// that doesn't fit in the last column becomes a space. Returns this
  /// region.
  Region write(String text, {int? color, bool bold = false}) {
    for (final line in text.split('\n')) {
      if (_cursor < _h) _drawLine(line, color: color, bold: bold);
      _cursor++;
    }
    return this;
  }

  void _drawLine(String line, {int? color, bool bold = false}) {
    final row = _y + _cursor;
    if (row < 0 || row >= _grid.length) return;
    var col = _x;
    final end = _x + _w;
    final runes = line.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final rune = runes[i];
      if (rune == 0x09) {
        // Tab: spaces up to the next multiple of 8 (region-relative).
        var next = col + (8 - (col - _x) % 8);
        if (next <= col) next = col + 1;
        while (col < next && col < end) {
          _place(row, col, ' ', 1, color, bold, false);
          col++;
        }
        i++;
        continue;
      }
      if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
        // Other C0/C1 controls and DEL never reach the terminal raw.
        if (col < end) {
          _place(row, col, '�', 1, color, bold, false);
          col++;
        }
        i++;
        continue;
      }
      if (isZeroWidth(rune)) {
        // Combining mark / ZWJ / variation selector: attach to the previous
        // cell's string instead of taking a cell.
        if (col > _x) {
          final prev = _grid[row][col - 1];
          if (prev.width != 0 && col - 1 < end) {
            _grid[row][col - 1] = _Cell(
              '${prev.ch}${String.fromCharCode(rune)}',
              color: prev.color,
              bold: prev.bold,
              inverse: prev.inverse,
              width: prev.width,
            );
          }
        }
        i++;
        continue;
      }
      final w = cellWidth(rune);
      final ch = String.fromCharCode(rune);
      // Attach any following zero-width runes to this cluster.
      final cluster = StringBuffer(ch);
      var j = i + 1;
      while (j < runes.length && isZeroWidth(runes[j])) {
        cluster.writeCharCode(runes[j]);
        j++;
      }
      i = j;
      if (col >= end) break;
      if (w == 2 && col + 1 >= end) {
        _place(row, col, ' ', 1, color, bold, false);
        col++;
        continue;
      }
      _place(row, col, cluster.toString(), w, color, bold, false);
      col += w;
    }
  }

  /// Place one cluster at ([row], [col]), blanking the orphaned half when a
  /// cell overwrites half of an existing wide char.
  void _place(
      int row, int col, String ch, int w, int? color, bool bold, bool inverse) {
    if (row < 0 || row >= _grid.length) return;
    final gridRow = _grid[row];
    final end = _x + _w;
    if (col < _x || col >= end || col >= gridRow.length) return;
    // Overwriting a continuation half: blank its lead.
    if (gridRow[col].width == 0 && col - 1 >= _x) {
      gridRow[col - 1] = const _Cell(' ');
    }
    gridRow[col] = _Cell(ch,
        color: color, bold: bold, inverse: inverse, width: w);
    if (w == 2) {
      if (col + 1 < end && col + 1 < gridRow.length) {
        gridRow[col + 1] = _Cell('', color: color, bold: bold,
            inverse: inverse, width: 0);
      }
    } else if (col + 1 < end &&
        col + 1 < gridRow.length &&
        gridRow[col + 1].width == 0) {
      // A narrowed cell orphans the old continuation half: blank it.
      gridRow[col + 1] = const _Cell(' ');
    }
  }

  /// Draw a border with [title] around the rest of the region (below the
  /// cursor) and return the inside. Consumes the region, like [rows]/[cols].
  Region box(String title) {
    final top = _y + _cursor;
    final rest = _h - _cursor;
    _drawBorder(_x, top, _w, rest, title);
    _cursor = _h;
    if (_w < 3 || rest < 3) {
      return Region._(_grid, _x, top, 0, 0, _screen);
    }
    return Region._(_grid, _x + 1, top + 1, _w - 2, rest - 2, _screen);
  }

  /// Split what is below the cursor into rows. A size above 0 is fixed
  /// cells; 0 shares what is left equally. A negative size is an
  /// [ArgumentError].
  List<Region> rows(List<int> sizes) => _split(sizes, horizontal: true);

  /// Split what is below the cursor into columns. A negative size is an
  /// [ArgumentError].
  List<Region> cols(List<int> sizes) => _split(sizes, horizontal: false);

  /// Draw a button at the cursor. True in the frame it is clicked (left
  /// button), or when it has focus and Enter is pressed. Tab and Shift+Tab
  /// move the focus, drawn inverted. A button that doesn't fit is neither
  /// drawn nor focusable (and can't fire).
  bool button(String label) {
    if (_cursor >= _h) {
      _cursor++;
      return false;
    }
    final text = '[ $label ]';
    final row = _y + _cursor;
    final index = _screen._nextButtons.length;
    // Clip the click area to what is actually drawn.
    var room = _w;
    if (row >= 0 && row < _grid.length) {
      room = _w.clamp(0, _grid[row].length - _x);
    }
    if (room < 0) room = 0;
    final drawn = text.length.clamp(0, room);
    _screen._nextButtons.add(_Button(row, _x, drawn));
    final isFocused = (_screen._buttons.isEmpty && index == 0) ||
        (index == _screen._focus);
    _drawButton(row, _x, text, drawn, isFocused);
    _cursor++;
    if (drawn > 0 && _screen._clicked(_x, row, drawn)) return true;
    if (isFocused && _screen._pressed.contains('enter')) return true;
    return false;
  }

  /// A scrollable list: draws the rows that fit with [selected] in view and
  /// highlighted, handles `up` `down` `pageup` `pagedown` `home` `end`, the
  /// wheel and clicks, and returns the new selected index. Consumes the
  /// region. An empty list draws nothing and returns 0.
  int list(List<String> items, int selected) {
    final top = _y + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    if (items.isEmpty || h <= 0) return 0;
    var sel = selected.clamp(0, items.length - 1);
    if (_screen._pressed.contains('up')) sel--;
    if (_screen._pressed.contains('down')) sel++;
    if (_screen._pressed.contains('pageup')) sel -= h;
    if (_screen._pressed.contains('pagedown')) sel += h;
    if (_screen._pressed.contains('home')) sel = 0;
    if (_screen._pressed.contains('end')) sel = items.length - 1;
    if (_screen._pressed.contains('wheelup')) sel -= 3;
    if (_screen._pressed.contains('wheeldown')) sel += 3;
    sel = sel.clamp(0, items.length - 1);
    // Clicks select directly.
    for (var r = 0; r < h && r < items.length; r++) {
      if (_screen._clicked(_x, top + r, _w)) {
        sel = (_selStart(sel, items.length, h) + r)
            .clamp(0, items.length - 1);
        break;
      }
    }
    final start = _selStart(sel, items.length, h);
    for (var r = 0; r < h; r++) {
      final idx = start + r;
      if (idx >= items.length) break;
      final row = top + r;
      final isSel = idx == sel;
      _drawRowText(row, items[idx], isSel);
    }
    return sel;
  }

  /// Window start keeping [sel] in view without stored scroll state.
  int _selStart(int sel, int len, int h) {
    if (len <= h) return 0;
    final start = (sel ~/ h) * h;
    return start + h > len ? len - h : start;
  }

  void _drawRowText(int row, String text, bool highlight) {
    if (row < 0 || row >= _grid.length) return;
    var col = _x;
    final end = _x + _w;
    // Highlight the whole row, then draw the (clipped) text over it.
    while (col < end && col < _grid[row].length && col >= 0) {
      _grid[row][col] = _Cell(' ', inverse: highlight);
      col++;
    }
    col = _x;
    for (final rune in text.runes) {
      if (col >= end) break;
      if (rune == 0x09) {
        var next = col + (8 - (col - _x) % 8);
        if (next <= col) next = col + 1;
        while (col < next && col < end) {
          _place(row, col, ' ', 1, null, false, highlight);
          col++;
        }
        continue;
      }
      if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
        _place(row, col, '�', 1, null, false, highlight);
        col++;
        continue;
      }
      if (isZeroWidth(rune)) continue;
      final w = cellWidth(rune);
      if (w == 2 && col + 1 >= end) {
        _place(row, col, ' ', 1, null, false, highlight);
        col++;
        continue;
      }
      _place(row, col, String.fromCharCode(rune), w, null, false, highlight);
      col += w;
    }
  }

  /// A single-line text field showing [value] with a cursor. Handles
  /// `typed()`, `backspace` (by grapheme) and pastes, and returns the edited
  /// text. Consumes one row.
  String input(String value) {
    var v = value;
    final typed = _screen._typed.toString();
    if (typed.isNotEmpty) v += typed;
    if (_screen._pressed.contains('backspace')) {
      v = _deleteLastGrapheme(v);
    }
    // Draw the tail that fits, with a block cursor at the end.
    final row = _y + _cursor;
    _cursor++;
    if (row < 0 || row >= _grid.length) return v;
    const cursor = '▌';
    final room = _w - 1;
    var visible = v;
    if (room <= 0) {
      if (_w >= 1) _place(row, _x, cursor, 1, null, false, false);
      return v;
    }
    // Keep the tail whose width fits in `room` (plus the cursor cell).
    var width = 0;
    final runes = visible.runes.toList();
    var i = runes.length;
    while (i > 0) {
      final r = runes[i - 1];
      if (isZeroWidth(r)) {
        i--;
        continue;
      }
      width += cellWidth(r);
      if (width > room) break;
      i--;
    }
    visible = String.fromCharCodes(runes.sublist(i));
    var col = _x;
    final end = _x + _w;
    for (final rune in visible.runes) {
      if (col >= end - 1) break;
      if (isZeroWidth(rune)) continue;
      final w = cellWidth(rune);
      if (w == 2 && col + 1 >= end - 1) {
        _place(row, col, ' ', 1, null, false, false);
        col++;
        break;
      }
      _place(row, col, String.fromCharCode(rune), w, null, false, false);
      col += w;
    }
    if (col < end) _place(row, col, cursor, 1, null, false, false);
    return v;
  }

  /// Delete the last grapheme cluster (base char + combining marks).
  String _deleteLastGrapheme(String v) {
    if (v.isEmpty) return v;
    final runes = v.runes.toList();
    var end = runes.length;
    while (end > 0 && isZeroWidth(runes[end - 1])) {
      end--;
    }
    if (end > 0) end--;
    return String.fromCharCodes(runes.sublist(0, end));
  }

  List<Region> _split(List<int> sizes, {required bool horizontal}) {
    for (final s in sizes) {
      if (s < 0) {
        throw ArgumentError.value(
            sizes, 'sizes', 'negative size $s: use 0 for a flex share');
      }
    }
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

  void _drawBorder(int x, int y, int w, int h, String title) {
    if (w <= 0 || h <= 0) return;
    const tl = '┌', tr = '┐', bl = '└', br = '┘', hh = '─', v = '│';
    _put(x, y, tl);
    _put(x + w - 1, y, tr);
    _put(x, y + h - 1, bl);
    _put(x + w - 1, y + h - 1, br);
    for (var xx = x + 1; xx < x + w - 1; xx++) {
      _put(xx, y, hh);
      _put(xx, y + h - 1, hh);
    }
    for (var yy = y + 1; yy < y + h - 1; yy++) {
      _put(x, yy, v);
      _put(x + w - 1, yy, v);
    }
    // Title with wide-char continuation cells; never the `┐` corner.
    var col = x + 2;
    final runes = ' $title '.runes.toList();
    var i = 0;
    while (i < runes.length && col < x + w - 1) {
      final rune = runes[i];
      if (isZeroWidth(rune)) {
        i++;
        continue;
      }
      final wch = cellWidth(rune);
      if (wch == 2 && col + 1 >= x + w - 1) break;
      _putWide(col, y, String.fromCharCode(rune), wch);
      col += wch;
      i++;
    }
  }

  void _drawButton(int row, int x, String text, int drawn, bool focused) {
    if (row < 0 || row >= _grid.length) return;
    var col = x;
    var left = drawn;
    for (final rune in text.runes) {
      if (left <= 0) break;
      if (col >= x + _w || col >= _grid[row].length) break;
      if (col >= 0) {
        _grid[row][col] = _Cell(String.fromCharCode(rune),
            inverse: focused, width: 1);
      }
      col++;
      left--;
    }
  }

  void _put(int x, int y, String ch) {
    if (y < 0 || y >= _grid.length) return;
    if (x < 0 || x >= _grid[y].length) return;
    final old = _grid[y][x];
    _grid[y][x] = _Cell(ch,
        color: old.color, bold: old.bold, inverse: old.inverse, width: 1);
  }

  void _putWide(int x, int y, String ch, int w) {
    if (y < 0 || y >= _grid.length) return;
    if (x < 0 || x >= _grid[y].length) return;
    _grid[y][x] = _Cell(ch, width: w);
    if (w == 2 && x + 1 < _grid[y].length) {
      _grid[y][x + 1] = const _Cell('', width: 0);
    }
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
  const _Cell(this.ch,
      {this.color,
      this.bold = false,
      this.inverse = false,
      this.width = 1,
      this.x = -1,
      this.y = -1});

  final String ch;
  final int? color;
  final bool bold;
  final bool inverse;

  /// Cells taken by this char: 2 for a wide char (lead), 0 for its
  /// continuation half (never emitted on its own).
  final int width;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _Cell &&
      other.ch == ch &&
      other.color == color &&
      other.bold == bold &&
      other.inverse == inverse &&
      other.width == width;

  @override
  int get hashCode => Object.hash(ch, color, bold, inverse, width);
}

final class _Button {
  _Button(this.row, this.col, this.width);

  final int row;
  final int col;
  final int width;
}

/// True for runes that take no cell (shared with `console`).
/// See `src/terminal.dart` for the table.
bool isZeroWidth(int rune) => term.isZeroWidth(rune);

/// Cells taken by [rune] on screen (shared with `console`).
/// See `src/terminal.dart` for the table.
int cellWidth(int rune) => term.cellWidth(rune);
