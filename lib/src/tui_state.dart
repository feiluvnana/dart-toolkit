/// State-driven terminal apps (REPORT §15, Step 1a scaffold).
///
/// New surface: [Tui], [App], [Screen], [Bind], [Pick], [Field], [Scroll],
/// [Region], [Color], [Style]. Temporary home is `tui2.dart`; this merges
/// into `src/tui.dart` (replacing the immediate-mode engine) at migration,
/// when `tui_test.dart`, `tui_pty/` and `rawfree` move over too.
///
/// Covered now: state-driven loop, event-driven redraws (60 fps coalesced,
/// zone-tracked), fullscreen mode, key/mouse routing 1–6 (click, wheel,
/// right/middle/doubleclick, hover), focus identity + recency, title/status
/// rows with key help, handler Exception/Error rules, colours (downgrade,
/// NO_COLOR, ASCII), terminal life, second-run guard, widgets write/box/
/// rows/cols/tabs/scroll/popup/on/list/table/input/button/bar/spin, Field
/// history/submit, Scroll follow, hovered/focused.
///
/// Deferred to 1b (throw [UnimplementedError]): [Region.markdown]
/// highlighting + layout cache, [Region.diff], [Region.picture],
/// [Region.input] `lines`/`suggest`, inline mode (`fullscreen: false`) with
/// [App.print] commit, Console-in-Tui routing, focus/blur lifecycle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:dart_toolkit/image.dart' show Image;

import 'terminal.dart' as term;

/// An event binding: a shown label plus the action it runs.
/// Binding names list alternatives separated by spaces (`'b escape'`).
/// An empty label hides the binding from the key help.
typedef Bind = (String label, FutureOr<void> Function() action);

/// Mouse event names usable in [Bind] maps.
const _mouseNames = {
  'click',
  'doubleclick',
  'rightclick',
  'middleclick',
  'wheelup',
  'wheeldown',
};

/// Lifecycle event names usable in [Bind] maps.
const _lifecycleNames = {'show', 'resize', 'focus', 'blur'};

bool _isMouse(String name) => _mouseNames.contains(name);
bool _isLifecycle(String name) => _lifecycleNames.contains(name);

bool _sameId(Object? a, Object? b) =>
    identical(a, b) || (a is String && b is String && a == b);

/// A terminal colour: a 256-palette index or an RGB triple.
/// Downgraded to the terminal's level at paint time (truecolor → 256 → 16;
/// `NO_COLOR` drops colours and keeps styles).
final class Color {
  static const black = Color._(0, null);
  static const red = Color._(1, null);
  static const green = Color._(2, null);
  static const yellow = Color._(3, null);
  static const blue = Color._(4, null);
  static const magenta = Color._(5, null);
  static const cyan = Color._(6, null);
  static const white = Color._(7, null);
  static const gray = Color._(8, null);
  static const orange = Color._(208, null);

  /// 0–255, else [ArgumentError].
  factory Color.index(int index) {
    if (index < 0 || index > 255) {
      throw ArgumentError.value(index, 'index', 'must be 0..255');
    }
    return Color._(index, null);
  }

  factory Color.rgb(int r, int g, int b) {
    for (final (n, v) in [('r', r), ('g', g), ('b', b)]) {
      if (v < 0 || v > 255) {
        throw ArgumentError.value(v, n, 'must be 0..255');
      }
    }
    return Color._(_rgbTo256(r, g, b), (r, g, b));
  }

  const Color._(this._i, this._rgb);

  final int _i;
  final (int, int, int)? _rgb;

  @override
  bool operator ==(Object other) =>
      other is Color && other._i == _i && other._rgb == _rgb;

  @override
  int get hashCode => Object.hash(_i, _rgb);
}

int _rgbTo256(int r, int g, int b) {
  if (r == g && g == b) {
    if (r < 8) return 16;
    if (r > 248) return 231;
    return 232 + ((r - 8) * 24 ~/ 247).clamp(0, 23);
  }
  int c(int v) => (v / 51).round().clamp(0, 5);
  return 16 + 36 * c(r) + 6 * c(g) + c(b);
}

/// Text styles.
enum Style { bold, dim, italic, underline, strike, reverse }

/// A list's items and selection. Lives in the app's state object, so the
/// selection (and focus) survives redraws and state switches.
final class Pick<T> {
  Pick([List<T> items = const []]) : _items = List<T>.unmodifiable(items);

  List<T> _items;
  var _index = 0;

  List<T> items() => _items;
  int index() => _index;

  /// The selected item, or null when empty.
  T? selected() =>
      _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

  /// Replace the items, keeping the selected item if it is still there,
  /// else selecting 0.
  Pick<T> set(List<T> items) {
    final cur = selected();
    _items = List<T>.unmodifiable(items);
    if (_items.isEmpty) {
      _index = 0;
      return this;
    }
    final at = cur == null ? -1 : _items.indexOf(cur);
    _index = at >= 0 ? at : 0;
    return this;
  }

  /// Select [index], clamped.
  Pick<T> select(int index) {
    _index = _items.isEmpty ? 0 : index.clamp(0, _items.length - 1);
    return this;
  }
}

/// An input's text, cursor and history. Lives in the app's state object.
final class Field {
  Field({String text = '', List<String> history = const []})
      : _text = text,
        _history = List<String>.unmodifiable(history) {
    _cursor = text.runes.length;
  }

  String _text;
  int _cursor = 0; // rune offset
  List<String> _history;
  int _histAt = -1;
  String _draft = '';

  String text() => _text;
  List<String> history() => _history;

  /// Replace the text; the cursor goes to the end.
  Field set(String text) {
    _text = text;
    _cursor = text.runes.length;
    _histAt = -1;
    return this;
  }

  /// Return the text, push it to the history, and clear.
  String submit() {
    final t = _text;
    if (t.isNotEmpty) _history = List<String>.unmodifiable([t, ..._history]);
    _text = '';
    _cursor = 0;
    _histAt = -1;
    return t;
  }
}

/// A scroll view's offset. `follow` keeps the view pinned to the end as
/// content grows; scrolling up unpins, `end` re-pins.
final class Scroll {
  // ignore: prefer_initializing_formals – the public argument stays `follow`.
  Scroll({bool follow = true}) : _follow = follow;

  final bool _follow;
  var _off = 0;
  var _pinned = true;
}

/// The app handle handed to `screen` and bindings.
final class App<S> {
  App._(this._s);

  final _Session<S> _s;

  /// The current state object.
  S state() => _s._state;

  /// Switch state; the next redraw calls `screen` with it.
  void go(S state) => _s._go(state);

  /// A status-row message until the next `say` or error.
  void say(String message) => _s._say(message);

  /// Commit a drawing above the live area into the scrollback (inline mode).
  /// In full screen this throws [StateError].
  void print(void Function(Region r) draw) => _s._print(draw);

  /// A desktop notification (OSC 9/777, bell fallback). TODO(1b): no-op
  /// while the terminal has focus (needs focus events).
  void notify(String message) => _s._notify(message);

  /// Copy text to the clipboard (OSC 52).
  void copy(String text) => _s._copy(text);

  /// Return the state from [Tui.run] (pending handlers keep running).
  void quit() => _s._quit();
}

/// One screen description: a draw function plus title, status mode line and
/// key bindings.
final class Screen {
  // ignore: prefer_initializing_formals – the public arguments keep their names.
  Screen(void Function(Region r) draw,
      {String? title, String? status, Map<String, Bind> keys = const {}})
      : _draw = draw,
        // ignore: prefer_initializing_formals
        _title = title,
        // ignore: prefer_initializing_formals
        _status = status,
        // ignore: prefer_initializing_formals
        _keys = keys;

  final void Function(Region r) _draw;
  final String? _title;
  final String? _status;
  final Map<String, Bind> _keys;
}

/// Entry point: run a state-driven app.
abstract final class Tui {
  static bool _active = false;

  /// Own the loop: redraw on every input event, handler settle, `go`/`say`,
  /// resize, and at most every 80 ms while work is pending or a spinner is
  /// visible. Returns the state passed to [App.quit]. A second [run] while
  /// one is active throws [StateError]. Throws [StdoutException] when stdout
  /// is not a terminal.
  static Future<S> run<S>(S state,
      Screen Function(S state, App<S> app) screen,
      {bool fullscreen = true, Color accent = Color.orange}) {
    if (_active) throw StateError('Tui.run is already active');
    if (!fullscreen) {
      throw UnimplementedError('inline mode follows in Step 1b');
    }
    _active = true;
    final session = _Session<S>(state, screen,
        out: io.stdout.write,
        size: () => (io.stdout.terminalColumns, io.stdout.terminalLines),
        accent: accent,
        fullscreen: fullscreen);
    return session._run().whenComplete(() => _active = false);
  }
}

/// A drawable rectangle. Every method draws or splits below the cursor and
/// clips to the region; layout methods return the new area, widgets return
/// the receiver.
final class Region {
  // ignore: prefer_initializing_formals – internal construction stays positional.
  Region._(this._s, this._grid, this._gx, this._gy, this._w, this._h,
      {bool grow = false, _ScrollCtx? scroll, _Popup? pop})
      // ignore: prefer_initializing_formals
      : _grow = grow,
        // ignore: prefer_initializing_formals
        _scroll = scroll,
        // ignore: prefer_initializing_formals
        _pop = pop;

  final _Session<dynamic> _s;
  final List<List<_Cell>> _grid;
  final int _gx;
  final int _gy;
  final int _w;
  final int _h;
  final bool _grow;
  final _ScrollCtx? _scroll;
  final _Popup? _pop;
  var _cursor = 0;

  int width() => _w;
  int height() => _h;

  /// True when the pointer is inside this region.
  bool hovered() {
    final m = _s._mouse;
    if (m == null) return false;
    return _toLocal(m.$1, m.$2) != null;
  }

  /// True when the session focus belongs to a focusable drawn in this region.
  bool focused() => _s._focusIn(_gx, _gy, _w, _h);

  /// Draw text with wrapping (`\n` breaks, `\t` expands, controls show as
  /// `�`, overrun ends with `…`). `link` makes an OSC 8 hyperlink.
  Region write(String text,
      {Color? color,
      Color? background,
      Set<Style> style = const {},
      String? link}) {
    final st = _s._pack(color, background, style);
    final parts = text.split('\n');
    final lines = parts.isNotEmpty && parts.last.isEmpty
        ? parts.sublist(0, parts.length - 1)
        : parts;
    var overflow = false;
    for (final line in lines) {
      if (_cursor < _h || _grow) {
        _writeLine(_gy + _cursor, _gx, _gx + _w, line, st, link);
      } else {
        overflow = true;
      }
      _cursor++;
    }
    if (overflow && _h > 0 && _w > 0 && !_grow) {
      _put(_gy + _h - 1, _gx + _w - 1, '…', 1, st, link);
    }
    return this;
  }

  /// TODO(1b): markdown rendering (blocks, inline, highlight, cache).
  Region markdown(String source) {
    throw UnimplementedError('markdown follows in Step 1b');
  }

  /// TODO(1b): line diff (Myers, hunks, word-bright pairs).
  Region diff(String before, String after) {
    throw UnimplementedError('diff follows in Step 1b');
  }

  /// Border the rest of the region with [title]; return the inside.
  Region box(String title) {
    final top = _gy + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    if (_w <= 0 || h <= 0) return _sub(_gx, top, 0, 0);
    final ascii = _s._caps.ascii;
    final (horiz, vert, tl, tr, bl, br) = ascii
        ? ('-', '|', '+', '+', '+', '+')
        : ('─', '│', '┌', '┐', '└', '┘');
    final right = _gx + _w - 1;
    final bottom = top + h - 1;
    for (var x = _gx; x <= right; x++) {
      _put(top, x, horiz, 1, 0, null);
      _put(bottom, x, horiz, 1, 0, null);
    }
    for (var y = top; y <= bottom; y++) {
      _put(y, _gx, vert, 1, 0, null);
      _put(y, right, vert, 1, 0, null);
    }
    _put(top, _gx, tl, 1, 0, null);
    _put(top, right, tr, 1, 0, null);
    _put(bottom, _gx, bl, 1, 0, null);
    _put(bottom, right, br, 1, 0, null);
    if (title.isNotEmpty && _w > 5) {
      _writeLine(top, _gx + 2, right, ' $title ', 0, null);
    }
    if (_w < 3 || h < 3) return _sub(_gx, top, 0, 0);
    return _sub(_gx + 1, top + 1, _w - 2, h - 2);
  }

  /// Split below the cursor into rows; >0 fixed, 0 shares the rest.
  List<Region> rows(List<int> sizes) => _split(sizes, horizontal: true);

  /// Split below the cursor into columns.
  List<Region> cols(List<int> sizes) => _split(sizes, horizontal: false);

  /// A tab row; returns the area below it.
  Region tabs<T>(Pick<T> tabs, String Function(T tab) label) {
    final y = _gy + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    if (h <= 0 || _w <= 0 || tabs.items().isEmpty) {
      return _sub(_gx, y, _w, math.max(0, h - 1));
    }
    final order = _s._order++;
    _reg(tabs, _gx, y, _w, 1, order, (ev) {
      if (ev is! _KeyEv || !_sameId(_s._focusId, tabs)) return false;
      if (ev.name == 'left' || ev.name == 'right') {
        tabs.select(tabs.index() + (ev.name == 'left' ? -1 : 1));
        _s._dirtyAndWake();
        return true;
      }
      return false;
    });
    final items = tabs.items();
    var x = _gx;
    for (var k = 0; k < items.length && x < _gx + _w; k++) {
      final t = ' ${label(items[k])} ';
      final sel = k == tabs.index();
      final st = sel
          ? _s._pack(null, _s.accent, {Style.bold})
          : _s._pack(null, null, {});
      x = _writeLine(y, x, _gx + _w, t, st, null);
    }
    _s._clickCbs[tabs] = (cx, cy) {
      var x = _gx;
      for (var k = 0; k < items.length; k++) {
        final w = term.displayWidth(' ${label(items[k])} ');
        if (cx >= x && cx < x + w) {
          tabs.select(k);
          _s._setFocus(tabs);
          _s._dirtyAndWake();
          return;
        }
        x += w;
      }
    };
    return _sub(_gx, y + 1, _w, math.max(0, h - 1));
  }

  /// A scroll viewport over unbounded content.
  Region scroll(Scroll scroll) {
    final y = _gy + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    final viewH = math.max(0, h);
    final buf = <List<_Cell>>[
      for (var k = 0; k < viewH; k++) List.filled(_w, _Cell.blank)
    ];
    final ctx = _ScrollCtx(scroll, buf, _gx, y, _w, viewH, _s._order++);
    _s._scrolls.add(ctx);
    _reg(scroll, _gx, y, _w, viewH, ctx.order, (ev) {
      if (ev is _WheelEv) {
        _scrollBy(scroll, ctx, ev.dir * 3);
        _s._setFocus(scroll);
        return true;
      }
      if (ev is! _KeyEv || !_sameId(_s._focusId, scroll)) return false;
      switch (ev.name) {
        case 'pageup':
          _scrollBy(scroll, ctx, -viewH);
          return true;
        case 'pagedown':
          _scrollBy(scroll, ctx, viewH);
          return true;
        case 'home':
          scroll._off = 0;
          scroll._pinned = false;
          _s._dirtyAndWake();
          return true;
        case 'end':
          scroll._pinned = true;
          _s._dirtyAndWake();
          return true;
      }
      return false;
    });
    return Region._(_s, buf, 0, 0, _w, viewH, grow: true, scroll: ctx);
  }

  void _scrollBy(Scroll scroll, _ScrollCtx ctx, int d) {
    final contentH = math.max(ctx.buf.length, 1);
    final maxOff = math.max(0, contentH - ctx.viewH);
    scroll._off = (scroll._off + d).clamp(0, maxOff);
    scroll._pinned = false;
    _s._dirtyAndWake();
  }

  /// A centered modal; drawn last.
  Region popup(String title, {int width = 40, int height = 10}) {
    final w = math.min(width, _s._w);
    final h = math.min(height, _s._h);
    final x = (_s._w - w) ~/ 2;
    final y = (_s._h - h) ~/ 2;
    final buf = <List<_Cell>>[
      for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)
    ];
    final pop = _Popup(x, y, w, h, buf);
    _s._popups.add(pop);
    final ascii = _s._caps.ascii;
    final (hz, vt, tl, tr, bl, br) = ascii
        ? ('-', '|', '+', '+', '+', '+')
        : ('─', '│', '┌', '┐', '└', '┘');
    for (var cx = 0; cx < w; cx++) {
      _rawPut(buf, 0, cx, hz, 0, null);
      _rawPut(buf, h - 1, cx, hz, 0, null);
    }
    for (var ry = 0; ry < h; ry++) {
      _rawPut(buf, ry, 0, vt, 0, null);
      _rawPut(buf, ry, w - 1, vt, 0, null);
    }
    _rawPut(buf, 0, 0, tl, 0, null);
    _rawPut(buf, 0, w - 1, tr, 0, null);
    _rawPut(buf, h - 1, 0, bl, 0, null);
    _rawPut(buf, h - 1, w - 1, br, 0, null);
    if (title.isNotEmpty && w > 5) {
      _rawWrite(buf, 0, 2, w - 1, ' $title ', 0, null);
    }
    return Region._(_s, buf, 1, 1, math.max(0, w - 2), math.max(0, h - 2),
        pop: pop);
  }

  /// Bind events when focused (keys) or under the pointer (mouse).
  Region on(Map<String, Bind> events) {
    _reg(events, _gx, _gy + _cursor, _w, _h - _cursor, _s._order++, null,
        onMap: events);
    return this;
  }

  /// A selectable list.
  Region list<T>(Pick<T> pick, String Function(T item) label,
      {String empty = ''}) {
    final y = _gy + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    _drawList(pick, label, empty, y, h);
    return this;
  }

  /// A selectable table.
  Region table<T>(Pick<T> pick, List<String> Function(T item) cells,
      {List<String>? header, String empty = ''}) {
    final y = _gy + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    _drawList(pick, (t) => '', empty, y, h, cells: cells, header: header);
    return this;
  }

  void _drawList<T>(Pick<T> pick, String Function(T item) label, String empty,
      int y, int h,
      {List<String> Function(T item)? cells, List<String>? header}) {
    final order = _s._order++;
    final items = pick.items();
    final headRows = header != null ? 1 : 0;
    final viewH = h - headRows;
    var start = _s._listStart(pick, items.length, math.max(0, viewH));
    if (items.isEmpty || h <= 0 || _w <= 0) {
      if (empty.isNotEmpty && h > 0 && _w > 0) {
        _writeLine(y, _gx, _gx + _w, empty,
            _s._pack(null, null, {Style.dim}), null);
      }
      _reg(pick, _gx, y, _w, math.max(0, h), order, (_) => false);
      return;
    }
    _reg(pick, _gx, y, _w, h, order, (ev) {
      if (ev is _ClickEv) {
        final lr = ev.y;
        if (header != null) {
          if (lr == y) return false;
          pick.select(start + lr - y - 1);
        } else {
          pick.select(start + lr - y);
        }
        _s._setFocus(pick);
        _s._dirtyAndWake();
        return true;
      }
      if (ev is _WheelEv) {
        pick.select(pick.index() + ev.dir);
        _s._setFocus(pick);
        _s._dirtyAndWake();
        return true;
      }
      if (ev is! _KeyEv || !_sameId(_s._focusId, pick)) return false;
      final n = items.length;
      var sel = pick.index();
      switch (ev.name) {
        case 'up':
          sel--;
        case 'down':
          sel++;
        case 'pageup':
          sel -= viewH;
        case 'pagedown':
          sel += viewH;
        case 'home':
          sel = 0;
        case 'end':
          sel = n - 1;
        default:
          return false;
      }
      pick.select(sel);
      _s._dirtyAndWake();
      return true;
    });
    var row = y;
    if (header != null && h > 0) {
      _writeLine(row++, _gx, _gx + _w, _rowText(header),
          _s._pack(null, null, {Style.bold}), null);
    }
    final sel = pick.index();
    final focused = _sameId(_s._focusId, pick);
    for (var r = 0; r < viewH && start + r < items.length; r++) {
      final idx = start + r;
      final isSel = idx == sel;
      final st = isSel
          ? (focused
              ? _s._pack(null, _s.accent, {Style.bold})
              : _s._pack(null, null, {Style.reverse, Style.dim}))
          : 0;
      final text = cells == null
          ? label(items[idx])
          : _rowText(cells(items[idx]));
      if (st != 0) {
        for (var x = _gx; x < _gx + _w; x++) {
          _put(row, x, ' ', 1, st, null);
        }
      }
      _writeLine(row, _gx, _gx + _w, text, st, null);
      row++;
    }
    if (sel < start) start = sel;
    if (sel >= start + viewH) start = sel - viewH + 1;
    _s._listStartSave(pick, start);
  }

  String _rowText(List<String> cells) {
    if (cells.isEmpty) return '';
    if (cells.length == 1) return cells[0];
    final per = _w ~/ cells.length;
    final buf = StringBuffer();
    for (var k = 0; k < cells.length; k++) {
      if (k > 0) buf.write('  ');
      buf.write(term.truncateWidth(cells[k], math.max(1, per - 2)));
    }
    return buf.toString();
  }

  /// A text editor.
  Region input(Field field,
      {String hint = '',
      int lines = 1,
      FutureOr<List<String>> Function(String word)? suggest}) {
    if (lines != 1 || suggest != null) {
      throw UnimplementedError('input lines/suggest follow in Step 1b');
    }
    final y = _gy + _cursor;
    _cursor++;
    final order = _s._order++;
    _reg(field, _gx, y, _w, 1, order, (ev) => _inputKey(field, ev));
    if (_cursor > _h || _w <= 0 || y >= _gy + _h) return this;
    final shown = field._text.isEmpty ? hint : _tailText(field, _w - 1);
    final hintStyle =
        field._text.isEmpty ? _s._pack(null, null, {Style.dim}) : 0;
    final end = _writeLine(y, _gx, _gx + _w - 1, shown, hintStyle, null);
    _put(y, end, ' ', 1, _s._pack(null, null, {Style.reverse}), null);
    if (_sameId(_s._focusId, field)) {
      _placeCursorAt(y, _cursorCol(field));
    }
    return this;
  }

  void _placeCursorAt(int row, int col) {
    final p = _toScreen(row, col);
    if (p == null) {
      _s._cursorPos = null;
      return;
    }
    if (p.$1 < 0 ||
        p.$1 >= _s._w ||
        p.$2 < 0 ||
        p.$2 >= _s._h) {
      _s._cursorPos = null;
      return;
    }
    _s._cursorPos = p;
  }

  int _cursorCol(Field field) {
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    final tail = _tailText(field, _w - 1);
    final tailRunes = tail.runes.length;
    final dropped = runes.length - tailRunes;
    final rel = (at - math.max(0, dropped)).clamp(0, tailRunes);
    var col = _gx;
    var k = 0;
    for (final r in tail.runes) {
      if (k >= rel) break;
      col += term.isZeroWidth(r) ? 0 : term.cellWidth(r);
      k++;
    }
    return col;
  }

  String _tailText(Field field, int cells) {
    final runes = field._text.runes.toList();
    var used = 0;
    var i = runes.length;
    while (i > 0) {
      final r = runes[i - 1];
      final w = term.isZeroWidth(r) ? 0 : term.cellWidth(r);
      if (used + w > cells) break;
      used += w;
      i--;
    }
    while (i < runes.length && term.isZeroWidth(runes[i])) {
      i++;
    }
    return String.fromCharCodes(runes.sublist(i));
  }

  bool _inputKey(Field field, _Ev ev) {
    if (ev is _ClickEv) {
      _s._setFocus(field);
      _s._dirtyAndWake();
      return true;
    }
    if (ev is _WheelEv) return false;
    if (ev is! _KeyEv) return false;
    if (ev.text != null) {
      _s._setFocus(field);
      _insertText(field, ev.paste ? _oneLine(ev.text!) : ev.text!);
      _s._dirtyAndWake();
      return true;
    }
    if (!_sameId(_s._focusId, field)) return false;
    final runes = field._text.runes.toList();
    switch (ev.name) {
      case 'backspace':
        _dropGrapheme(field, -1);
        return true;
      case 'delete':
        _dropGrapheme(field, 1);
        return true;
      case 'left':
        field._cursor = _prevCluster(runes, field._cursor);
        _s._dirtyAndWake();
        return true;
      case 'right':
        field._cursor = _nextCluster(runes, field._cursor);
        _s._dirtyAndWake();
        return true;
      case 'home':
      case 'ctrl+a':
        field._cursor = 0;
        _s._dirtyAndWake();
        return true;
      case 'end':
      case 'ctrl+e':
        field._cursor = runes.length;
        _s._dirtyAndWake();
        return true;
      case 'ctrl+w':
      case 'alt+backspace':
        _deleteWord(field, -1);
        return true;
      case 'ctrl+u':
        runes.removeRange(0, field._cursor.clamp(0, runes.length));
        field._text = String.fromCharCodes(runes);
        field._cursor = 0;
        _s._dirtyAndWake();
        return true;
      case 'ctrl+k':
        runes.removeRange(
            field._cursor.clamp(0, runes.length), runes.length);
        field._text = String.fromCharCodes(runes);
        _s._dirtyAndWake();
        return true;
      case 'up':
      case 'down':
        if (field._history.isEmpty) return false;
        if (field._histAt < 0) {
          if (ev.name == 'down') return false;
          field._draft = field._text;
          field._histAt = 0;
        } else {
          field._histAt += ev.name == 'up' ? 1 : -1;
        }
        if (field._histAt < 0) {
          field._histAt = -1;
          field._text = field._draft;
        } else if (field._histAt >= field._history.length) {
          field._histAt = field._history.length - 1;
          field._text = field._history[field._histAt];
        } else {
          field._text = field._history[field._histAt];
        }
        field._cursor = field._text.runes.length;
        _s._dirtyAndWake();
        return true;
      default:
        if (ev.name.endsWith('left')) {
          field._cursor = _prevWord(runes, field._cursor);
          _s._dirtyAndWake();
          return true;
        }
        if (ev.name.endsWith('right')) {
          field._cursor = _nextWord(runes, field._cursor);
          _s._dirtyAndWake();
          return true;
        }
        return false;
    }
  }

  void _insertText(Field field, String s) {
    field._histAt = -1;
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    runes.insertAll(at, s.runes);
    field._text = String.fromCharCodes(runes);
    field._cursor = at + s.runes.length;
  }

  void _dropGrapheme(Field field, int dir) {
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    if (dir < 0) {
      final start = _prevCluster(runes, at);
      runes.removeRange(start, at);
      field._cursor = start;
    } else {
      final end = _nextCluster(runes, at);
      runes.removeRange(at, end);
    }
    field._text = String.fromCharCodes(runes);
    _s._dirtyAndWake();
  }

  void _deleteWord(Field field, int dir) {
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    final to = dir < 0 ? _prevWord(runes, at) : _nextWord(runes, at);
    runes.removeRange(math.min(at, to), math.max(at, to));
    field._text = String.fromCharCodes(runes);
    field._cursor = math.min(at, to);
    _s._dirtyAndWake();
  }

  static String _oneLine(String text) => text
      .replaceAll('\r\n', ' ')
      .replaceAll(RegExp('[\r\n\t]'), ' ')
      .replaceAll(RegExp('[\x00-\x1f\x7f]'), '');

  /// A button. Runs [action] on click or on enter/space while focused.
  Region button(String label, FutureOr<void> Function() action) {
    final y = _gy + _cursor;
    _cursor++;
    if (y >= _gy + _h || _w <= 0) return this;
    final order = _s._order++;
    final focused = _sameId(_s._focusId, label);
    _reg(label, _gx, y, _w, 1, order, (ev) {
      if (ev is _ClickEv) {
        _s._setFocus(label);
        _s._invoke(action);
        return true;
      }
      if (ev is! _KeyEv || !_sameId(_s._focusId, label)) return false;
      if (ev.name == 'enter' || ev.name == 'space') {
        _s._invoke(action);
        return true;
      }
      return false;
    });
    _writeLine(y, _gx, _gx + _w, '[ $label ]',
        _s._pack(null, null, focused ? {Style.reverse} : {}), null);
    return this;
  }

  /// A static progress snapshot laid out like `Console.bar`.
  Region bar(int done, int? total, {String? label}) {
    final lab = label == null ? '' : '$label ';
    final frac = total == null || total <= 0
        ? 0.0
        : (done / total).clamp(0.0, 1.0);
    final counts = total != null && total > 0 ? '$done/$total' : '$done';
    var width = 20;
    while (width > 10) {
      if (term.displayWidth('$lab${'_' * width}  $counts') <= _w) break;
      width--;
    }
    final filled = (frac * width).round().clamp(0, width);
    final glyphs = _s._caps.ascii
        ? ('#' * filled + '-' * (width - filled))
        : ('█' * filled + '░' * (width - filled));
    write('$lab$glyphs  $counts');
    return this;
  }

  /// A static spinner snapshot; the frame advances while visible.
  Region spin(String label) {
    _s._spinVisible = true;
    final frames = _s._caps.ascii
        ? const ['-', '\\', '|', '/']
        : const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    write('${frames[_s._spinTick % frames.length]} $label');
    return this;
  }

  /// TODO(1b): picture (half-block cells, scale down to fit).
  Region picture(Image image) {
    throw UnimplementedError('picture follows in Step 1b');
  }

  // --- coordinate mapping (scroll viewport / popup buffer) -----------------

  /// Map region-grid coords to screen coords, or null when scrolled out.
  (int, int, int, int)? _toScreenRect(int x, int y, int w, int h) {
    var sx = x, sy = y, sw = w, sh = h;
    final sc = _scroll;
    if (sc != null) {
      sx = sc.gx + (x - 0);
      sy = sc.gy + (y - sc.scroll._off);
      final x0 = math.max(sx, sc.gx), x1 = math.min(sx + sw, sc.gx + sc.w);
      final y0 = math.max(sy, sc.gy), y1 = math.min(sy + sh, sc.gy + sc.viewH);
      if (x1 <= x0 || y1 <= y0) return null;
      sx = x0;
      sy = y0;
      sw = x1 - x0;
      sh = y1 - y0;
    }
    final pop = _pop;
    if (pop != null) {
      sx += pop.x;
      sy += pop.y;
    }
    return (sx, sy, sw, sh);
  }

  /// Map a screen point to region-grid coords, or null when outside.
  (int, int)? _toLocal(int sx, int sy) {
    var x = sx, y = sy;
    final pop = _pop;
    if (pop != null) {
      x -= pop.x;
      y -= pop.y;
      if (x < _gx || x >= _gx + _w || y < _gy || y >= _gy + _h) return null;
      return (x, y);
    }
    final sc = _scroll;
    if (sc != null) {
      if (x < sc.gx || x >= sc.gx + sc.w) return null;
      if (y < sc.gy || y >= sc.gy + sc.viewH) return null;
      return (x - sc.gx, y - sc.gy + sc.scroll._off);
    }
    if (x < _gx || x >= _gx + _w || y < _gy || y >= _gy + _h) return null;
    return (x, y);
  }

  /// Map a screen point to a cursor position check for scroll content.
  (int, int)? _toScreen(int row, int col) {
    var sx = col, sy = row;
    final sc = _scroll;
    if (sc != null) {
      sx = sc.gx + (col - 0);
      sy = sc.gy + (row - sc.scroll._off);
      if (sx < sc.gx ||
          sx >= sc.gx + sc.w ||
          sy < sc.gy ||
          sy >= sc.gy + sc.viewH) {
        return null;
      }
    }
    final pop = _pop;
    if (pop != null) {
      sx += pop.x;
      sy += pop.y;
    }
    return (sx, sy);
  }

  /// Register a focusable, mapping scroll/popup coords to the screen.
  void _reg(Object id, int x, int y, int w, int h, int order,
      bool Function(_Ev ev)? tryKey,
      {Map<String, Bind>? onMap}) {
    final r = _toScreenRect(x, y, w, h);
    if (r == null) return;
    bool Function(_Ev)? wrapped = tryKey;
    if (wrapped != null && (_scroll != null || _pop != null)) {
      final inner = tryKey!;
      wrapped = (ev) {
        if (ev is _ClickEv) {
          final p = _toLocal(ev.x, ev.y);
          if (p == null) return false;
          return inner(_ClickEv(p.$1, p.$2, ev.kind));
        }
        if (ev is _WheelEv) {
          final p = _toLocal(ev.x, ev.y);
          if (p == null) return false;
          return inner(_WheelEv(p.$1, p.$2, ev.dir));
        }
        return inner(ev);
      };
    }
    _s._addFocusable(id, r.$1, r.$2, r.$3, r.$4, order, wrapped, onMap: onMap);
  }

  Region _sub(int x, int y, int w, int h) =>
      Region._(_s, _grid, x, y, w, h, grow: _grow, scroll: _scroll, pop: _pop);

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
    final end = horizontal ? _gy + _h : _gx + _w;
    var off = horizontal ? _gy + _cursor : _gx;
    final out = <Region>[];
    for (final s in sizes) {
      var size = s > 0 ? s : each + (extra-- > 0 ? 1 : 0);
      size = math.min(size, math.max(0, end - off));
      out.add(horizontal
          ? Region._(_s, _grid, _gx, off, _w, size,
              grow: _grow, scroll: _scroll, pop: _pop)
          : Region._(_s, _grid, off, _gy + _cursor, size, _h - _cursor,
              grow: _grow, scroll: _scroll, pop: _pop));
      off += size;
    }
    _cursor = _h;
    return out;
  }

  int _writeLine(
      int row, int from, int end, String text, int style, String? link) {
    _ensureRow(row);
    if (row < _gy || (!_grow && row >= _gy + _h)) return from;
    final cap = _grid == _s._grid ? _s._w : _grid[row - _gy].length;
    end = math.min(end, _gx + _w);
    if (_grid == _s._grid) end = math.min(end, cap);
    final runes = text.runes.toList();
    var col = from;
    var i = 0;
    while (i < runes.length && col < end) {
      final rune = runes[i++];
      if (rune == 0x1b && i < runes.length && runes[i] == 0x5b) {
        i++;
        while (i < runes.length && (runes[i] < 0x40 || runes[i] > 0x7e)) {
          i++;
        }
        i++;
        continue;
      }
      if (rune == 0x09) {
        final next = col + 8 - (col - _gx) % 8;
        while (col < next && col < end) {
          _put(row, col++, ' ', 1, style, link);
        }
        continue;
      }
      if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
        _put(row, col++, '�', 1, style, link);
        continue;
      }
      if (term.isZeroWidth(rune)) continue;
      final cluster = StringBuffer()..writeCharCode(rune);
      while (i < runes.length && term.isZeroWidth(runes[i])) {
        cluster.writeCharCode(runes[i++]);
      }
      final w = term.cellWidth(rune);
      if (col + w > end) {
        _put(row, col++, ' ', 1, style, link);
        break;
      }
      _put(row, col, cluster.toString(), w, style, link);
      col += w;
    }
    return col;
  }

  void _ensureRow(int row) {
    if (!_grow) return;
    final local = row - _gy;
    while (_grid.length <= local) {
      _grid.add(List.filled(_w, _Cell.blank));
    }
  }

  void _put(int row, int col, String ch, int width, int style, String? link) {
    final grid = _grid;
    final gr = _grow ? row - _gy : row;
    if (gr < 0) return;
    if (_grow) _ensureRow(row);
    if (gr >= grid.length) return;
    final cells = grid[gr];
    final gc = _grow ? col - _gx : col;
    if (gc < 0 || gc + width > cells.length) return;
    if (!_grow && (row < _gy || row >= _gy + _h)) return;
    if (cells[gc].width == 0 && gc > 0) cells[gc - 1] = _Cell.blank;
    final after = gc + width;
    if (after < cells.length && cells[after].width == 0) {
      cells[after] = _Cell.blank;
    }
    cells[gc] = _Cell(ch, style, width, link: link);
    if (width == 2) cells[gc + 1] = _Cell('', style, 0, link: link);
  }

  void _rawPut(List<List<_Cell>> grid, int row, int col, String ch, int style,
      String? link) {
    if (row < 0 || row >= grid.length) return;
    if (col < 0 || col >= grid[row].length) return;
    grid[row][col] = _Cell(ch, style, 1, link: link);
  }

  void _rawWrite(List<List<_Cell>> grid, int row, int from, int end,
      String text, int style, String? link) {
    var col = from;
    for (final r in text.runes) {
      if (col >= end || col >= grid[row].length) break;
      if (r < 0x20 || r == 0x7f) continue;
      grid[row][col++] = _Cell(String.fromCharCode(r), style, 1, link: link);
    }
  }
}

/// Grapheme helpers shared by [Region] input editing.
int _prevCluster(List<int> runes, int at) {
  var end = at.clamp(0, runes.length);
  if (end <= 0) return 0;
  while (true) {
    while (end > 0 &&
        term.isZeroWidth(runes[end - 1]) &&
        runes[end - 1] != 0x200D) {
      end--;
    }
    if (end <= 0) return 0;
    end--;
    if (end > 0 && runes[end - 1] == 0x200D) {
      end--;
      continue;
    }
    return end;
  }
}

int _nextCluster(List<int> runes, int at) {
  var i = at.clamp(0, runes.length);
  if (i >= runes.length) return runes.length;
  i++;
  while (i < runes.length &&
      term.isZeroWidth(runes[i]) &&
      runes[i] != 0x200D) {
    i++;
  }
  while (i < runes.length && runes[i] == 0x200D) {
    i++;
    if (i < runes.length) i++;
    while (i < runes.length &&
        term.isZeroWidth(runes[i]) &&
        runes[i] != 0x200D) {
      i++;
    }
  }
  return i;
}

bool _isWordChar(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x41 && r <= 0x5A) ||
    r == 0x5F ||
    (r >= 0x61 && r <= 0x7A);

int _prevWord(List<int> runes, int at) {
  var i = at.clamp(0, runes.length);
  while (i > 0 && !_isWordChar(runes[i - 1])) {
    i = _prevCluster(runes, i);
  }
  while (i > 0 && _isWordChar(runes[i - 1])) {
    i = _prevCluster(runes, i);
  }
  return i;
}

int _nextWord(List<int> runes, int at) {
  var i = at.clamp(0, runes.length);
  while (i < runes.length && !_isWordChar(runes[i])) {
    i = _nextCluster(runes, i);
  }
  while (i < runes.length && _isWordChar(runes[i])) {
    i = _nextCluster(runes, i);
  }
  return i;
}

/// Scroll viewport bookkeeping.
final class _ScrollCtx {
  _ScrollCtx(this.scroll, this.buf, this.gx, this.gy, this.w, this.viewH,
      this.order);

  final Scroll scroll;
  final List<List<_Cell>> buf;
  final int gx;
  final int gy;
  final int w;
  final int viewH;
  final int order;
}

/// A centered popup buffer, composited after the main draw.
final class _Popup {
  _Popup(this.x, this.y, this.w, this.h, this.buf);

  final int x;
  final int y;
  final int w;
  final int h;
  final List<List<_Cell>> buf;
}

/// One focusable thing drawn this frame.
final class _F {
  _F(this.id, this.x, this.y, this.w, this.h, this.order, this.tryKey,
      {this.onMap});

  final Object id;
  final int x;
  final int y;
  final int w;
  final int h;
  final int order;
  final bool Function(_Ev ev)? tryKey;
  final Map<String, Bind>? onMap;
}

/// A routed input event.
sealed class _Ev {}

final class _KeyEv extends _Ev {
  _KeyEv(this.name, {this.text, this.paste = false});

  final String name;
  final String? text;
  final bool paste;
}

final class _ClickEv extends _Ev {
  _ClickEv(this.x, this.y, this.kind);

  final int x;
  final int y;
  final String kind;
}

final class _WheelEv extends _Ev {
  _WheelEv(this.x, this.y, this.dir);

  final int x;
  final int y;
  final int dir;
}

/// The live session behind [Tui.run] and the test harness.
final class _Session<S> {
  _Session(this._state, this._screenFn,
      {required this.out,
      required this.size,
      required this.accent,
      required this.fullscreen});

  S _state;
  final Screen Function(S state, App<S> app) _screenFn;
  final void Function(String) out;
  final (int, int) Function() size;
  final Color accent;
  final bool fullscreen;
  late final App<S> app = App<S>._(this);

  var _w = 80;
  var _h = 24;
  List<List<_Cell>> _grid = const [];
  List<List<_Cell>>? _shown;
  var _repaint = true;

  final _pending = <int>[];
  final _signals = <String>[];
  int? _heldSince;
  var _heldLength = 0;

  (int, int)? _mouse;
  (int, int)? _lastClick;
  int _lastClickAt = 0;
  Object? _focusId;
  final _focusSeq = <Object, int>{};
  var _seq = 0;
  final _focusables = <_F>[];
  var _order = 0;
  final _listStarts = <Object, int>{};

  String? _sayMsg;
  String? _error;
  String? _statusLine;
  Map<String, Bind> _keys = const {};
  String? _title;
  Object? _shownState;

  final _popups = <_Popup>[];
  final _scrolls = <_ScrollCtx>[];
  final _clickCbs = <Object, void Function(int x, int y)>{};
  var _spinVisible = false;
  var _spinTick = 0;
  (int, int)? _cursorPos;
  var _caps = _Caps.fallback;
  bool _testMode = false;

  var _dirty = true;
  var _quitFlag = false;
  Object? _fatal;
  StackTrace? _fatalStack;
  var _activeH = 0;
  var _done = false;
  Completer<void>? _waker;
  var _lastPaint = 0;
  final _subs = <StreamSubscription<Object?>>[];
  term.TermModes? _modes;
  var _entered = false;
  Zone? _zone;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  ZoneSpecification _spec() => ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, f) {
          _dirtyAndWake();
          parent.scheduleMicrotask(zone, f);
        },
        createTimer: (self, parent, zone, duration, f) {
          _dirtyAndWake();
          return parent.createTimer(zone, duration, () {
            _dirtyAndWake();
            f();
          });
        },
        createPeriodicTimer: (self, parent, zone, period, f) {
          _dirtyAndWake();
          return parent.createPeriodicTimer(zone, period, (timer) {
            _dirtyAndWake();
            f(timer);
          });
        },
        handleUncaughtError: (self, parent, zone, e, st) {
          if (e is Exception) {
            _failStatus(e);
          } else {
            _fatal ??= e;
            _fatalStack ??= st;
          }
          _dirtyAndWake();
        },
      );

  Future<T> _zoneRun<T>(Future<T> Function() fn) {
    final z = _zone;
    if (z == null) return fn();
    return z.run(fn);
  }

  Future<void> _settleForTest() async {
    for (var k = 0; k < 200; k++) {
      await Future<void>.delayed(Duration.zero);
      if (_activeH == 0) {
        await Future<void>.delayed(Duration.zero);
        if (_activeH == 0) return;
      }
    }
  }

  // --- run loop ----------------------------------------------------------

  Future<S> _run() async {
    if (!io.stdout.hasTerminal) {
      throw const io.StdoutException('no terminal for the TUI');
    }
    late final S result;
    Object? error;
    StackTrace? stack;
    await runZoned(() async {
      _zone = Zone.current;
      await _enter();
      try {
        await _loop();
        result = _state;
      } catch (e, st) {
        error = e;
        stack = st;
      } finally {
        await _leave();
      }
    }, zoneSpecification: _spec());
    if (error != null) {
      Error.throwWithStackTrace(error!, stack ?? StackTrace.empty);
    }
    return result;
  }

  Future<void> _loop() async {
    _draw();
    _paint();
    while (!_quitFlag) {
      if (_fatal != null) {
        final e = _fatal!;
        final st = _fatalStack ?? StackTrace.empty;
        _fatal = null;
        Error.throwWithStackTrace(e, st);
      }
      final active = _activeH > 0 || _spinVisible;
      _waker ??= Completer<void>();
      final w = _waker!;
      if (active) {
        try {
          await w.future.timeout(const Duration(milliseconds: 80));
        } on TimeoutException {
          _spinTick++;
          _dirty = true;
        }
      } else {
        await w.future;
      }
      if (identical(_waker, w)) _waker = null;
      _pollInput();
      if (_dirty && _now() - _lastPaint >= 16) {
        _draw();
        _paint();
      }
      try {
        final (w2, h2) = size();
        if (w2 != _w || h2 != _h) {
          _w = math.max(1, w2);
          _h = math.max(1, h2);
          _repaint = true;
          _fireLifecycle('resize');
          _dirty = true;
          _draw();
          _paint();
        }
      } catch (_) {}
    }
  }

  void _wake() {
    if (_done) return;
    final w = _waker;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _dirtyAndWake() {
    if (_done) return;
    _dirty = true;
    _wake();
  }

  void _failStatus(Exception e) {
    var first = _firstLine('$e');
    // `Exception('msg')` stringifies as `Exception: msg`; the status shows
    // the message's first line.
    const prefix = 'Exception: ';
    if (first.startsWith(prefix)) first = first.substring(prefix.length);
    _error = '✗ $first';
    _dirtyAndWake();
  }

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    return (i < 0 ? s : s.substring(0, i)).trim();
  }

  // --- state ops ---------------------------------------------------------

  void _go(S state) {
    _state = state;
    _sayMsg = null;
    _dirtyAndWake();
  }

  void _say(String message) {
    _sayMsg = message;
    _dirtyAndWake();
  }

  void _print(void Function(Region r) draw) {
    throw StateError('print needs inline mode');
  }

  void _notify(String message) {
    String esc(String s) => s.replaceAll('\x1b', '').replaceAll('\x07', '');
    out('\x1b]9;${esc(message)}\x07');
    out('\x1b]777;notify;${esc(message)}\x07');
    out('\x07');
  }

  void _copy(String text) {
    final b64 = base64.encode(utf8.encode(text));
    out('\x1b]52;c;$b64\x1b\\');
  }

  void _quit() {
    _quitFlag = true;
    _wake();
  }

  void _setFocus(Object id) {
    if (!_sameId(_focusId, id)) {
      _focusId = id;
      _focusSeq[id] = ++_seq;
    }
  }

  bool _focusIn(int x, int y, int w, int h) {
    final id = _focusId;
    if (id == null) return false;
    for (final f in _focusables) {
      if (_sameId(f.id, id) &&
          f.x < x + w &&
          f.x + f.w > x &&
          f.y < y + h &&
          f.y + f.h > y) {
        return true;
      }
    }
    return false;
  }

  void _addFocusable(Object id, int x, int y, int w, int h, int order,
      bool Function(_Ev ev)? tryKey,
      {Map<String, Bind>? onMap}) {
    _focusables.add(
        _F(id, x, y, w, h, order, tryKey, onMap: onMap));
  }

  int _listStart(Object id, int n, int h) =>
      _listStarts[id]?.clamp(0, math.max(0, n - h)) ?? 0;

  void _listStartSave(Object id, int start) => _listStarts[id] = start;

  final _styleCache = <String, int>{};
  final _styleReverse = <int, (Color?, Color?, int)>{};

  int _pack(Color? fg, Color? bg, Set<Style> style) {
    var bits = 0;
    for (final s in style) {
      bits |= switch (s) {
        Style.bold => 1,
        Style.dim => 2,
        Style.italic => 4,
        Style.underline => 8,
        Style.strike => 16,
        Style.reverse => 32,
      };
    }
    if (fg == null && bg == null && bits == 0) return 0;
    final key = '${fg?._i}:${fg?._rgb}:${bg?._i}:${bg?._rgb}:$bits';
    return _styleCache.putIfAbsent(key, () {
      final id = _styleCache.length + 1;
      _styleReverse[id] = (fg, bg, bits);
      return id;
    });
  }

  (Color?, Color?, int) _unpack(int packed) =>
      packed == 0 ? (null, null, 0) : _styleReverse[packed] ?? (null, null, 0);

  // --- input -------------------------------------------------------------

  void _pollInput() {
    _decode();
    for (final name in _signals) {
      _routeKey(name);
    }
    _signals.clear();
    if (_pending.isEmpty) {
      _heldSince = null;
      return;
    }
    final now = _now();
    if (_heldSince == null || _pending.length != _heldLength) {
      _heldSince = now;
      _heldLength = _pending.length;
      return;
    }
    final waited = now - _heldSince!;
    final maybeCsi = _pending.length >= 2 &&
        _pending[0] == 0x1b &&
        (_pending[1] == 0x5b || _pending[1] == 0x4f);
    if (maybeCsi) {
      if (waited < 1000) return;
      _pending.clear();
      _heldSince = null;
      return;
    }
    if (_pending.length <= 2 && waited >= 30) {
      if (_pending.length == 1 || _pending[1] == 0x1b) {
        _routeKey('escape');
      } else if (_pending[1] < 0x80) {
        _routeKey('alt+${String.fromCharCode(_pending[1])}');
      }
      _pending.clear();
      _heldSince = null;
      return;
    }
    if (waited < 1000) return;
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
          _routeKey(name);
        case term.TermType(:final text, :final paste):
          _routeText(text, paste);
        case term.TermClick(:final x, :final y):
          _mouse = (x, y);
          _clickAt('click', x, y);
        case term.TermHover(:final x, :final y):
          _mouse = (x, y);
          _dirtyAndWake();
      }
    }
  }

  void _clickAt(String kind, int x, int y) {
    if (kind == 'click') {
      final now = _now();
      final last = _lastClick;
      if (last != null &&
          last.$1 == x &&
          last.$2 == y &&
          now - _lastClickAt < 400) {
        _lastClick = null;
        _routeMouse('doubleclick', x, y);
        return;
      }
      _lastClick = (x, y);
      _lastClickAt = now;
    }
    _routeMouse(kind, x, y);
  }

  void _routeText(String text, bool paste) {
    if (text.isEmpty) return;
    final single = !paste && text.runes.length == 1;
    // Focused on-region bindings and buttons come before falling back.
    if (single) {
      final r = text.runes.single;
      final nm = r == 0x20 ? 'space' : String.fromCharCode(r);
      final fid = _focusId;
      if (fid != null && fid is! Field && fid is! String) {
        for (final f in _focusables) {
          if (identical(f.id, fid) && f.onMap != null) {
            final b = _lookup(f.onMap!, nm);
            if (b != null) {
              _invoke(b.$2);
              return;
            }
            break;
          }
        }
      }
      if (fid is String) {
        _routeKey(nm); // focused button: space/letters are keys
        return;
      }
      // Screen keys before the rule-5 input fallback (mirrors 4-before-5).
      final b = _lookup(_keys, nm);
      if (b != null) {
        _invoke(b.$2);
        return;
      }
    }
    _F? target;
    for (final f in _focusables) {
      if (f.id is Field && f.tryKey != null && _sameId(f.id, _focusId)) {
        target = f;
        break;
      }
    }
    target ??= _focusables
        .where((f) => f.id is Field && f.tryKey != null)
        .firstOrNull;
    if (target != null) {
      target.tryKey!(_KeyEv('', text: text, paste: paste));
      return;
    }
    if (single) {
      final r = text.runes.single;
      _routeKey(r == 0x20 ? 'space' : String.fromCharCode(r));
    }
  }

  bool _routeKey(String name) {
    if (name == 'wheelup' || name == 'wheeldown') {
      final m = _mouse;
      if (m != null) {
        return _routeWheel(m.$1, m.$2, name == 'wheelup' ? -1 : 1);
      }
    }
    final fid = _focusId;
    if (fid != null) {
      for (final f in _focusables) {
        if (_sameId(f.id, fid) && f.tryKey != null) {
          if (f.tryKey!(_KeyEv(name))) return true;
          break;
        }
      }
      for (final f in _focusables) {
        if (_sameId(f.id, fid) && f.onMap != null) {
          final b = _lookup(f.onMap!, name);
          if (b != null) {
            _invoke(b.$2);
            return true;
          }
          break;
        }
      }
    }
    if (name == 'tab' || name == 'shift+tab') {
      if (!_bindsTab(name)) {
        _moveFocus(name == 'tab' ? 1 : -1);
        return true;
      }
    }
    final b = _lookup(_keys, name);
    if (b != null) {
      _invoke(b.$2);
      return true;
    }
    for (final f in _focusables) {
      if (_sameId(f.id, fid)) continue;
      if (f.tryKey != null && f.tryKey!(_KeyEv(name))) return true;
    }
    for (final f in _focusables) {
      if (_sameId(f.id, fid)) continue;
      if (f.onMap != null) {
        final ob = _lookup(f.onMap!, name);
        if (ob != null) {
          _setFocus(f.id);
          _invoke(ob.$2);
          return true;
        }
      }
    }
    if (name == 'ctrl+c') {
      _quit();
      return true;
    }
    return false;
  }

  bool _bindsTab(String name) {
    if (_lookup(_keys, name) != null) return true;
    final fid = _focusId;
    if (fid != null) {
      for (final f in _focusables) {
        if (_sameId(f.id, fid) && f.onMap != null) {
          if (_lookup(f.onMap!, name) != null) return true;
        }
      }
    }
    return false;
  }

  void _moveFocus(int dir) {
    if (_focusables.isEmpty) return;
    var idx = _focusables.indexWhere((f) => _sameId(f.id, _focusId));
    idx = idx < 0 ? (dir > 0 ? -1 : 0) : idx;
    idx = (idx + dir) % _focusables.length;
    if (idx < 0) idx += _focusables.length;
    _setFocus(_focusables[idx].id);
    _dirtyAndWake();
  }

  Bind? _lookup(Map<String, Bind> map, String name) {
    for (final entry in map.entries) {
      for (final alt in entry.key.split(' ')) {
        if (alt == name) return entry.value;
      }
    }
    return null;
  }

  bool _routeMouse(String kind, int x, int y) {
    _F? best;
    var bestArea = 1 << 30;
    var bestOrder = -1;
    for (final f in _focusables) {
      final mouseable = (kind == 'click' && f.tryKey != null) ||
          (f.onMap != null && _lookup(f.onMap!, kind) != null);
      if (!mouseable) continue;
      if (x < f.x || x >= f.x + f.w || y < f.y || y >= f.y + f.h) continue;
      final area = f.w * f.h;
      if (area < bestArea || (area == bestArea && f.order > bestOrder)) {
        best = f;
        bestArea = area;
        bestOrder = f.order;
      }
    }
    if (best != null) {
      if (kind == 'click' && best.tryKey != null) {
        if (best.tryKey!(_ClickEv(x, y, kind))) return true;
      }
      if (best.onMap != null) {
        final b = _lookup(best.onMap!, kind);
        if (b != null) {
          _setFocus(best.id);
          _invoke(b.$2);
          return true;
        }
      }
      final cb = _clickCbs[best.id];
      if (cb != null && kind == 'click') {
        cb(x, y);
        return true;
      }
    }
    final b = _lookup(_keys, kind);
    if (b != null) {
      _invoke(b.$2);
      return true;
    }
    return false;
  }

  bool _routeWheel(int x, int y, int dir) {
    _F? best;
    var bestArea = 1 << 30;
    var bestOrder = -1;
    for (final f in _focusables) {
      if (f.tryKey == null) continue;
      if (x < f.x || x >= f.x + f.w || y < f.y || y >= f.y + f.h) continue;
      final area = f.w * f.h;
      if (area < bestArea || (area == bestArea && f.order > bestOrder)) {
        best = f;
        bestArea = area;
        bestOrder = f.order;
      }
    }
    if (best != null && best.tryKey!(_WheelEv(x, y, dir))) return true;
    final b = _lookup(_keys, dir < 0 ? 'wheelup' : 'wheeldown');
    if (b != null) {
      _invoke(b.$2);
      return true;
    }
    return false;
  }

  void _invoke(FutureOr<void> Function() action) {
    _activeH++;
    _dirtyAndWake();
    try {
      final r = _zone != null ? _zone!.run(action) : action();
      if (r is Future) {
        r.then((_) {
          _activeH--;
          _dirtyAndWake();
        }, onError: (Object e, StackTrace st) {
          _activeH--;
          _handlerError(e, st);
          _dirtyAndWake();
        });
      } else {
        _activeH--;
      }
    } catch (e, st) {
      _activeH--;
      _handlerError(e, st);
    }
  }

  void _handlerError(Object e, StackTrace st) {
    if (e is Exception) {
      _failStatus(e);
    } else {
      _fatal ??= e;
      _fatalStack ??= st;
      _wake();
    }
  }

  void _fireLifecycle(String name) {
    final b = _lookup(_keys, name);
    if (b != null) _invoke(b.$2);
  }

  // --- draw & paint ------------------------------------------------------

  void _draw() {
    _focusables.clear();
    _clickCbs.clear();
    _popups.clear();
    _scrolls.clear();
    _order = 0;
    _spinVisible = false;
    _cursorPos = null;
    if (!_testMode) _caps = _Caps.current;
    // Fresh working grid every draw; _shown keeps last-painted state so the
    // paint still writes only changed cells.
    if (_grid.length != _h ||
        _grid.isNotEmpty && _grid.first.length != _w) {
      _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
      _shown = null;
      _repaint = true;
    } else {
      for (final row in _grid) {
        row.fillRange(0, row.length, _Cell.blank);
      }
    }
    final screen = _screenFn(_state, app);
    _keys = screen._keys;
    _title = screen._title;
    _statusLine = screen._status;
    final h = _h;
    final titleH = screen._title == null ? 0 : 1;
    final bodyH = math.max(0, h - titleH - 1);
    if (_grid.length != h) {
      _grid = List.generate(h, (_) => List.filled(_w, _Cell.blank));
      _shown = null;
      _repaint = true;
    }
    final root = Region._(this, _grid, 0, titleH, _w, bodyH);
    screen._draw(root);
    if (titleH == 1) {
      Region._(this, _grid, 0, 0, _w, 1)
          .write(' ${_title ?? ''} ', color: accent);
    }
    _drawStatus();
    _compositeScrolls();
    _compositePopups();
    if (_focusables.isNotEmpty &&
        !_focusables.any((f) => _sameId(f.id, _focusId))) {
      _F? best;
      for (final f in _focusables) {
        final s = _focusSeq[f.id] ?? -1;
        if (best == null || s > (_focusSeq[best.id] ?? -1)) best = f;
      }
      best ??= _focusables.first;
      _focusId = best.id;
      _focusSeq[best.id] = ++_seq;
    }
    if (!identical(_shownState, _state)) {
      _shownState = _state;
      _fireLifecycle('show');
    }
  }

  void _drawStatus() {
    final y = _h - 1;
    if (y < 0) return;
    String left;
    int leftStyle = 0;
    if (_error != null) {
      left = _error!;
      leftStyle = _pack(Color.red, null, {});
    } else if (_sayMsg != null) {
      left = _sayMsg!;
    } else if (_statusLine != null) {
      left = _statusLine!;
    } else {
      left = '';
    }
    final helps = <String>[];
    for (final entry in _keys.entries) {
      if (entry.value.$1.trim().isEmpty) continue;
      final alts = entry.key
          .split(' ')
          .where((a) => a.isNotEmpty && !_isMouse(a) && !_isLifecycle(a))
          .toList();
      if (alts.isEmpty) continue;
      final shown = alts.first == 'escape' ? 'esc' : alts.first;
      helps.add('$shown ${entry.value.$1}');
    }
    var help = helps.join(' · ');
    final leftW = term.displayWidth(left);
    var helpW = term.displayWidth(help);
    while (help.isNotEmpty && leftW + 1 + helpW > _w) {
      final cut = help.indexOf('·');
      help = cut < 0 ? '' : help.substring(cut + 1).trimLeft();
      helpW = term.displayWidth(help);
    }
    if (leftW <= _w) {
      _writeRaw(y, 0, _w, left, leftStyle);
      if (helpW > 0) _writeRaw(y, _w - helpW, _w, help, 0);
    } else {
      _writeRaw(y, 0, _w, term.truncateWidth(left, _w), leftStyle);
    }
  }

  void _writeRaw(int row, int from, int end, String text, int style) {
    if (row < 0 || row >= _grid.length) return;
    end = math.min(end, _w);
    var col = from;
    for (final rune in text.runes) {
      if (col >= end) break;
      if (rune < 0x20 || rune == 0x7f) continue;
      final w = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
      if (w == 0) continue;
      if (col + w > end) break;
      _grid[row][col] = _Cell(String.fromCharCode(rune), style, w);
      if (w == 2 && col + 1 < end) {
        _grid[row][col + 1] = _Cell('', style, 0);
      }
      col += w;
    }
  }

  void _compositeScrolls() {
    for (final ctx in _scrolls) {
      final contentH = math.max(ctx.buf.length, 1);
      final st = ctx.scroll;
      if (st._follow && st._pinned) {
        st._off = math.max(0, contentH - ctx.viewH);
      }
      st._off = st._off.clamp(0, math.max(0, contentH - ctx.viewH));
      for (var r = 0; r < ctx.viewH; r++) {
        final src = st._off + r;
        final dst = ctx.gy + r;
        if (dst < 0 || dst >= _grid.length) continue;
        if (src < ctx.buf.length) {
          final row = ctx.buf[src];
          for (var c = 0; c < ctx.w && c < row.length; c++) {
            if (ctx.gx + c < _grid[dst].length) {
              _grid[dst][ctx.gx + c] = row[c];
            }
          }
        }
      }
      if (contentH > ctx.viewH && ctx.w > 0) {
        for (var r = 0; r < ctx.viewH; r++) {
          final dst = ctx.gy + r;
          if (dst < 0 || dst >= _grid.length) continue;
          final frac = (st._off + r) / contentH;
          final thumb = frac * ctx.viewH;
          final ch = (r >= thumb && r < thumb + 1)
              ? (_caps.ascii ? '#' : '█')
              : (_caps.ascii ? '|' : '│');
          final dx = ctx.gx + ctx.w - 1;
          if (dx >= 0 && dx < _grid[dst].length) {
            _grid[dst][dx] = _Cell(ch, 0, 1);
          }
        }
      }
    }
  }

  void _compositePopups() {
    for (final p in _popups) {
      for (var r = 0; r < p.h; r++) {
        final dst = p.y + r;
        if (dst < 0 || dst >= _grid.length) continue;
        for (var c = 0; c < p.w; c++) {
          final dx = p.x + c;
          if (dx < 0 || dx >= _grid[dst].length) continue;
          _grid[dst][dx] = p.buf[r][c];
        }
      }
    }
  }

  /// Build the frame's output; null when nothing changed.
  String? _buildFrame() {
    final grid = _grid;
    var shown = _shown;
    if (_repaint || shown == null || shown.length != grid.length) {
      shown = _shown =
          List.generate(grid.length, (_) => List.filled(_w, _Cell.unknown));
      _repaint = false;
    }
    final buf = StringBuffer();
    var curSgr = '';
    String? link;
    for (var y = 0; y < grid.length && y < _h; y++) {
      final row = grid[y];
      final was = y < shown.length ? shown[y] : null;
      var cx = -1;
      for (var x = 0; x < row.length && x < _w; x++) {
        final c = row[x];
        if (c.width == 0) continue;
        if (was != null && x < was.length && c == was[x]) continue;
        if (x != cx) buf.write('\x1b[${y + 1};${x + 1}H');
        final sgr = _sgrFor(c);
        if (sgr != curSgr) {
          buf.write(sgr);
          curSgr = sgr;
        }
        if (c.link != link) {
          if (link != null) buf.write('\x1b]8;;\x1b\\');
          link = c.link;
          if (link != null) buf.write('\x1b]8;;$link\x1b\\');
        }
        buf.write(c.ch.isEmpty ? ' ' : c.ch);
        if (was != null && x < was.length) {
          was[x] = c;
          if (c.width == 2 && x + 1 < was.length && x + 1 < row.length) {
            was[x + 1] = row[x + 1];
          }
        }
        cx = c.isAscii ? x + 1 : -1;
      }
    }
    if (link != null) buf.write('\x1b]8;;\x1b\\');
    if (buf.isEmpty) return null;
    buf.write('\x1b[0m');
    var s = '\x1b[?2026h$buf\x1b[?2026l';
    final cur = _cursorPos;
    if (cur != null &&
        cur.$2 >= 0 &&
        cur.$2 < _w &&
        cur.$1 >= 0 &&
        cur.$1 < _h) {
      s += '\x1b[${cur.$1 + 1};${cur.$2 + 1}H\x1b[?25h';
    } else {
      s += '\x1b[?25l';
    }
    return s;
  }

  void _paint() {
    final s = _buildFrame();
    if (s == null) return;
    out(s);
    _lastPaint = _now();
  }

  bool _paintTo(StringBuffer sink) {
    final s = _buildFrame();
    if (s == null) return false;
    sink.write(s);
    _lastPaint = _now();
    return true;
  }

  String _sgrFor(_Cell c) {
    final (fg, bg, bits) = _unpack(c.style);
    final b = StringBuffer('\x1b[0');
    if (bits & 1 != 0) b.write(';1');
    if (bits & 2 != 0) b.write(';2');
    if (bits & 4 != 0) b.write(';3');
    if (bits & 8 != 0) b.write(';4');
    if (bits & 16 != 0) b.write(';9');
    if (bits & 32 != 0) b.write(';7');
    if (!_caps.noColor) {
      b.write(_colorSgr(fg, false));
      b.write(_colorSgr(bg, true));
    }
    b.write('m');
    return b.toString();
  }

  String _colorSgr(Color? col, bool bg) {
    if (col == null) return '';
    if (_caps.truecolor && col._rgb != null) {
      final (r, g, b) = col._rgb;
      return bg ? ';48;2;$r;$g;$b' : ';38;2;$r;$g;$b';
    }
    if (_caps.truecolor || _caps.color256) {
      return bg ? ';48;5;${col._i}' : ';38;5;${col._i}';
    }
    return ';${_basic(col._i, bg)}';
  }

  static int _basic(int i, bool bg) {
    int c;
    if (i < 16) {
      c = i;
    } else if (i >= 232) {
      c = i < 244 ? 0 : 7;
    } else {
      final v = i - 16;
      final r = v ~/ 36, g = (v % 36) ~/ 6, bl = v % 6;
      final m = math.max(r, math.max(g, bl));
      if (m == 0) {
        c = 0;
      } else if (r == m && g == m && bl == m) {
        c = 7;
      } else if (r == m && g == m) {
        c = 3;
      } else if (r == m && bl == m) {
        c = 5;
      } else if (g == m && bl == m) {
        c = 6;
      } else if (r == m) {
        c = 1;
      } else if (g == m) {
        c = 2;
      } else {
        c = 4;
      }
      if (m >= 3) c += 8;
    }
    if (c < 8) return (bg ? 40 : 30) + c;
    return (bg ? 100 : 90) + (c - 8);
  }

  // --- terminal life -----------------------------------------------------

  Future<void> _enter() async {
    try {
      final (w, h) = size();
      _w = math.max(1, w);
      _h = math.max(1, h);
    } catch (_) {}
    _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
    _modes = term.captureModes();
    term.setRawModes();
    _subs.add(term.sharedStdin().listen(_pending.addAll, onError: (_) {}));
    void watch(io.ProcessSignal signal, void Function() onSignal) {
      try {
        _subs.add(signal.watch().listen((_) => onSignal()));
      } catch (_) {}
    }

    watch(io.ProcessSignal.sigwinch, () {
      _repaint = true;
      _dirtyAndWake();
    });
    watch(io.ProcessSignal.sigint, () => _signals.add('ctrl+c'));
    watch(io.ProcessSignal.sigterm, () => _quitSync(143));
    watch(io.ProcessSignal.sighup, () => _quitSync(129));
    out('\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?2004h');
    _repaint = true;
    _dirty = true;
    _entered = true;
  }

  void _quitSync(int code) {
    _done = true;
    try {
      out('\x1b[0m\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?7h\x1b[?25h'
          '\x1b[?1049l');
      final modes = _modes;
      if (modes != null) term.restoreModes(modes);
    } catch (_) {}
    io.exit(code);
  }

  Future<void> _leave() async {
    _done = true;
    if (!_entered) return;
    _entered = false;
    _wake();
    await Future.wait(_subs.map((sub) async {
      try {
        await sub.cancel();
      } catch (_) {}
    }));
    _subs.clear();
    out('\x1b[0m\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?7h\x1b[?25h'
        '\x1b[?1049l');
    final modes = _modes;
    if (modes != null) term.restoreModes(modes);
    try {
      await io.stdout.flush();
    } catch (_) {}
  }
}

/// Terminal colour capabilities for one redraw.
final class _Caps {
  const _Caps(
      {required this.truecolor,
      required this.color256,
      required this.noColor,
      required this.ascii});

  static const fallback = _Caps(
      truecolor: false, color256: true, noColor: false, ascii: false);

  static _Caps get current {
    final env = io.Platform.environment;
    final noColor = env['NO_COLOR'] != null;
    final colorterm = (env['COLORTERM'] ?? '').toLowerCase();
    final tm = (env['TERM'] ?? '').toLowerCase();
    final lang = (env['LANG'] ?? '').toLowerCase();
    final truecolor =
        colorterm.contains('truecolor') || colorterm.contains('24bit');
    final color256 = truecolor || tm.contains('256color');
    final ascii = lang == 'c' ||
        lang.startsWith('c.') ||
        lang.isEmpty ||
        lang == 'posix';
    return _Caps(
        truecolor: truecolor,
        color256: color256,
        noColor: noColor,
        ascii: ascii);
  }

  final bool truecolor;
  final bool color256;
  final bool noColor;
  final bool ascii;
}

final class _Cell {
  const _Cell(this.ch, this.style, this.width, {this.link});

  static const blank = _Cell(' ', 0, 1);
  static const unknown = _Cell('', -1, -1);

  final String ch;
  final int style;
  final int width;
  final String? link;

  bool get isAscii => ch.length == 1 && ch.codeUnitAt(0) < 0x7f;

  @override
  bool operator ==(Object other) =>
      other is _Cell &&
      other.ch == ch &&
      other.style == style &&
      other.width == width &&
      other.link == link;

  @override
  int get hashCode => Object.hash(ch, style, width, link);
}

/// In-memory test harness: drive a state-driven app without a terminal.
final class TestSession<S> {
  TestSession._(this._s);

  final _Session<S> _s;
  final _out = StringBuffer();

  /// Feed raw input bytes for the next [pump].
  void bytes(List<int> b) => _s._pending.addAll(b);

  /// Process pending input, settle handlers, redraw if dirty.
  /// Returns true when a paint wrote output.
  Future<bool> pump() async {
    var painted = false;
    await _s._zoneRun(() async {
      _s._pollInput();
      await _s._settleForTest();
      if (_s._dirty) {
        _s._draw();
        painted = _s._paintTo(_out);
        _s._dirty = false;
      }
    });
    return painted;
  }

  /// The current screen row as text (wide continuation cells skipped).
  String row(int y) {
    final grid = _s._grid;
    if (y < 0 || y >= grid.length) return '';
    final buf = StringBuffer();
    for (final c in grid[y]) {
      if (c.width == 0) continue;
      buf.write(c.ch.isEmpty ? ' ' : c.ch);
    }
    return buf.toString().trimRight();
  }

  /// Run until [quit] (or a fatal [Error], rethrown).
  Future<S> run() async {
    await _s._zoneRun(() async {
      _s._draw();
      _s._paintTo(_out);
      _s._dirty = false;
    });
    while (!_s._quitFlag) {
      if (_s._fatal != null) {
        final e = _s._fatal!;
        final st = _s._fatalStack ?? StackTrace.empty;
        Error.throwWithStackTrace(e, st);
      }
      await _s._zoneRun(() async {
        _s._pollInput();
        await _s._settleForTest();
        if (_s._dirty) {
          _s._draw();
          _s._paintTo(_out);
          _s._dirty = false;
        }
      });
      if (_s._pending.isEmpty &&
          _s._activeH == 0 &&
          !_s._dirty &&
          !_s._quitFlag) {
        break;
      }
    }
    if (_s._fatal != null) {
      final e = _s._fatal!;
      final st = _s._fatalStack ?? StackTrace.empty;
      Error.throwWithStackTrace(e, st);
    }
    return _s._state;
  }

  bool get quitRequested => _s._quitFlag;
  S get state => _s._state;
  String get output => _out.toString();
}

/// Build an in-memory [TestSession] (no terminal required).
TestSession<S> testSession<S>(S state,
    Screen Function(S state, App<S> app) screen,
    {int width = 80, int height = 24, Color accent = Color.orange}) {
  final s = _Session<S>(state, screen,
      out: (_) {},
      size: () => (width, height),
      accent: accent,
      fullscreen: true);
  s._w = width;
  s._h = height;
  s._grid = List.generate(height, (_) => List.filled(width, _Cell.blank));
  s._testMode = true;
  s._caps = _Caps.fallback;
  late Zone z;
  runZoned(() {
    z = Zone.current;
  }, zoneSpecification: s._spec());
  s._zone = z;
  return TestSession<S>._(s);
}
