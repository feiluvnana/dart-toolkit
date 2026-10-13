/// The state-driven engine behind `tui.dart`: session loop, routing,
/// painter, widgets, markdown, diff and the Console bridge.
/// [TestSession] is the in-memory harness for `test/tui_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

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

/// The height of an inline (or print) region: as tall as its content.
const _unbounded = 1 << 20;

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

  /// Add [item] to the end of the list. Returns this.
  Pick<T> add(T item) => set([..._items, item]);

  /// Add all [items] to the end of the list. Returns this.
  Pick<T> addAll(Iterable<T> items) => set([..._items, ...items]);

  /// Remove [item] from the list. Returns this.
  Pick<T> remove(T item) => set([for (final x in _items) if (x != item) x]);

  /// Remove items satisfying [test]. Returns this.
  Pick<T> removeWhere(bool Function(T item) test) =>
      set([for (final x in _items) if (!test(x)) x]);
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
  int _wantCol = -1; // sticky display column for vertical moves
  int _rowOff = 0; // first visible row for multiline inputs

  String text() => _text;
  List<String> history() => _history;

  /// Replace the text; the cursor goes to the end.
  Field set(String text) {
    _text = text;
    _cursor = text.runes.length;
    _histAt = -1;
    _wantCol = -1;
    return this;
  }

  /// Return the text, push it to the history, and clear.
  String submit() {
    final t = _text;
    if (t.isNotEmpty) _history = List<String>.unmodifiable([t, ..._history]);
    _text = '';
    _cursor = 0;
    _histAt = -1;
    _wantCol = -1;
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
      {bool grow = false,
      bool open = false,
      Region? parent,
      _ScrollCtx? scroll,
      _Popup? pop})
      // ignore: prefer_initializing_formals
      : _grow = grow,
        // ignore: prefer_initializing_formals
        _open = open,
        // ignore: prefer_initializing_formals
        _parent = parent,
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
  /// The buffer grows as rows are written (inline, scroll, print).
  final bool _grow;

  /// The height comes from the content: `rows` 0-sizes and `box` take
  /// what their content draws (measured in a first pass), and widgets take
  /// only the rows they draw.
  final bool _open;
  final Region? _parent;
  final _ScrollCtx? _scroll;
  final _Popup? _pop;
  var _cursor = 0;

  /// Rows drawn so far, from the top of this region (open layout).
  var _extent = 0;

  void _bump(int row) {
    final n = row - _gy + 1;
    if (n > _extent) _extent = n;
    final p = _parent;
    if (p != null && identical(p._grid, _grid)) p._bump(row);
  }

  /// Rows the rest of an open region takes: what [used] rows drew.
  void _take(int used) {
    if (used > 0) _bump(_gy + _cursor + used - 1);
    _cursor += used;
  }

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
      if (_cursor < _h) {
        _writeLine(_gy + _cursor, _gx, _gx + _w, line, st, link);
      } else {
        overflow = true;
      }
      _cursor++;
    }
    if (overflow && _h > 0 && _w > 0) {
      _put(_gy + _h - 1, _gx + _w - 1, '…', 1, st, link);
    }
    return this;
  }

  /// Markdown: headings, lists (nested, numbered), `>` quotes, tables
  /// (box-drawn), `---`, inline bold/italic/strike/`code`/links (OSC 8).
  /// Fenced code is highlighted by an in-house lexer; an unclosed fence or
  /// emphasis renders as if closed (safe to stream). Layout is cached by
  /// (source, width).
  Region markdown(String source) {
    for (final line in _mdLayout(source, _w, _s._caps.ascii, _s)) {
      if (_cursor >= _h) {
        _cursor++;
        continue;
      }
      var col = _gx;
      for (final seg in line) {
        col = _writeLine(_gy + _cursor, col, _gx + _w, seg.text,
            _s._pack(seg.fg, seg.bg, seg.style), seg.link);
      }
      _cursor++;
    }
    return this;
  }

  /// A line diff: unified hunks with 3 context lines, gutter line numbers,
  /// `-`/`+` rows on red/green backgrounds, changed words of paired lines
  /// brighter.
  Region diff(String before, String after) {
    for (final line in _diffHunks(before.split('\n'), after.split('\n'))) {
      if (_cursor >= _h) {
        _cursor++;
        continue;
      }
      var col = _gx;
      for (final seg in line) {
        col = _writeLine(_gy + _cursor, col, _gx + _w, seg.text,
            _s._pack(seg.fg, seg.bg, seg.style), null);
      }
      _cursor++;
    }
    return this;
  }

  /// Border the rest of the region with [title]; return the inside.
  Region box(String title) {
    if (_open) return _measuredRows(const [0], 2, title).single;
    return _boxAt(title, _gy + _cursor, _h - _cursor);
  }

  Region _boxAt(String title, int top, int h, {bool open = false}) {
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
    if (_w < 3 || h < 3) return _sub(_gx, top, 0, 0, open: open);
    return _sub(_gx + 1, top + 1, _w - 2, open ? _unbounded : h - 2,
        open: open);
  }

  /// `rows` (and `box`, with a 2-row [border]) in an open region: 0-sized
  /// children take their content's height. The first draw pass gives each
  /// child its own scratch buffer and measures it; later passes lay them
  /// out with the measured heights until they settle (see
  /// [_Session._measured]).
  List<Region> _measuredRows(List<int> sizes, int border, String? title) {
    final s = _s;
    final base = s._mNext;
    s._mNext += sizes.length;
    final at = _cursor;
    final slots = s._mSlots;
    final List<Region> kids;
    if (slots == null) {
      final inner = border > 0 ? math.max(0, _w - 2) : _w;
      kids = [
        for (final z in sizes)
          Region._(s, <List<_Cell>>[], 0, 0, inner, z > 0 ? z : _unbounded,
              grow: true, open: true)
      ];
      _cursor = _h; // siblings after this are measured by the next pass
    } else {
      final hs = [
        for (var k = 0; k < sizes.length; k++)
          base + k < slots.length ? slots[base + k] : 0
      ];
      final total = hs.fold(0, (a, b) => a + b);
      if (title != null) {
        kids = [_boxAt(title, _gy + at, total + border, open: true)];
      } else {
        kids = [];
        var off = _gy + at;
        for (var k = 0; k < sizes.length; k++) {
          kids.add(_sub(_gx, off, _w, sizes[k] > 0 ? sizes[k] : _unbounded,
              open: true));
          off += hs[k];
        }
      }
      _cursor = at;
      _take(total + border);
    }
    s._mPending.add(() {
      var total = 0;
      for (var k = 0; k < sizes.length; k++) {
        final h = sizes[k] > 0 ? sizes[k] : kids[k]._extent;
        s._mBuild[base + k] = h;
        total += h;
      }
      if (slots == null) {
        _cursor = at;
        _take(total + border);
      }
    });
    return kids;
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
    var h = _h - _cursor;
    if (_open) {
      // As tall as the terminal allows, under the title and status rows.
      h = math.min(h, math.max(1, _s._h - 2));
      _take(h);
    } else {
      _cursor = _h;
    }
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
    return Region._(_s, buf, 0, 0, _w, _unbounded,
        grow: true, open: true, scroll: ctx);
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
    final h = _listRows(pick, 0, empty);
    _drawList(pick, label, empty, y, h);
    return this;
  }

  /// A selectable table.
  Region table<T>(Pick<T> pick, List<String> Function(T item) cells,
      {List<String>? header, String empty = ''}) {
    final y = _gy + _cursor;
    final h = _listRows(pick, header == null ? 0 : 1, empty);
    // Columns as wide as their widest cell, the widest shrunk to fit.
    final widths = <int>[];
    for (final row in [?header, for (final t in pick.items()) cells(t)]) {
      for (var k = 0; k < row.length; k++) {
        final w = term.displayWidth(row[k]);
        if (k == widths.length) {
          widths.add(w);
        } else if (w > widths[k]) {
          widths[k] = w;
        }
      }
    }
    while (widths.fold(0, (a, w) => a + w + 2) - 2 > _w) {
      final k = widths.indexOf(widths.reduce(math.max));
      if (widths[k] <= 4) break;
      widths[k]--;
    }
    String line(List<String> row) => [
          for (var k = 0; k < row.length; k++)
            k == row.length - 1
                ? row[k]
                : _padCells(term.truncateWidth(row[k], widths[k]), widths[k]),
        ].join('  ');
    _drawList(pick, (t) => line(cells(t)), empty, y, h,
        header: header == null ? null : [line(header)]);
    return this;
  }

  static String _padCells(String s, int cells) =>
      s + ' ' * math.max(0, cells - term.displayWidth(s));

  /// The rows a list takes: the rest of the region, or in an open region
  /// one per item (plus the header).
  int _listRows(Pick<Object?> pick, int head, String empty) {
    var h = _h - _cursor;
    if (!_open) {
      _cursor = _h;
      return h;
    }
    final n = pick.items().length;
    h = math.min(h, n == 0 ? (empty.isEmpty ? 0 : 1) : n + head);
    _take(h);
    return h;
  }

  void _drawList<T>(Pick<T> pick, String Function(T item) label, String empty,
      int y, int h,
      {List<String> Function(T item)? cells, List<String>? header}) {
    final order = _s._order++;
    final items = pick.items();
    final headRows = header != null ? 1 : 0;
    final viewH = h - headRows;
    var start = _s._listStart(pick, items.length, math.max(0, viewH));
    // Scroll by the least needed to show the selection, in this frame.
    final want = pick.index();
    if (want < start) start = want;
    if (viewH > 0 && want >= start + viewH) start = want - viewH + 1;
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
      if (ev is! _KeyEv) return false;
      if (!ev.fallback && !_sameId(_s._focusId, pick)) return false;
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

  /// A text editor. `lines` reserves rows (`>1` grows to that many, `0` is
  /// uncapped); `suggest` completes the word at the cursor in a popup
  /// (`up`/`down` choose, `tab`/`enter` replace, `escape` closes; stale async
  /// answers are dropped). `enter` is never consumed. Text editing is by
  /// grapheme: `backspace`/`delete`, `left` `right` `home` `end`, `ctrl+a`
  /// `ctrl+e`, word jumps (`ctrl`/`alt` + arrows) and kills (`ctrl+w`,
  /// `alt+backspace`, `ctrl+u`, `ctrl+k`); `shift+enter`, `alt+enter` or `\`
  /// then `enter` insert a newline. `up`/`down` move between lines, and at
  /// the first or last line they walk the history.
  Region input(Field field,
      {String hint = '',
      int lines = 1,
      FutureOr<List<String>> Function(String word)? suggest,
      FutureOr<void> Function()? onSubmit}) {
    if (lines < 0) {
      throw ArgumentError.value(lines, 'lines', 'must be >= 0');
    }
    final y = _gy + _cursor;
    final rem = _h - _cursor;
    final rows = _fieldRows(field);
    final need = rows.length;
    final reserve = lines == 0 ? math.max(need, 1) : lines;
    _cursor += reserve;
    final order = _s._order++;
    _s._drawnFields.add(field);
    _reg(field, _gx, y, _w, math.max(0, math.min(reserve, rem)), order,
        (ev) => _inputKey(field, ev, lines, suggest, onSubmit));
    if (rem <= 0 || _w <= 0) return this;
    final showN = lines == 0 ? need : lines;
    _s._clickBase[field] = y;
    final curRow = _rowOf(field);
    var rowOff = field._rowOff;
    if (curRow < rowOff) {
      rowOff = curRow;
    } else if (curRow >= rowOff + showN) {
      rowOff = curRow - showN + 1;
    }
    field._rowOff = math.max(0, rowOff);
    final drawN = math.min(showN, rem);
    for (var r = 0; r < drawN; r++) {
      final text = field._rowOff + r < rows.length
          ? rows[field._rowOff + r]
          : '';
      final isHint = field._text.isEmpty && r == 0;
      String shown;
      if (isHint) {
        shown = hint;
      } else if (lines == 1) {
        shown = _tailText(field, _w - 1);
      } else {
        shown = _fitCells(text, _w - 1);
      }
      final st = isHint ? _s._pack(null, null, {Style.dim}) : 0;
      final end = _writeLine(y + r, _gx, _gx + _w - 1, shown, st, null);
      _put(y + r, end, ' ', 1, _s._pack(null, null, {Style.reverse}), null);
    }
    final cpos = _cursorScreenPos(field, y, lines);
    if (_sameId(_s._focusId, field)) {
      if (cpos == null) {
        _s._cursorPos = null;
      } else {
        _placeCursorAt(cpos.$1, cpos.$2);
      }
    }
    if (suggest != null) _s._refreshSuggest(field, suggest);
    _s._drawSuggestPopup(field, this, cpos);
    return this;
  }

  /// Display rows of [field]'s text.
  List<String> _fieldRows(Field field) => field._text.split('\n');

  int _rowOf(Field field) {
    final off = field._cursor.clamp(0, field._text.runes.length);
    var row = 0;
    var k = 0;
    for (final r in field._text.runes) {
      if (k >= off) break;
      if (r == 0x0a) row++;
      k++;
    }
    return row;
  }

  /// Display column (cells) of the cursor within its row.
  int _colOf(Field field) {
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    var start = at;
    while (start > 0 && runes[start - 1] != 0x0a) {
      start = _prevCluster(runes, start);
    }
    var col = 0;
    var k = start;
    while (k < at) {
      final next = _nextCluster(runes, k);
      for (var j = k; j < next; j++) {
        final r = runes[j];
        if (!term.isZeroWidth(r)) col += term.cellWidth(r);
      }
      k = next;
    }
    return col;
  }

  /// Offset of (row, display column), clamped into the row.
  int _offsetAt(Field field, int row, int colCells) {
    final rows = _fieldRows(field);
    row = row.clamp(0, rows.length - 1);
    final runes = rows[row].runes.toList();
    var col = 0;
    var k = 0;
    while (k < runes.length) {
      final next = _nextCluster(runes, k);
      var w = 0;
      for (var j = k; j < next; j++) {
        final r = runes[j];
        if (!term.isZeroWidth(r)) w += term.cellWidth(r);
      }
      if (col + w > colCells) break;
      col += w;
      k = next;
    }
    var off = 0;
    for (var r = 0; r < row; r++) {
      off += rows[r].runes.length + 1;
    }
    return off + k;
  }

  /// Longest head of [text] fitting [cells].
  String _fitCells(String text, int cells) {
    final runes = text.runes.toList();
    var used = 0;
    var i = 0;
    while (i < runes.length) {
      final next = _nextCluster(runes, i);
      var w = 0;
      for (var j = i; j < next; j++) {
        final r = runes[j];
        if (!term.isZeroWidth(r)) w += term.cellWidth(r);
      }
      if (used + w > cells) break;
      used += w;
      i = next;
    }
    return String.fromCharCodes(runes.sublist(0, i));
  }

  void _placeCursorAt(int row, int col) {
    final p = _toScreen(row, col);
    if (p == null) {
      _s._cursorPos = null;
      return;
    }
    final (x, y) = p;
    if (x < 0 || x >= _s._w || y < 0) {
      _s._cursorPos = null;
      return;
    }
    // (row, col), as the painters read it.
    _s._cursorPos = (y, x);
  }

  /// Buffer (row, col) of the cursor, or null when its row is scrolled out.
  (int, int)? _cursorScreenPos(Field field, int y0, int lines) {
    if (lines == 1) {
      // Single line shows the tail; the cursor pins to the last cell when
      // scrolled out of view.
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
      return (y0, col);
    }
    final rows = _fieldRows(field);
    final curRow = _rowOf(field);
    final rel = curRow - field._rowOff;
    final showN = lines == 0 ? rows.length : lines;
    if (rel < 0 || rel >= showN) return null;
    final start = _offsetAt(field, curRow, 0);
    final at = field._cursor.clamp(0, field._text.runes.length);
    final rowRunes =
        curRow < rows.length ? rows[curRow].runes.toList() : <int>[];
    var col = _gx;
    var k = 0;
    final target = (at - start).clamp(0, rowRunes.length);
    while (k < target) {
      final next = _nextCluster(rowRunes, k);
      for (var j = k; j < next; j++) {
        final r = rowRunes[j];
        if (!term.isZeroWidth(r)) col += term.cellWidth(r);
      }
      k = next;
    }
    return (y0 + rel, col);
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

  bool _inputKey(Field field, _Ev ev, int lines,
      FutureOr<List<String>> Function(String word)? suggest,
      [FutureOr<void> Function()? onSubmit]) {
    if (ev is _ClickEv) {
      _s._setFocus(field);
      final rows = _fieldRows(field);
      final y0 = _clickBaseRow(field);
      final row = (ev.y - y0).clamp(0, rows.length - 1);
      field._cursor = _clickOffset(field, rows, row, ev.x);
      field._wantCol = -1;
      _s._dirtyAndWake();
      return true;
    }
    if (ev is _WheelEv) return false;
    if (ev is! _KeyEv) return false;
    if (ev.text != null) {
      _s._setFocus(field);
      _insertText(field, ev.paste ? _oneLine(ev.text!) : ev.text!);
      if (suggest != null) _s._refreshSuggest(field, suggest);
      _s._dirtyAndWake();
      return true;
    }
    if (!_sameId(_s._focusId, field)) return false;
    final runes = field._text.runes.toList();
    final multi = lines != 1;
    bool edited(void Function() op) {
      op();
      field._wantCol = -1;
      if (suggest != null) _s._refreshSuggest(field, suggest);
      _s._dirtyAndWake();
      return true;
    }

    switch (ev.name) {
      case 'backspace':
        return edited(() => _dropGrapheme(field, -1));
      case 'delete':
        return edited(() => _dropGrapheme(field, 1));
      case 'left':
        field._cursor = _prevCluster(runes, field._cursor);
        field._wantCol = -1;
        if (suggest != null) _s._refreshSuggest(field, suggest);
        _s._dirtyAndWake();
        return true;
      case 'right':
        field._cursor = _nextCluster(runes, field._cursor);
        field._wantCol = -1;
        if (suggest != null) _s._refreshSuggest(field, suggest);
        _s._dirtyAndWake();
        return true;
      case 'home':
      case 'ctrl+a':
        field._cursor = _lineStart(runes, field._cursor);
        field._wantCol = -1;
        _s._dirtyAndWake();
        return true;
      case 'end':
      case 'ctrl+e':
        field._cursor = _lineEnd(runes, field._cursor);
        field._wantCol = -1;
        _s._dirtyAndWake();
        return true;
      case 'ctrl+w':
      case 'alt+backspace':
        return edited(() => _deleteWord(field, -1));
      case 'ctrl+u':
        return edited(() {
          final at = field._cursor.clamp(0, runes.length);
          final start = _lineStart(runes, at);
          runes.removeRange(start, at);
          field._text = String.fromCharCodes(runes);
          field._cursor = start;
        });
      case 'ctrl+k':
        return edited(() {
          final at = field._cursor.clamp(0, runes.length);
          final end = _lineEnd(runes, at);
          runes.removeRange(at, end);
          field._text = String.fromCharCodes(runes);
        });
      case 'up':
      case 'down':
        final rows = _fieldRows(field);
        final curRow = _rowOf(field);
        final goUp = ev.name == 'up';
        if (multi &&
            ((goUp && curRow > 0) ||
                (!goUp && curRow < rows.length - 1))) {
          if (field._wantCol < 0) field._wantCol = _colOf(field);
          field._cursor =
              _offsetAt(field, curRow + (goUp ? -1 : 1), field._wantCol);
          if (suggest != null) _s._refreshSuggest(field, suggest);
          _s._dirtyAndWake();
          return true;
        }
        if (field._history.isEmpty) return false;
        if (field._histAt < 0) {
          if (!goUp) return false;
          field._draft = field._text;
          field._histAt = 0;
        } else {
          field._histAt += goUp ? 1 : -1;
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
        field._wantCol = -1;
        if (suggest != null) _s._refreshSuggest(field, suggest);
        _s._dirtyAndWake();
        return true;
      case 'enter':
        if (multi) {
          final at = field._cursor.clamp(0, runes.length);
          final prev = _prevCluster(runes, at);
          if (prev == at - 1 && prev >= 0 && runes[prev] == 0x5c) {
            return edited(() {
              runes.removeAt(prev);
              runes.insert(prev, 0x0a);
              field._text = String.fromCharCodes(runes);
              field._cursor = prev + 1;
            });
          }
        }
        if (onSubmit != null) {
          _s._invoke(onSubmit);
          return true;
        }
        return false;
      case 'shift+enter':
      case 'alt+enter':
        if (!multi) return false;
        return edited(() => _insertText(field, '\n'));
      default:
        if (ev.name.endsWith('left')) {
          field._cursor = _prevWord(runes, field._cursor);
          field._wantCol = -1;
          if (suggest != null) _s._refreshSuggest(field, suggest);
          _s._dirtyAndWake();
          return true;
        }
        if (ev.name.endsWith('right')) {
          field._cursor = _nextWord(runes, field._cursor);
          field._wantCol = -1;
          if (suggest != null) _s._refreshSuggest(field, suggest);
          _s._dirtyAndWake();
          return true;
        }
        return false;
    }
  }

  /// Buffer row of this input's first line (for click mapping).
  int _clickBaseRow(Field field) => _s._clickBase[field] ?? _gy + _cursor - 1;

  int _clickOffset(Field field, List<String> rows, int row, int xCells) {
    var col = xCells - _gx;
    if (col < 0) col = 0;
    final runes = row < rows.length ? rows[row].runes.toList() : <int>[];
    var used = 0;
    var k = 0;
    while (k < runes.length) {
      final next = _nextCluster(runes, k);
      var w = 0;
      for (var j = k; j < next; j++) {
        final r = runes[j];
        if (!term.isZeroWidth(r)) w += term.cellWidth(r);
      }
      if (used + w > col) break;
      used += w;
      k = next;
    }
    var off = 0;
    for (var r = 0; r < row.clamp(0, rows.length - 1); r++) {
      off += rows[r].runes.length + 1;
    }
    return off + k;
  }

  int _lineStart(List<int> runes, int at) {
    var i = at.clamp(0, runes.length);
    while (i > 0 && runes[i - 1] != 0x0a) {
      i = _prevCluster(runes, i);
    }
    return i;
  }

  int _lineEnd(List<int> runes, int at) {
    var i = at.clamp(0, runes.length);
    while (i < runes.length && runes[i] != 0x0a) {
      i = _nextCluster(runes, i);
    }
    return i;
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
    final cells = frac * width;
    final full = cells.floor();
    final half = cells - full >= 0.5 && full < width;
    final (on, mid, off) = _s._caps.ascii ? ('#', '>', '-') : ('━', '╸', '─');
    final glyphs = '${on * full}${half ? mid : ''}${off * (width - full - (half ? 1 : 0))}';
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
    _s._addFocusable(id, r.$1, r.$2, r.$3, r.$4, order, wrapped,
        onMap: onMap, fixed: _pop != null);
  }

  Region _sub(int x, int y, int w, int h, {bool? open}) => Region._(
      _s, _grid, x, y, w, h,
      grow: _grow,
      open: open ?? _open,
      parent: this,
      scroll: _scroll,
      pop: _pop);

  List<Region> _split(List<int> sizes, {required bool horizontal}) {
    for (final s in sizes) {
      if (s < 0) {
        throw ArgumentError.value(
            sizes, 'sizes', 'negative size $s: use 0 for a flex share');
      }
    }
    if (horizontal && _open) return _measuredRows(sizes, 0, null);
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
          ? _sub(_gx, off, _w, size)
          : _sub(off, _gy + _cursor, size, _h - _cursor));
      off += size;
    }
    _cursor = _h;
    return out;
  }

  int _writeLine(
      int row, int from, int end, String text, int style, String? link) {
    if (row < _gy || row >= _gy + _h) return from;
    _ensureRow(row);
    _bump(row);
    final cap = _grid == _s._grid ? _s._w : _grid[row].length;
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
    // Grow buffers start at (0, 0) and are as wide as their first row.
    final width = _grid.isEmpty ? _gx + _w : _grid.first.length;
    while (_grid.length <= row) {
      _grid.add(List.filled(width, _Cell.blank));
    }
  }

  void _put(int row, int col, String ch, int width, int style, String? link) {
    final grid = _grid;
    if (row < _gy || row >= _gy + _h) return;
    _ensureRow(row);
    if (row >= grid.length) return;
    final cells = grid[row];
    final gc = col;
    if (gc < 0 || gc + width > cells.length) return;
    _bump(row);
    if (cells[gc].width == 0 && gc > 0) cells[gc - 1] = _Cell.blank;
    final after = gc + width;
    if (after < cells.length && cells[after].width == 0) {
      cells[after] = _Cell.blank;
    }
    cells[gc] = _Cell(ch, style, width, link: link);
    if (width == 2) cells[gc + 1] = _Cell('', style, 0, link: link);
    if (identical(grid, _s._grid)) {
      _s._usedRows = math.max(_s._usedRows, row + 1);
    }
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

/// Markdown keyword sets by canonical language.
const _mdKw = {
  'dart': {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'bool', 'break',
    'case', 'catch', 'class', 'const', 'continue', 'covariant', 'default',
    'deferred', 'do', 'double', 'dynamic', 'else', 'enum', 'export',
    'extends', 'extension', 'external', 'factory', 'false', 'final',
    'finally', 'for', 'Function', 'get', 'hide', 'if', 'implements',
    'import', 'in', 'interface', 'int', 'is', 'late', 'library', 'mixin',
    'new', 'null', 'num', 'on', 'operator', 'part', 'required', 'rethrow',
    'return', 'sealed', 'set', 'show', 'static', 'String', 'super', 'switch',
    'sync', 'this', 'throw', 'true', 'try', 'typedef', 'var', 'void',
    'while', 'with', 'yield'
  },
  'js': {
    'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
    'debugger', 'default', 'delete', 'do', 'else', 'enum', 'export',
    'extends', 'false', 'finally', 'for', 'function', 'if', 'implements',
    'import', 'in', 'instanceof', 'interface', 'let', 'new', 'null',
    'package', 'private', 'protected', 'public', 'return', 'static',
    'super', 'switch', 'this', 'throw', 'true', 'try', 'typeof', 'var',
    'void', 'while', 'with', 'yield', 'async', 'of', 'from',
    'type', 'string', 'number', 'boolean'
  },
  'python': {
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await',
    'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
    'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
    'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try',
    'while', 'with', 'yield', 'self', 'print'
  },
  'shell': {
    'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'while',
    'until', 'do', 'done', 'in', 'function', 'select', 'time', 'export',
    'local', 'return', 'exit', 'echo', 'true', 'false', 'set', 'shift',
    'continue', 'break', 'trap', 'await'
  },
  'json': {'true', 'false', 'null'},
  'yaml': {'true', 'false', 'null', 'yes', 'no', 'on', 'off'},
  'rust': {
    'as', 'break', 'const', 'continue', 'crate', 'else', 'enum', 'extern',
    'false', 'fn', 'for', 'if', 'impl', 'in', 'let', 'loop', 'match',
    'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self', 'Self',
    'static', 'struct', 'super', 'trait', 'true', 'type', 'unsafe',
    'use', 'where', 'while', 'async', 'await', 'dyn', 'become', 'do'
  },
  'go': {
    'break', 'case', 'chan', 'const', 'continue', 'default', 'defer',
    'else', 'fallthrough', 'for', 'func', 'go', 'goto', 'if', 'import',
    'interface', 'map', 'package', 'range', 'return', 'select', 'struct',
    'switch', 'type', 'var', 'true', 'false', 'nil', 'string', 'int',
    'bool', 'error'
  },
  'c': {
    'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do',
    'double', 'else', 'enum', 'extern', 'float', 'for', 'goto', 'if',
    'inline', 'int', 'long', 'register', 'restrict', 'return', 'short',
    'signed', 'sizeof', 'static', 'struct', 'switch', 'typedef', 'union',
    'unsigned', 'void', 'volatile', 'while', 'class', 'public', 'private',
    'new', 'true', 'false', 'null', 'using', 'namespace', 'template',
    'virtual', 'override', 'final', 'import', 'package', 'String',
    'System', 'var'
  },
};

/// Canonical language key for a fence info string, or null for plain code.
String? _mdLang(String info) {
  final key = info.trim().split(RegExp(r'\s+')).firstOrNull?.toLowerCase();
  if (key == null || key.isEmpty) return null;
  const aliases = {
    'javascript': 'js',
    'typescript': 'js',
    'ts': 'js',
    'jsx': 'js',
    'tsx': 'js',
    'py': 'python',
    'sh': 'shell',
    'bash': 'shell',
    'zsh': 'shell',
    'console': 'shell',
    'yml': 'yaml',
    'rs': 'rust',
    'cpp': 'c',
    'c++': 'c',
    'h': 'c',
    'hpp': 'c',
    'java': 'c',
    'cs': 'c',
    'csharp': 'c',
  };
  final canon = aliases[key] ?? key;
  return _mdKw.containsKey(canon) ? canon : null;
}

/// Highlight one code line; [block] tracks `/* */` across lines.
List<_MdSeg> _mdHighlight(String line, String? lang, List<bool> block) {
  if (lang == null) return [_MdSeg(line, null, null, {}, null)];
  const str = Color.green;
  const com = Color.gray;
  const num = Color.cyan;
  const kw = Color.yellow;
  final out = <_MdSeg>[];
  final buf = StringBuffer();
  void text(String s) {
    if (s.isNotEmpty) out.add(_MdSeg(s, null, null, {}, null));
  }

  void flush() {
    text(buf.toString());
    buf.clear();
  }

  var i = 0;
  final hashComment = lang == 'python' ||
      lang == 'shell' ||
      lang == 'yaml' ||
      lang == 'rust';
  final slashComment =
      lang != 'python' && lang != 'shell' && lang != 'yaml';
  final blockComment = slashComment && lang != 'json';
  final kws = _mdKw[lang] ?? const {};
  bool ident(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      c == 0x5F ||
      (c >= 0x61 && c <= 0x7A);
  while (i < line.length) {
    final c = line.codeUnitAt(i);
    if (block[0]) {
      final end = line.indexOf('*/', i);
      if (end < 0) {
        out.add(_MdSeg(line.substring(i), com, null, {}, null));
        i = line.length;
        break;
      }
      out.add(_MdSeg(line.substring(i, end + 2), com, null, {}, null));
      i = end + 2;
      block[0] = false;
      continue;
    }
    if (slashComment && line.startsWith('//', i)) {
      flush();
      out.add(_MdSeg(line.substring(i), com, null, {}, null));
      break;
    }
    if (hashComment && c == 0x23) {
      flush();
      out.add(_MdSeg(line.substring(i), com, null, {}, null));
      break;
    }
    if (blockComment && line.startsWith('/*', i)) {
      flush();
      final end = line.indexOf('*/', i + 2);
      if (end < 0) {
        out.add(_MdSeg(line.substring(i), com, null, {}, null));
        block[0] = true;
        break;
      }
      out.add(_MdSeg(line.substring(i, end + 2), com, null, {}, null));
      i = end + 2;
      continue;
    }
    if (c == 0x22 || c == 0x27 || c == 0x60) {
      flush();
      var j = i + 1;
      while (j < line.length) {
        if (line.codeUnitAt(j) == 0x5c) {
          j += 2;
          continue;
        }
        if (line.codeUnitAt(j) == c) {
          j++;
          break;
        }
        j++;
      }
      out.add(_MdSeg(line.substring(i, j), str, null, {}, null));
      i = j;
      continue;
    }
    if (c >= 0x30 && c <= 0x39) {
      flush();
      var j = i;
      while (j < line.length) {
        final d = line.codeUnitAt(j);
        if ((d >= 0x30 && d <= 0x39) ||
            d == 0x2E ||
            d == 0x5F ||
            d == 0x78 ||
            d == 0x58 ||
            (d >= 0x41 && d <= 0x46) ||
            (d >= 0x61 && d <= 0x66)) {
          j++;
        } else {
          break;
        }
      }
      out.add(_MdSeg(line.substring(i, j), num, null, {}, null));
      i = j;
      continue;
    }
    if (ident(c)) {
      var j = i;
      while (j < line.length && ident(line.codeUnitAt(j))) {
        j++;
      }
      final word = line.substring(i, j);
      flush();
      if (kws.contains(word)) {
        out.add(_MdSeg(word, kw, null, {}, null));
      } else {
        out.add(_MdSeg(word, null, null, {}, null));
      }
      i = j;
      continue;
    }
    buf.writeCharCode(c);
    i++;
  }
  flush();
  if (out.isEmpty) out.add(_MdSeg('', null, null, {}, null));
  return out;
}

/// Inline runs for prose [text] (bold/italic/strike/code/links).
List<_MdSeg> _mdInline(String text) {
  final out = <_MdSeg>[];
  // Code spans first (no formatting inside).
  final parts = <Object>[text];
  final codeRe = RegExp(r'`([^`\n]+)`');
  for (var k = 0; k < parts.length; k++) {
    final part = parts[k];
    if (part is! String) continue;
    final m = codeRe.firstMatch(part);
    if (m == null) continue;
    parts.replaceRange(k, k + 1, [
      part.substring(0, m.start),
      _MdSeg(m.group(1)!, null, null, const {Style.reverse}, null),
      part.substring(m.end),
    ]);
  }
  // Links.
  final linkRe = RegExp(r'\[([^\]]*)\]\(([^)\s]+)\)');
  for (var k = 0; k < parts.length; k++) {
    final part = parts[k];
    if (part is! String) continue;
    final m = linkRe.firstMatch(part);
    if (m == null) continue;
    parts.replaceRange(k, k + 1, [
      part.substring(0, m.start),
      _MdSeg(m.group(1)!, null, null, const {Style.underline}, m.group(2)),
      part.substring(m.end),
    ]);
  }
  for (final part in parts) {
    if (part is _MdSeg) {
      out.add(part);
    } else if ((part as String).isNotEmpty) {
      out.addAll(_mdEmph(part, {}));
    }
  }
  return out;
}

List<_MdSeg> _mdEmph(String text, Set<Style> base) {
  const opens = ['**', '__', '~~', '*', '_'];
  final out = <_MdSeg>[];
  var i = 0;
  var plain = StringBuffer();
  void textOut(String s) {
    if (s.isNotEmpty) out.add(_MdSeg(s, null, null, base, null));
  }

  while (i < text.length) {
    String? mark;
    for (final o in opens) {
      if (text.startsWith(o, i)) {
        mark = o;
        break;
      }
    }
    if (mark == null) {
      plain.writeCharCode(text.codeUnitAt(i));
      i++;
      continue;
    }
    final bit = switch (mark) {
      '**' || '__' => Style.bold,
      '~~' => Style.strike,
      _ => Style.italic,
    };
    final close = text.indexOf(mark, i + mark.length);
    textOut(plain.toString());
    plain.clear();
    if (close < 0) {
      // Unclosed emphasis renders as if closed (streaming-safe).
      out.addAll(_mdEmph(
          text.substring(i + mark.length), {...base, bit}));
      i = text.length;
    } else {
      out.addAll(_mdEmph(
          text.substring(i + mark.length, close), {...base, bit}));
      i = close + mark.length;
    }
  }
  textOut(plain.toString());
  return out;
}

/// Wrap segments to [width] with hanging [indent] on continuations.
List<List<_MdSeg>> _mdWrap(List<_MdSeg> segs, int width, int indent) {
  final lines = <List<_MdSeg>>[];
  var line = <_MdSeg>[];
  var used = 0;
  var start = 0; // where words begin on this line
  var space = false; // the source had a space before the next word
  for (final seg in segs) {
    final words = seg.text.split(' ');
    for (var k = 0; k < words.length; k++) {
      if (k > 0) space = true;
      final word = words[k];
      if (word.isEmpty) continue;
      final w = term.displayWidth(word);
      final gap = space && used > start ? 1 : 0;
      if (used + gap + w > width && used > start) {
        lines.add(line);
        line = [];
        used = start = indent;
      } else if (gap == 1) {
        line.add(_MdSeg(' ', seg.fg, seg.bg, seg.style, seg.link));
        used++;
      }
      line.add(_MdSeg(word, seg.fg, seg.bg, seg.style, seg.link));
      used += w;
      space = false;
    }
  }
  lines.add(line);
  return lines;
}

/// Code lines keep their spaces and break at [width] cells.
List<List<_MdSeg>> _mdHard(List<_MdSeg> segs, int width) {
  final lines = <List<_MdSeg>>[];
  var line = <_MdSeg>[];
  var used = 0;
  for (final seg in segs) {
    var part = StringBuffer();
    for (final rune in seg.text.runes) {
      final w = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
      if (used + w > width && used > 0) {
        if (part.isNotEmpty) {
          line.add(_MdSeg('$part', seg.fg, seg.bg, seg.style, seg.link));
        }
        lines.add(line);
        line = [];
        used = 0;
        part = StringBuffer();
      }
      part.writeCharCode(rune);
      used += w;
    }
    if (part.isNotEmpty) {
      line.add(_MdSeg('$part', seg.fg, seg.bg, seg.style, seg.link));
    }
  }
  lines.add(line);
  return lines;
}

/// Lay out [source] at [width] into styled lines (cached).
List<List<_MdSeg>> _mdLayout(
    String source, int width, bool ascii, _Session<Object?> session) {
  final key = '$width:${ascii ? 1 : 0}\n$source';
  final hit = session._mdCache[key];
  if (hit != null) return hit;
  final lines = _mdRender(source, width, ascii);
  final cache = session._mdCache;
  if (cache.length > 64) cache.clear();
  cache[key] = lines;
  return lines;
}

List<List<_MdSeg>> _mdRender(String source, int width, bool ascii) {
  final out = <List<_MdSeg>>[];
  var src = source;
  if (src.endsWith('\n')) src = src.substring(0, src.length - 1);
  final raw = src.split('\n');
  var i = 0;
  bool blank(String s) => s.trim().isEmpty;

  while (i < raw.length) {
    final line = raw[i];
    final trim = line.trimLeft();
    // Fenced code.
    if (trim.startsWith('```')) {
      final lang = _mdLang(trim.substring(3));
      i++;
      final code = <String>[];
      while (i < raw.length && !raw[i].trimLeft().startsWith('```')) {
        code.add(raw[i]);
        i++;
      }
      if (i < raw.length) i++; // closing fence
      final block = [false];
      for (final cl in code) {
        final segs = _mdHighlight(cl, lang, block);
        out.addAll(_mdHard(segs, width));
      }
      if (code.isEmpty) out.add([]);
      continue;
    }
    // Heading.
    final head = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (head != null) {
      final styled = _mdInline(head.group(2) ?? '');
      out.addAll(_mdWrap(
          [for (final s in styled) _MdSeg(s.text, s.fg, s.bg, {...s.style, Style.bold}, s.link)],
          width,
          0));
      i++;
      continue;
    }
    // Rule.
    if (RegExp(r'^\s*(---|\*\*\*|___)\s*$').hasMatch(line)) {
      out.add([
        _MdSeg((ascii ? '-' : '─') * math.max(1, width), null, null, {},
            null)
      ]);
      i++;
      continue;
    }
    // Quote.
    if (RegExp(r'^\s*>').hasMatch(line)) {
      final inner = <String>[];
      while (i < raw.length && RegExp(r'^\s*>').hasMatch(raw[i])) {
        inner.add(raw[i].replaceFirst(RegExp(r'^\s*>\s?'), ''));
        i++;
      }
      for (final il in inner) {
        for (final wl in _mdWrap(_mdInline(il), width - 2, 0)) {
          out.add([
            const _MdSeg('> ', null, null, {Style.dim}, null),
            ...wl
          ]);
        }
      }
      continue;
    }
    // Table.
    if (line.contains('|') && i + 1 < raw.length && _mdSep(raw[i + 1])) {
      final headCells = _mdCells(line);
      i += 2;
      final rows = <List<String>>[];
      while (i < raw.length && raw[i].contains('|') && !blank(raw[i])) {
        rows.add(_mdCells(raw[i]));
        i++;
      }
      out.addAll(_mdTable(headCells, rows, width, ascii));
      continue;
    }
    // List.
    final lm = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$').firstMatch(line);
    if (lm != null) {
      final items = <(int, bool, String, String)>[];
      while (i < raw.length) {
        final m =
            RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$').firstMatch(raw[i]);
        if (m == null) break;
        final indent = m.group(1)!.replaceAll('\t', '  ').length;
        final marker = m.group(2)!;
        items.add((
          indent ~/ 2,
          RegExp(r'^\d').hasMatch(marker),
          marker,
          m.group(3) ?? ''
        ));
        i++;
      }
      for (final (level, ordered, marker, text) in items) {
        final bullet = ordered ? '$marker ' : '${ascii ? '-' : '•'} ';
        final indent = level * 2;
        final pre = ' ' * indent + bullet;
        var firstLine = true;
        for (final wl in _mdWrap(
            _mdInline(text), width - term.displayWidth(pre), 0)) {
          out.add([
            _MdSeg(firstLine ? pre : ' ' * (indent + 2), null, null, {},
                null),
            ...wl
          ]);
          firstLine = false;
        }
      }
      continue;
    }
    // Paragraph.
    if (blank(line)) {
      i++;
      continue;
    }
    final para = <String>[];
    while (i < raw.length &&
        !blank(raw[i]) &&
        !raw[i].trimLeft().startsWith('```') &&
        RegExp(r'^(#{1,6})\s+').firstMatch(raw[i]) == null &&
        RegExp(r'^\s*(---|\*\*\*|___)\s*$').firstMatch(raw[i]) == null &&
        RegExp(r'^\s*>').firstMatch(raw[i]) == null &&
        RegExp(r'^(\s*)([-*+]|\d+[.)])\s+').firstMatch(raw[i]) == null) {
      para.add(raw[i].trim());
      i++;
    }
    out.addAll(_mdWrap(_mdInline(para.join(' ')), width, 0));
  }
  return out;
}

bool _mdSep(String line) {
  final t = line.trim();
  if (!t.contains('|') || !t.contains('-')) return false;
  return RegExp(r'^[\s|:\-]+$').hasMatch(t);
}

List<String> _mdCells(String line) {
  var cells = line.split('|').map((c) => c.trim()).toList();
  if (cells.isNotEmpty && cells.first.isEmpty) {
    cells = cells.sublist(1);
  }
  if (cells.isNotEmpty && cells.last.isEmpty) {
    cells = cells.sublist(0, cells.length - 1);
  }
  return cells;
}

List<List<_MdSeg>> _mdTable(
    List<String> head, List<List<String>> rows, int width, bool ascii) {
  final n = math.max(
      head.length, rows.fold<int>(0, (m, r) => math.max(m, r.length)));
  if (n == 0) return [];
  final widths = List<int>.filled(n, 3);
  String cell(List<String> r, int k) => k < r.length ? r[k] : '';
  for (var k = 0; k < n; k++) {
    var m = term.displayWidth(cell(head, k));
    for (final r in rows) {
      m = math.max(m, term.displayWidth(cell(r, k)));
    }
    widths[k] = math.max(3, m);
  }
  var total = widths.fold(0, (a, b) => a + b) + 3 * (n - 1) + 4;
  while (total > width) {
    var cut = -1;
    var best = 3;
    for (var k = 0; k < n; k++) {
      if (widths[k] > best) {
        best = widths[k];
        cut = k;
      }
    }
    if (cut < 0) break;
    widths[cut]--;
    total--;
  }
  final vb = ascii ? '|' : '│';
  List<_MdSeg> row(List<String> cells, Set<Style> st) {
    final segs = <_MdSeg>[_MdSeg('$vb ', null, null, {}, null)];
    for (var k = 0; k < n; k++) {
      if (k > 0) segs.add(_MdSeg(' $vb ', null, null, {}, null));
      final t = term.truncateWidth(cell(cells, k), widths[k]);
      segs.add(_MdSeg(t, null, null, st, null));
      segs.add(_MdSeg(
          ' ' * math.max(0, widths[k] - term.displayWidth(t)), null, null,
          st, null));
    }
    segs.add(_MdSeg(' $vb', null, null, {}, null));
    return segs;
  }

  List<_MdSeg> rule(String l, String m, String r) {
    if (ascii) l = m = r = '+';
    final b = StringBuffer(l);
    for (var k = 0; k < n; k++) {
      if (k > 0) b.write(m);
      b.write((ascii ? '-' : '─') * (widths[k] + 2));
    }
    b.write(r);
    return [_MdSeg(b.toString(), null, null, {}, null)];
  }

  return [
    rule('┌', '┬', '┐'),
    row(head, const {Style.bold}),
    rule('├', '┼', '┤'),
    for (final r in rows) row(r, const {}),
    rule('└', '┴', '┘'),
  ];
}

/// Human-readable byte counts and rates for the status row's bridge bars.
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

String _fmtRate(double bytesPerSec) {
  if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

String _fmtCount(double perSec) {
  if (perSec < 100) return perSec.toStringAsFixed(1);
  return perSec.toStringAsFixed(0);
}

/// One inline markdown run.
final class _MdSeg {
  const _MdSeg(this.text, this.fg, this.bg, this.style, this.link);

  final String text;
  final Color? fg;
  final Color? bg;
  final Set<Style> style;
  final String? link;
}

/// A diff output row segment.
final class _DiffSeg {
  _DiffSeg(this.text, this.fg, this.bg, this.style);

  final String text;
  final Color? fg;
  final Color? bg;
  final Set<Style> style;
}

/// Myers O(ND) line diff, rendered as unified hunks: 3 context lines,
/// gutter line numbers, `-`/`+` rows on red/green, changed words of paired
/// lines brighter.
List<List<_DiffSeg>> _diffHunks(List<String> a, List<String> b) {
  // Strip one trailing empty from a trailing newline, like write().
  if (a.isNotEmpty && a.last.isEmpty) a = a.sublist(0, a.length - 1);
  if (b.isNotEmpty && b.last.isEmpty) b = b.sublist(0, b.length - 1);
  final script = _myers(a, b);
  // Group into hunks with 3 context lines.
  final hunks = <List<List<_DiffSeg>>>[];
  var hunk = <List<_DiffSeg>>[];
  var ai = 0, bi = 0; // line numbers consumed
  void flush() {
    if (hunk.isNotEmpty) {
      if (hunks.isNotEmpty) hunks.add([[_DiffSeg('…', null, null, {})]]);
      hunks.add(hunk);
      hunk = [];
    }
  }

  // First pass: collect change blocks with context.
  final blocks = <(int, int, int, int)>[]; // (aStart, aEnd, bStart, bEnd)
  var k = 0;
  while (k < script.length) {
    if (script[k] == 0) {
      ai++;
      bi++;
      k++;
      continue;
    }
    final a0 = ai, b0 = bi;
    while (k < script.length && script[k] != 0) {
      if (script[k] < 0) {
        ai++;
      } else {
        bi++;
      }
      k++;
    }
    blocks.add((a0, ai, b0, bi));
  }
  // Merge blocks separated by <= 6 context lines (3+3).
  final merged = <(int, int, int, int)>[];
  for (final blk in blocks) {
    if (merged.isNotEmpty &&
        blk.$1 - merged.last.$2 <= 6 &&
        blk.$3 - merged.last.$4 <= 6) {
      final last = merged.removeLast();
      merged.add((last.$1, blk.$2, last.$3, blk.$4));
    } else {
      merged.add(blk);
    }
  }
  for (final (a0, a1, b0, b1) in merged) {
    hunk = [];
    final ca0 = math.max(0, a0 - 3);
    final cb0 = math.max(0, b0 - 3);
    // Leading context (show `a` numbering; both sides agree here).
    for (var t = 0; t < a0 - ca0; t++) {
      hunk.add(
          _diffRow(' ', ca0 + t + 1, cb0 + t + 1, a[ca0 + t], const {}));
    }
    // Paired -/+ lines get word-bright pairs.
    var da = a0, db = b0;
    while (da < a1 || db < b1) {
      if (da < a1 && db < b1) {
        hunk.addAll(_diffPair(a[da], da + 1, b[db], db + 1));
        da++;
        db++;
      } else if (da < a1) {
        hunk.add(_diffRow('-', da + 1, null, a[da],
            const {Style.bold}, del: true));
        da++;
      } else {
        hunk.add(_diffRow('+', null, db + 1, b[db],
            const {Style.bold}, del: false));
        db++;
      }
    }
    // Trailing context.
    var t = 0;
    while (t < 3 && a1 + t < a.length && b1 + t < b.length) {
      hunk.add(
          _diffRow(' ', a1 + t + 1, b1 + t + 1, a[a1 + t], const {}));
      t++;
    }
    flush();
  }
  return hunks.expand((h) => h).toList();
}

/// Myers diff as opcodes per consumed line: 0 same, -1 delete, +1 insert.
/// (Compares `a` and `b` line by line.)
List<int> _myers(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  if (n == 0) return List.filled(m, 1);
  if (m == 0) return List.filled(n, -1);
  final max = n + m;
  final v = <int, int>{1: 0};
  final trace = <Map<int, int>>[];
  outer:
  for (var d = 0; d <= max; d++) {
    final cur = <int, int>{};
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && (v[k - 1] ?? -1) < (v[k + 1] ?? -1))) {
        x = v[k + 1] ?? 0;
      } else {
        x = (v[k - 1] ?? 0) + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      cur[k] = x;
      if (x >= n && y >= m) {
        trace.add(cur);
        break outer;
      }
    }
    trace.add(Map.of(cur));
    v
      ..clear()
      ..addAll(cur);
  }
  // Backtrack to opcodes.
  final ops = <int>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d > 0; d--) {
    final prev = trace[d - 1];
    final k = x - y;
    final down =
        (k == -d || (k != d && (prev[k - 1] ?? -1) < (prev[k + 1] ?? -1)));
    final kPrev = down ? k + 1 : k - 1;
    final xPrev = prev[kPrev] ?? (down ? 0 : -1);
    final yPrev = xPrev - kPrev;
    while (x > xPrev && y > yPrev) {
      ops.add(0);
      x--;
      y--;
    }
    if (down) {
      ops.add(1);
      y--;
    } else {
      ops.add(-1);
      x--;
    }
    x = xPrev;
    y = yPrev;
  }
  while (x > 0 && y > 0) {
    ops.add(0);
    x--;
    y--;
  }
  while (x > 0) {
    ops.add(-1);
    x--;
  }
  while (y > 0) {
    ops.add(1);
    y--;
  }
  return ops.reversed.toList();
}

List<_DiffSeg> _diffRow(String mark, int? aNo, int? bNo, String text,
    Set<Style> extra, {bool? del}) {
  final gutter =
      '${(aNo?.toString() ?? '').padLeft(4)} ${(bNo?.toString() ?? '').padLeft(4)} $mark ';
  final fg = del == null
      ? null
      : del
          ? Color.red
          : Color.green;
  final bg = del == null
      ? null
      : del
          ? const Color._(52, null)
          : const Color._(22, null);
  return [
    _DiffSeg(gutter, fg, null, {...extra}),
    _DiffSeg(text, fg, bg, extra),
  ];
}

/// A `-`/`+` pair with changed words brighter.
List<List<_DiffSeg>> _diffPair(
    String aText, int aNo, String bText, int bNo) {
  final aw = aText.split(' ');
  final bw = bText.split(' ');
  final ops = _myers(aw, bw);
  var ai = 0, bi = 0;
  final aSegs = <_DiffSeg>[];
  final bSegs = <_DiffSeg>[];
  for (final op in ops) {
    if (op == 0) {
      aSegs.add(_DiffSeg('${aw[ai]} ', Color.red, const Color._(52, null),
          const {Style.bold}));
      bSegs.add(_DiffSeg('${bw[bi]} ', Color.green, const Color._(22, null),
          const {Style.bold}));
      ai++;
      bi++;
    } else if (op < 0) {
      aSegs.add(_DiffSeg('${aw[ai]} ', Color.red, const Color._(52, null),
          const {Style.bold, Style.reverse}));
      ai++;
    } else {
      bSegs.add(_DiffSeg('${bw[bi]} ', Color.green, const Color._(22, null),
          const {Style.bold, Style.reverse}));
      bi++;
    }
  }
  List<_DiffSeg> row(
      String mark, int? aN, int? bN, List<_DiffSeg> segs, Color fg) {
    final gutter =
        '${(aN?.toString() ?? '').padLeft(4)} ${(bN?.toString() ?? '').padLeft(4)} $mark ';
    return [_DiffSeg(gutter, fg, null, const {Style.bold}), ...segs];
  }

  return [
    row('-', aNo, null, aSegs, Color.red),
    row('+', null, bNo, bSegs, Color.green),
  ];
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
      {this.onMap, this.fixed = false});

  /// Inside a popup: screen coordinates, never shifted by inline layout.
  final bool fixed;

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
  _KeyEv(this.name, {this.text, this.paste = false, this.fallback = false});

  final String name;
  final String? text;
  final bool paste;

  /// Routing rule 5: offered to a drawn widget that isn't focused.
  final bool fallback;
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

/// Open suggest-completion state for one [Field].
final class _Suggest {
  _Suggest(this.field);

  final Field field;
  String word = '';
  int wordStart = 0;
  List<String> matches = const [];
  var index = 0;
  var gen = 0;
  var open = false;
}

/// A Console prompt shown as a modal popup (ask/confirm/choose).
final class _Prompt {
  _Prompt.ask(this.question, this.secret)
      : kind = 0,
        choices = const [],
        completer = Completer<String>();

  _Prompt.confirm(this.question)
      : kind = 1,
        secret = false,
        choices = const [],
        completer = Completer<bool>();

  _Prompt.choose(this.question, this.choices)
      : kind = 2,
        secret = false,
        completer = Completer<String>();

  final int kind; // 0 ask, 1 confirm, 2 choose
  final String question;
  final bool secret;
  final List<String> choices;
  final Field field = Field();
  final Pick<int> pick = Pick<int>();
  String? error;
  final Completer<Object> completer; // String (ask/choose) or bool (confirm)
}

/// A Console progress bar mirrored into the status row.
final class _CBridge {
  _CBridge(this.total, this.label) : start = DateTime.now();

  final int? total;
  final String? label;
  var done = 0;
  var bytes = false;
  final DateTime start;
}

bool _isWordSuggestChar(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x41 && r <= 0x5A) ||
    r == 0x5F ||
    (r >= 0x61 && r <= 0x7A) ||
    r == 0x40 ||
    r == 0x2F ||
    r == 0x3A ||
    r == 0x2E ||
    r == 0x2B ||
    r == 0x2D;

/// The live session behind [Tui.run] and the test harness.
final class _Session<S> implements term.TuiBridge {
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
  final _drawnFields = <Field>{};
  final _clickBase = <Field, int>{};
  final _suggests = <Field, _Suggest>{};
  _Suggest? _activeSg;
  final _prompts = <_Prompt>[];
  final _cSpinners = <Object, String>{};
  final _cBars = <Object, _CBridge>{};
  var _termFocused = true;
  var _usedRows = 0;
  var _statusY = 23;

  // Open-layout measuring (see [_measured]).
  List<int>? _mSlots;
  var _mNext = 0;
  final _mPending = <void Function()>[];
  final _mBuild = <int, int>{};
  var _refocused = false;
  var _liveH = 0;
  int _curR = -1;
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
        // Wake after the callback ran, so the redraw sees what it changed.
        scheduleMicrotask: (self, parent, zone, f) {
          parent.scheduleMicrotask(zone, () {
            try {
              f();
            } finally {
              _dirtyAndWake();
            }
          });
        },
        createTimer: (self, parent, zone, duration, f) =>
            parent.createTimer(zone, duration, () {
              try {
                f();
              } finally {
                _dirtyAndWake();
              }
            }),
        createPeriodicTimer: (self, parent, zone, period, f) =>
            parent.createPeriodicTimer(zone, period, (timer) {
              try {
                f(timer);
              } finally {
                _dirtyAndWake();
              }
            }),
        // Stream and I/O callbacks (socket data, a reply's listen).
        runUnary: <R, T>(self, parent, zone, R Function(T) f, T arg) {
          try {
            return parent.runUnary(zone, f, arg);
          } finally {
            _dirtyAndWake();
          }
        },
        handleUncaughtError: (self, parent, zone, e, st) {
          // Escape in a Console prompt ends the handler silently.
          if (e is io.StdinException) {
            _dirtyAndWake();
            return;
          }
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
    // Handlers run in the redraw zone; the loop itself stays outside it, or
    // its own timers and awaits would wake it forever and starve I/O.
    runZoned(() => _zone = Zone.current, zoneSpecification: _spec());
    await _enter();
    try {
      await _loop();
      return _state;
    } finally {
      await _leave();
    }
  }

  Future<void> _loop() async {
    _draw();
    _paintNow();
    while (!_quitFlag) {
      if (_fatal != null) {
        final e = _fatal!;
        final st = _fatalStack ?? StackTrace.empty;
        _fatal = null;
        Error.throwWithStackTrace(e, st);
      }
      final active = _activeH > 0 ||
          _spinVisible ||
          _cSpinners.isNotEmpty ||
          _cBars.isNotEmpty;
      _waker ??= Completer<void>();
      final w = _waker!;
      // Wake on an event, or: when a redraw waits out the 60 fps gap, when
      // a held ESC or split sequence needs another look, or for the next
      // spinner frame.
      final wait = _dirty
          ? math.max(0, 16 - (_now() - _lastPaint))
          : _pending.isNotEmpty
              ? 30
              : active
                  ? 80
                  : null;
      if (wait == null) {
        await w.future;
      } else {
        try {
          await w.future.timeout(Duration(milliseconds: wait));
        } on TimeoutException {
          if (!_dirty && _pending.isEmpty) {
            _spinTick++;
            _dirty = true;
          }
        }
      }
      if (identical(_waker, w)) _waker = null;
      _pollInput();
      if (_dirty && _now() - _lastPaint >= 16) {
        _dirty = false;
        _draw();
        _paintNow();
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
          _paintNow();
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
    _sayMsg = null;
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
    _error = null;
    _dirtyAndWake();
  }

  void _print(void Function(Region r) draw) {
    if (fullscreen) throw StateError('print needs inline mode');
    _printInline(draw);
  }

  /// Render [draw] at full width and commit it above the live area.
  void _printInline(void Function(Region r) draw) {
    if (_curR >= 0) {
      out('\r\x1b[${_liveH - _curR}B');
      _curR = -1;
    }
    final buf = <List<_Cell>>[List.filled(_w, _Cell.blank)];
    final nf = _focusables.length,
        np = _popups.length,
        ns = _scrolls.length,
        no = _order;
    void restore() {
      _focusables.length = nf;
      _popups.length = np;
      _scrolls.length = ns;
      _order = no;
    }

    _measured(() {
      draw(Region._(this, buf, 0, 0, _w, _unbounded, grow: true, open: true));
    }, () {
      restore();
      buf
        ..clear()
        ..add(List.filled(_w, _Cell.blank));
    });
    restore();
    var n = buf.length;
    while (n > 0 && buf[n - 1].every((c) => c == _Cell.blank)) {
      n--;
    }
    final sb = StringBuffer();
    if (_liveH > 0) sb.write('\r\x1b[${_liveH}A\x1b[J');
    for (var r = 0; r < n; r++) {
      sb.write('\r\x1b[2K');
      sb.write(_renderRow(buf[r]));
      sb.write('\n');
    }
    out(sb.toString());
    _liveH = 0;
    _dirtyAndWake();
  }

  /// One grid row rendered with SGR (no cursor addressing).
  String _renderRow(List<_Cell> row) {
    final buf = StringBuffer();
    var curSgr = '';
    String? link;
    for (final c in row) {
      if (c.width == 0) continue;
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
    }
    if (link != null) buf.write('\x1b]8;;\x1b\\');
    buf.write('\x1b[0m');
    return buf.toString().trimRight();
  }

  void _notify(String message) {
    // No-op while the terminal has focus.
    if (_termFocused) return;
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

  // --- term.TuiBridge (Console-in-Tui routing) -----------------------------

  @override
  Object spinStarted(String label) {
    final id = Object();
    _cSpinners[id] = label;
    // New work replaces a stale message, so its progress shows.
    _sayMsg = _error = null;
    _dirtyAndWake();
    return id;
  }

  @override
  void spinEnded(Object id, bool ok) {
    final label = _cSpinners.remove(id);
    if (!ok && label != null) _error = '✗ $label'.trimRight();
    _dirtyAndWake();
  }

  @override
  Object barStarted(int? total, String? label) {
    final id = Object();
    _cBars[id] = _CBridge(total, label);
    _sayMsg = _error = null;
    _dirtyAndWake();
    return id;
  }

  @override
  void barMode(Object id, bool bytes) {
    final bar = _cBars[id];
    if (bar != null) bar.bytes = bytes;
  }

  @override
  void barTick(Object id, int count) {
    final bar = _cBars[id];
    if (bar == null) return;
    bar.done += count;
    final total = bar.total;
    if (total != null && total > 0 && bar.done > total) bar.done = total;
    _dirtyAndWake();
  }

  @override
  void barEnded(Object id, bool ok) {
    final bar = _cBars.remove(id);
    if (!ok && bar != null) _error = '✗ ${bar.label ?? ''}'.trimRight();
    _dirtyAndWake();
  }

  @override
  Future<String> promptAsk(String question, {required bool secret}) {
    final p = _Prompt.ask(question, secret);
    _prompts.add(p);
    _dirtyAndWake();
    return p.completer.future.then((v) => v as String);
  }

  @override
  Future<bool> promptConfirm(String question) {
    final p = _Prompt.confirm(question);
    _prompts.add(p);
    _dirtyAndWake();
    return p.completer.future.then((v) => v as bool);
  }

  @override
  Future<String> promptChoose(String question, List<String> choices) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    final p = _Prompt.choose(question, choices);
    p.pick.set(List<int>.generate(choices.length, (k) => k));
    _prompts.add(p);
    _dirtyAndWake();
    return p.completer.future.then((v) => v as String);
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
      {Map<String, Bind>? onMap, bool fixed = false}) {
    _focusables.add(
        _F(id, x, y, w, h, order, tryKey, onMap: onMap, fixed: fixed));
  }

  int _listStart(Object id, int n, int h) =>
      _listStarts[id]?.clamp(0, math.max<int>(0, n - h)) ?? 0;

  void _listStartSave(Object id, int start) => _listStarts[id] = start;

  final _styleCache = <String, int>{};
  final _styleReverse = <int, (Color?, Color?, int)>{};
  final _mdCache = <String, List<List<_MdSeg>>>{};

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
        case term.TermClick(:final x, :final y, :final kind):
          _mouse = (x, y);
          _clickAt(kind, x, y);
        case term.TermHover(:final x, :final y):
          _mouse = (x, y);
          _dirtyAndWake();
        case term.TermFocus(:final gained):
          _termFocused = gained;
          _fireLifecycle(gained ? 'focus' : 'blur');
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
    // Fast typing arrives as one chunk: route it a character at a time, so
    // bindings and focus apply to each.
    if (!paste && text.runes.length > 1) {
      for (final r in text.runes) {
        _routeText(String.fromCharCode(r), false);
      }
      return;
    }
    if (_prompts.isNotEmpty) {
      _promptRouteText(text, paste);
      return;
    }
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
      // Screen keys before the rule-5 input fallback (mirrors 4-before-5);
      // a focused input (rule 2) takes its text first.
      final b = fid is Field ? null : _lookup(_keys, nm);
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
    // 1. Open popup (suggest list, Console prompts).
    if (_routeSuggest(name)) return true;
    if (_prompts.isNotEmpty && _promptKey(_prompts.last, name)) return true;
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
      if (f.tryKey != null && f.tryKey!(_KeyEv(name, fallback: true))) {
        return true;
      }
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
    if (_prompts.isNotEmpty) return _promptMouse(kind, x, y);
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
    if (_prompts.isNotEmpty) {
      final p = _prompts.last;
      if (p.kind == 2) {
        return _promptKey(p, dir < 0 ? 'wheelup' : 'wheeldown');
      }
      return true; // modal: swallow
    }
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

  /// Refresh the suggest popup for [field] from the word at its cursor.
  void _refreshSuggest(
      Field field, FutureOr<List<String>> Function(String word)? fn) {
    if (fn == null) return;
    final sg = _suggests.putIfAbsent(field, () => _Suggest(field));
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    var start = at;
    while (start > 0 && _isWordSuggestChar(runes[start - 1])) {
      start = _prevCluster(runes, start);
    }
    var end = at;
    while (end < runes.length && _isWordSuggestChar(runes[end])) {
      end = _nextCluster(runes, end);
    }
    final word = String.fromCharCodes(runes.sublist(start, end));
    if (word.isEmpty) {
      sg.open = false;
      if (identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    // Same word: nothing new to ask (and an escaped popup stays closed).
    if (word == sg.word && start == sg.wordStart) return;
    sg.word = word;
    sg.wordStart = start;
    final gen = ++sg.gen;
    FutureOr<List<String>> result;
    try {
      result = fn(word);
    } catch (_) {
      if (sg.gen == gen) sg.open = false;
      if (identical(_activeSg, sg) && !sg.open) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    if (result is Future<List<String>>) {
      result.then((matches) {
        if (sg.gen != gen) return; // stale async answer: drop
        sg.matches = matches.length > 10 ? matches.sublist(0, 10) : matches;
        sg.index = 0;
        sg.open = sg.matches.isNotEmpty;
        if (!sg.open && identical(_activeSg, sg)) _activeSg = null;
        _dirtyAndWake();
      }, onError: (_) {
        if (sg.gen == gen) {
          sg.open = false;
          if (identical(_activeSg, sg)) _activeSg = null;
          _dirtyAndWake();
        }
      });
    } else {
      sg.matches = result.length > 10 ? result.sublist(0, 10) : result;
      sg.index = 0;
      sg.open = sg.matches.isNotEmpty;
      if (!sg.open && identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
    }
  }

  void _acceptSuggest(_Suggest sg) {
    if (sg.matches.isEmpty) {
      sg.open = false;
      if (identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    final field = sg.field;
    final runes = field._text.runes.toList();
    // Replace [wordStart, cursor) with the match.
    final at = field._cursor.clamp(0, runes.length);
    runes.removeRange(sg.wordStart.clamp(0, at), at);
    final match = sg.matches[sg.index.clamp(0, sg.matches.length - 1)];
    runes.insertAll(sg.wordStart.clamp(0, runes.length), match.runes);
    field._text = String.fromCharCodes(runes);
    field._cursor = sg.wordStart + match.runes.length;
    field._wantCol = -1;
    sg.word = match;
    sg.open = false;
    if (identical(_activeSg, sg)) _activeSg = null;
    _dirtyAndWake();
  }

  /// Route a key to the open suggest popup, if any drawn field has one.
  /// Returns true when consumed.
  bool _routeSuggest(String name) {
    final sg = _activeSg;
    if (sg == null || !sg.open || sg.matches.isEmpty) return false;
    switch (name) {
      case 'up':
        sg.index =
            (sg.index - 1 + sg.matches.length) % sg.matches.length;
        _dirtyAndWake();
        return true;
      case 'down':
        sg.index = (sg.index + 1) % sg.matches.length;
        _dirtyAndWake();
        return true;
      case 'tab':
      case 'enter':
        _acceptSuggest(sg);
        return true;
      case 'escape':
        sg.open = false;
        _activeSg = null;
        _dirtyAndWake();
        return true;
    }
    return false;
  }

  /// Draw the suggest popup for [field] near its cursor (buffer coords
  /// [cpos] in [region]), if its matches are open.
  void _drawSuggestPopup(
      Field field, Region region, (int, int)? cpos) {
    final sg = _suggests[field];
    if (sg == null || !sg.open || sg.matches.isEmpty || cpos == null) {
      if (sg != null && identical(_activeSg, sg)) _activeSg = null;
      return;
    }
    final sp = region._toScreen(cpos.$1, cpos.$2);
    if (sp == null) {
      if (identical(_activeSg, sg)) _activeSg = null;
      return;
    }
    _activeSg = sg;
    var mw = 0;
    for (final m in sg.matches) {
      mw = math.max(mw, term.displayWidth(m));
    }
    final w = (mw + 4).clamp(8, math.min<int>(40, _w));
    final h = math.min<int>(sg.matches.length + 2, math.max<int>(3, _h));
    var y = sp.$2 + 1;
    if (y + h > _h) y = sp.$2 - h;
    y = y.clamp(0, math.max<int>(0, _h - h));
    var x = sp.$1.clamp(0, math.max<int>(0, _w - w));
    final buf = <List<_Cell>>[
      for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)
    ];
    final ascii = _caps.ascii;
    final (hz, vt, tl, tr, bl, br) = ascii
        ? ('-', '|', '+', '+', '+', '+')
        : ('─', '│', '┌', '┐', '└', '┘');
    void raw(int r, int c, String ch) {
      if (r >= 0 && r < h && c >= 0 && c < w) buf[r][c] = _Cell(ch, 0, 1);
    }

    for (var cx = 0; cx < w; cx++) {
      raw(0, cx, hz);
      raw(h - 1, cx, hz);
    }
    for (var ry = 0; ry < h; ry++) {
      raw(ry, 0, vt);
      raw(ry, w - 1, vt);
    }
    raw(0, 0, tl);
    raw(0, w - 1, tr);
    raw(h - 1, 0, bl);
    raw(h - 1, w - 1, br);
    final rows = h - 2;
    var start = sg.index - rows + 1;
    if (start < 0) start = 0;
    for (var r = 0; r < rows && start + r < sg.matches.length; r++) {
      final idx = start + r;
      final sel = idx == sg.index;
      final st = _pack(null, sel ? accent : null, sel ? {Style.bold} : {});
      final label = term.truncateWidth(sg.matches[idx], math.max(1, w - 4));
      var col = 2;
      if (sel) {
        for (var c = 1; c < w - 1; c++) {
          buf[r + 1][c] = _Cell(' ', st, 1);
        }
      }
      for (final rune in label.runes) {
        if (col >= w - 1) break;
        if (rune < 0x20 || rune == 0x7f) continue;
        final cw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
        if (cw == 0 || col + cw > w - 1) continue;
        buf[r + 1][col] = _Cell(String.fromCharCode(rune), st, cw);
        if (cw == 2 && col + 1 < w - 1) {
          buf[r + 1][col + 1] = _Cell('', st, 0);
        }
        col += cw;
      }
    }
    _popups.add(_Popup(x, y, w, h, buf));
  }

  /// Route a key to the topmost Console prompt. Returns true when consumed
  /// (prompts are modal: everything is consumed while one is open).
  bool _promptKey(_Prompt p, String name) {
    if (p.kind == 2) {
      final n = p.choices.length;
      switch (name) {
        case 'up':
        case 'wheelup':
          if (n > 0) {
            p.pick.select(p.pick.index() - 1);
            _dirtyAndWake();
          }
          return true;
        case 'down':
        case 'wheeldown':
          if (n > 0) {
            p.pick.select(p.pick.index() + 1);
            _dirtyAndWake();
          }
          return true;
        case 'home':
          p.pick.select(0);
          _dirtyAndWake();
          return true;
        case 'end':
          p.pick.select(n - 1);
          _dirtyAndWake();
          return true;
        case 'enter':
          _prompts.remove(p);
          if (!p.completer.isCompleted) {
            p.completer.complete(
                n == 0 ? '' : p.choices[p.pick.index().clamp(0, n - 1)]);
          }
          _dirtyAndWake();
          return true;
        case 'escape':
          _prompts.remove(p);
          if (!p.completer.isCompleted) {
            p.completer.completeError(
                const io.StdinException('stdin is closed'));
          }
          _dirtyAndWake();
          return true;
      }
      return true; // modal: swallow the rest
    }
    switch (name) {
      case 'backspace':
        _promptDrop(p, -1);
        return true;
      case 'delete':
        _promptDrop(p, 1);
        return true;
      case 'left':
        p.field._cursor = _prevCluster(
            p.field._text.runes.toList(), p.field._cursor);
        _dirtyAndWake();
        return true;
      case 'right':
        p.field._cursor = _nextCluster(
            p.field._text.runes.toList(), p.field._cursor);
        _dirtyAndWake();
        return true;
      case 'home':
      case 'ctrl+a':
        p.field._cursor = 0;
        _dirtyAndWake();
        return true;
      case 'end':
      case 'ctrl+e':
        p.field._cursor = p.field._text.runes.length;
        _dirtyAndWake();
        return true;
      case 'ctrl+u':
      case 'ctrl+k':
      case 'ctrl+w':
      case 'alt+backspace':
        p.field.set('');
        _dirtyAndWake();
        return true;
      case 'enter':
        _submitPrompt(p);
        return true;
      case 'escape':
        _prompts.remove(p);
        if (!p.completer.isCompleted) {
          p.completer
              .completeError(const io.StdinException('stdin is closed'));
        }
        _dirtyAndWake();
        return true;
    }
    return true; // modal: swallow the rest
  }

  void _promptDrop(_Prompt p, int dir) {
    final runes = p.field._text.runes.toList();
    final at = p.field._cursor.clamp(0, runes.length);
    if (dir < 0) {
      final start = _prevCluster(runes, at);
      runes.removeRange(start, at);
      p.field._cursor = start;
    } else {
      final end = _nextCluster(runes, at);
      runes.removeRange(at, end);
    }
    p.field._text = String.fromCharCodes(runes);
    _dirtyAndWake();
  }

  void _promptText(_Prompt p, String text, bool paste) {
    final clean = paste
        ? text
            .replaceAll('\r\n', ' ')
            .replaceAll(RegExp('[\r\n\t]'), ' ')
            .replaceAll(RegExp('[\x00-\x1f\x7f]'), '')
        : text;
    final runes = p.field._text.runes.toList();
    final at = p.field._cursor.clamp(0, runes.length);
    runes.insertAll(at, clean.runes);
    p.field._text = String.fromCharCodes(runes);
    p.field._cursor = at + clean.runes.length;
    _dirtyAndWake();
  }

  void _submitPrompt(_Prompt p) {
    if (p.kind == 1) {
      final answer = p.field.text().trim().toLowerCase();
      if (answer == 'y' || answer == 'yes') {
        _prompts.remove(p);
        if (!p.completer.isCompleted) p.completer.complete(true);
      } else if (answer == 'n' ||
          answer == 'no' ||
          answer.isEmpty) {
        _prompts.remove(p);
        if (!p.completer.isCompleted) p.completer.complete(false);
      } else {
        p.error = 'please answer y or n';
      }
      _dirtyAndWake();
      return;
    }
    final text = p.field.text();
    _prompts.remove(p);
    if (!p.completer.isCompleted) p.completer.complete(text);
    _dirtyAndWake();
  }

  /// Route typed text to the topmost prompt (ask/confirm only).
  void _promptRouteText(String text, bool paste) {
    if (_prompts.isEmpty) return;
    final p = _prompts.last;
    if (p.kind == 2) return; // choose ignores typing
    _promptText(p, text, paste);
  }

  /// Route a mouse event to the topmost prompt. Always consumes (modal).
  bool _promptMouse(String kind, int x, int y) {
    if (_prompts.isEmpty) return false;
    final p = _prompts.last;
    if (p.kind == 2 && (kind == 'click' || kind == 'doubleclick')) {
      // Click a row to select it.
      final g = _promptGeometry(p);
      if (g != null) {
        final idx = y - (g.$2 + 2);
        if (idx >= 0 && idx < p.choices.length) {
          p.pick.select(idx);
          if (kind == 'doubleclick') {
            _prompts.remove(p);
            if (!p.completer.isCompleted) {
              p.completer.complete(p.choices[p.pick.index()]);
            }
          }
          _dirtyAndWake();
        }
      }
    }
    return true;
  }

  /// Screen geometry (x, y, w, h) of the topmost prompt popup, if drawn.
  (int, int, int, int)? _promptGeometry(_Prompt p) => _promptGeoms[p];

  final _promptGeoms = <_Prompt, (int, int, int, int)>{};

  void _drawPrompt() {
    _promptGeoms.clear();
    if (_prompts.isEmpty) return;
    final p = _prompts.last;
    final lines = <(String, int)>[]; // (text, style)
    void wrapped(String text, int style, {int indent = 0}) {
      final maxW = math.max(8, _w - 8);
      var rest = text;
      var first = true;
      while (rest.isNotEmpty) {
        final lead = first ? indent : indent + 2;
        var used = lead;
        var k = 0;
        for (final r in rest.runes) {
          final w = term.isZeroWidth(r) ? 0 : term.cellWidth(r);
          if (used + w > maxW) break;
          used += w;
          k++;
        }
        if (k == 0) break;
        final runes = rest.runes.toList();
        lines.add((
          '${first ? '' : '  '}${String.fromCharCodes(runes.sublist(0, k))}',
          style
        ));
        rest = String.fromCharCodes(runes.sublist(k)).trimLeft();
        first = false;
      }
    }

    int fieldRow = -1;
    if (p.kind == 2) {
      wrapped(p.question, _pack(null, null, {Style.bold}));
      lines.add(('', 0));
      for (var k = 0; k < p.choices.length; k++) {
        lines.add(('${k == p.pick.index() ? '❯ ' : '  '}${p.choices[k]}', 0));
      }
    } else {
      final q = p.kind == 1 ? '${p.question} [y/n]' : p.question;
      wrapped(q, _pack(null, null, {Style.bold}));
      lines.add(('', 0));
      final shown =
          p.secret ? '•' * p.field._text.runes.length : p.field._text;
      fieldRow = lines.length;
      lines.add(('❯ $shown', 0));
      if (p.error != null) {
        lines.add(('  ${p.error}', _pack(Color.red, null, {})));
      }
    }
    final contentW = lines.fold<int>(0,
        (m, l) => math.max(m, term.displayWidth(l.$1)));
    final w = (contentW + 6).clamp(20, math.max<int>(20, _w - 2));
    final h = (lines.length + 4).clamp(5, math.max<int>(5, _h - 2));
    final x = ((_w - w) ~/ 2).clamp(0, math.max<int>(0, _w - w));
    final y = ((_h - h) ~/ 2).clamp(0, math.max<int>(0, _h - h));
    final buf = <List<_Cell>>[
      for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)
    ];
    final ascii = _caps.ascii;
    final (hz, vt, tl, tr, bl, br) = ascii
        ? ('-', '|', '+', '+', '+', '+')
        : ('─', '│', '┌', '┐', '└', '┘');
    void raw(int r, int c, String ch) {
      if (r >= 0 && r < h && c >= 0 && c < w) buf[r][c] = _Cell(ch, 0, 1);
    }

    for (var cx = 0; cx < w; cx++) {
      raw(0, cx, hz);
      raw(h - 1, cx, hz);
    }
    for (var ry = 0; ry < h; ry++) {
      raw(ry, 0, vt);
      raw(ry, w - 1, vt);
    }
    raw(0, 0, tl);
    raw(0, w - 1, tr);
    raw(h - 1, 0, bl);
    raw(h - 1, w - 1, br);
    for (var r = 0; r < lines.length && r + 2 < h - 1; r++) {
      final (text, st) = lines[r];
      var col = 3;
      for (final rune in text.runes) {
        if (col >= w - 2) break;
        if (rune < 0x20 || rune == 0x7f) continue;
        final cw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
        if (cw == 0 || col + cw > w - 2) continue;
        buf[r + 2][col] =
            _Cell(String.fromCharCode(rune), st, cw);
        if (cw == 2 && col + 1 < w - 2) {
          buf[r + 2][col + 1] = _Cell('', st, 0);
        }
        col += cw;
      }
    }
    _popups.add(_Popup(x, y, w, h, buf));
    _promptGeoms[p] = (x, y, w, h);
    if (p.kind != 2 && fieldRow >= 0) {
      // Hardware cursor at the end of the field text.
      final text = p.secret
          ? '•' * p.field._text.runes.length
          : p.field._text;
      var col = x + 3 + 2 + term.displayWidth(text);
      col = math.min(col, x + w - 2);
      _cursorPos = (y + 2 + fieldRow, col);
    }
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
    // A handler that ends in StdinException (Escape in a Console prompt)
    // shows nothing.
    if (e is io.StdinException) {
      _dirtyAndWake();
      return;
    }
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

  /// Clear what one draw pass registers.
  void _resetFrame() {
    _focusables.clear();
    _clickCbs.clear();
    _popups.clear();
    _scrolls.clear();
    _drawnFields.clear();
    _activeSg = null;
    _order = 0;
    _usedRows = 0;
    _spinVisible = false;
    _cursorPos = null;
    for (final row in _grid) {
      row.fillRange(0, row.length, _Cell.blank);
    }
  }

  /// Run [draw] until the heights of open `rows`/`box` settle: the first
  /// pass measures, later passes lay out with the measures (at most 4).
  void _measured(void Function() draw, void Function() reset) {
    _mSlots = null;
    _mNext = 0;
    _mPending.clear();
    _mBuild.clear();
    draw();
    for (var pass = 0; _mNext > 0 && pass < 4; pass++) {
      for (final resolve in _mPending.reversed) {
        resolve();
      }
      final next = List<int>.generate(_mNext, (k) => _mBuild[k] ?? 0);
      final was = _mSlots;
      if (was != null &&
          was.length == next.length &&
          Iterable<int>.generate(next.length).every((k) => was[k] == next[k])) {
        break;
      }
      reset();
      _mSlots = next;
      _mNext = 0;
      _mPending.clear();
      _mBuild.clear();
      draw();
    }
    _mSlots = null;
    _mNext = 0;
    _mPending.clear();
    _mBuild.clear();
  }

  void _draw() {
    _resetFrame();
    if (!_testMode) _caps = _Caps.current;
    // Fresh working grid every draw; _shown keeps last-painted state so the
    // paint still writes only changed cells.
    if (_grid.length != _h ||
        _grid.isNotEmpty && _grid.first.length != _w) {
      _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
      _shown = null;
      _repaint = true;
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
    if (fullscreen) {
      _measured(() {
        screen._draw(Region._(this, _grid, 0, titleH, _w, bodyH));
        if (titleH == 1) {
          Region._(this, _grid, 0, 0, _w, 1)
              .write(' ${_title ?? ''} ', color: accent);
        }
      }, _resetFrame);
      _statusY = _h - 1;
      _drawStatus();
      _compositeScrolls();
    } else {
      _drawInlineBody(screen, titleH);
      _drawStatus();
    }
    _drawPrompt();
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
      // Draw again so the newly focused widget shows its focus (cursor,
      // accent) in this frame, not the next.
      if (!_refocused) {
        _refocused = true;
        try {
          _draw();
        } finally {
          _refocused = false;
        }
        return;
      }
    }
    if (!identical(_shownState, _state)) {
      _shownState = _state;
      _fireLifecycle('show');
    }
    // Drop suggest state for fields that are no longer drawn.
    _suggests.removeWhere((field, sg) {
      if (_drawnFields.contains(field)) return false;
      if (identical(_activeSg, sg)) _activeSg = null;
      return true;
    });
  }

  /// Inline: lay the screen out on an unbounded buffer, then keep its
  /// bottom slice above the status row (the whole height while a popup or
  /// prompt is open).
  void _drawInlineBody(Screen screen, int titleH) {
    final live = _grid;
    var buf = <List<_Cell>>[];
    _measured(() {
      _grid = buf = [];
      screen._draw(Region._(this, buf, 0, titleH, _w, _unbounded,
          grow: true, open: true));
      if (titleH == 1) {
        Region._(this, buf, 0, 0, _w, 1, grow: true)
            .write(' ${_title ?? ''} ', color: accent);
      }
    }, () {
      _grid = live;
      _resetFrame();
    });
    for (final ctx in _scrolls) {
      while (buf.length < ctx.gy + ctx.viewH) {
        buf.add(List.filled(_w, _Cell.blank));
      }
    }
    _compositeScrolls();
    var n = buf.length;
    while (n > 0 && buf[n - 1].every((c) => c == _Cell.blank)) {
      n--;
    }
    final shown = math.min(n, math.max(0, _h - 1));
    final drop = n - shown;
    for (var r = 0; r < shown; r++) {
      live[r].setRange(0, _w, buf[drop + r]);
    }
    _grid = live;
    if (drop > 0) {
      // Popups are centered on the screen already; only content moves.
      final fs = [
        for (final f in _focusables)
          f.fixed
              ? f
              : _F(f.id, f.x, f.y - drop, f.w, f.h, f.order, f.tryKey,
                  onMap: f.onMap)
      ];
      _focusables
        ..clear()
        ..addAll(fs);
      if (_cursorPos case (final r, final c)) {
        _cursorPos = r - drop < 0 ? null : (r - drop, c);
      }
    }
    // A popup below the content (a suggest list) grows the live area just
    // enough; a Console prompt is centered on the whole terminal.
    final below = _popups.fold(shown, (m, p) => math.max(m, p.y + p.h));
    _statusY = _prompts.isNotEmpty ? _h - 1 : math.min(below, _h - 1);
    _usedRows = _statusY + 1;
  }

  void _drawStatus() {
    final y = _statusY;
    if (y < 0) return;
    String left;
    int leftStyle = 0;
    if (_error != null) {
      left = _error!;
      leftStyle = _pack(Color.red, null, {});
    } else if (_sayMsg != null) {
      left = _sayMsg!;
    } else if (_cSpinners.isNotEmpty || _cBars.isNotEmpty) {
      left = _consoleStatus();
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

  /// The running Console spinners and bars for the status row.
  String _consoleStatus() {
    final frames = _caps.ascii
        ? const ['-', '\\', '|', '/']
        : const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    final parts = <String>[];
    for (final label in _cSpinners.values) {
      parts.add('${frames[_spinTick % frames.length]} $label');
    }
    for (final bar in _cBars.values) {
      final lab = bar.label == null ? '' : '${bar.label} ';
      final secs =
          DateTime.now().difference(bar.start).inMilliseconds / 1000;
      if (bar.bytes) {
        final rate = secs > 0 ? bar.done / secs : 0.0;
        final counts = bar.total != null && bar.total! > 0
            ? '${_fmtSize(bar.done)}/${_fmtSize(bar.total!)}'
            : _fmtSize(bar.done);
        parts.add(
            '$lab${_barGlyphs(bar.done, bar.total)}$counts  ${_fmtRate(rate)}');
      } else {
        final total = bar.total;
        final counts =
            total != null && total > 0 ? '${bar.done}/$total' : '${bar.done}';
        final rate = secs > 0 ? bar.done / secs : 0.0;
        parts.add('$lab${_barGlyphs(bar.done, total)}$counts  '
            '${_fmtCount(rate)}/s');
      }
    }
    return parts.join(' · ');
  }

  /// `━━━╸──── ` for a known total (like `Console.bar`), else nothing.
  String _barGlyphs(int done, int? total) {
    if (total == null || total <= 0) return '';
    const width = 10;
    final cells = (done / total).clamp(0.0, 1.0) * width;
    final full = cells.floor();
    final half = cells - full >= 0.5 && full < width;
    final (on, mid, off) = _caps.ascii ? ('#', '>', '-') : ('━', '╸', '─');
    return '${on * full}${half ? mid : ''}'
        '${off * (width - full - (half ? 1 : 0))} ';
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
      st._off = st._off.clamp(0, math.max<int>(0, contentH - ctx.viewH));
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
        // Thumb: as tall as the visible share, at the top at offset 0 and
        // on the last row at the end.
        final size = math.max(1, ctx.viewH * ctx.viewH ~/ contentH);
        final maxOff = contentH - ctx.viewH;
        final top = ((ctx.viewH - size) * st._off / maxOff).round();
        for (var r = 0; r < ctx.viewH; r++) {
          final dst = ctx.gy + r;
          if (dst < 0 || dst >= _grid.length) continue;
          final ch = (r >= top && r < top + size)
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

  void _paintNow() {
    if (fullscreen) {
      _paint();
    } else {
      _paintInline();
    }
  }

  /// Inline live area below the shell prompt: the content's bottom slice,
  /// capped at the terminal height. Redraws in place; the cursor rests below.
  void _paintInline() {
    // Return a placed hardware cursor below the live area first.
    if (_curR >= 0) {
      out('\r\x1b[${_liveH - _curR}B');
      _curR = -1;
    }
    final contentH = math.max(_usedRows, 1);
    // One row short of the terminal: the parking newline below must never
    // scroll the live area's top row into the scrollback.
    final liveH = math.min(contentH, math.max(1, _h - 1));
    final first = contentH - liveH;
    final buf = StringBuffer();
    if (_liveH > 0) buf.write('\r\x1b[${_liveH}A');
    for (var r = 0; r < liveH; r++) {
      buf.write('\r\x1b[2K');
      if (first + r < _grid.length) buf.write(_renderRow(_grid[first + r]));
      if (r + 1 < liveH) buf.write('\n');
    }
    // Park below the live area, then erase any stale lines from a shrink.
    buf.write('\n\x1b[J');
    out(buf.toString());
    _liveH = liveH;
    _lastPaint = _now();
    // Cursor placement for a focused input, relative to the live area.
    final cur = _cursorPos;
    if (cur != null) {
      // _cursorPos is absolute (fullscreen math); inline draws the bottom
      // slice, so rebase rows that fall inside it.
      final rel = cur.$1 - first;
      if (rel >= 0 && rel < liveH && cur.$2 >= 0 && cur.$2 < _w) {
        out('\x1b[${liveH - rel}A\r');
        if (cur.$2 > 0) out('\x1b[${cur.$2}C');
        out('\x1b[?25h');
        _curR = rel;
        return;
      }
    }
    out('\x1b[?25l');
    _curR = -1;
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
    if (!fullscreen) return _enterInline();
    try {
      final (w, h) = size();
      _w = math.max(1, w);
      _h = math.max(1, h);
    } catch (_) {}
    _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
    _modes = term.captureModes();
    term.setRawModes();
    _subs.add(term.sharedStdin().listen((b) {
      _pending.addAll(b);
      _wake();
    }, onError: (_) {}));
    void watch(io.ProcessSignal signal, void Function() onSignal) {
      try {
        _subs.add(signal.watch().listen((_) => onSignal()));
      } catch (_) {}
    }

    watch(io.ProcessSignal.sigwinch, () {
      _repaint = true;
      _dirtyAndWake();
    });
    watch(io.ProcessSignal.sigint, () {
      _signals.add('ctrl+c');
      _wake();
    });
    watch(io.ProcessSignal.sigterm, () => _quitSync(143));
    watch(io.ProcessSignal.sighup, () => _quitSync(129));
    out('\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[>1u');
    _repaint = true;
    _dirty = true;
    _entered = true;
    term.TuiBridge.current = this;
  }

  void _quitSync(int code) {
    _done = true;
    try {
      out('\x1b[<u\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?7h\x1b[?25h'
          '\x1b[?1049l');
      final modes = _modes;
      if (modes != null) term.restoreModes(modes);
    } catch (_) {}
    io.exit(code);
  }

  Future<void> _leave() async {
    if (!fullscreen) return _leaveInline();
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
    out('\x1b[<u\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?7h\x1b[?25h'
        '\x1b[?1049l');
    final modes = _modes;
    if (modes != null) term.restoreModes(modes);
    try {
      await io.stdout.flush();
    } catch (_) {}
    if (identical(term.TuiBridge.current, this)) {
      term.TuiBridge.current = null;
    }
  }

  Future<void> _enterInline() async {
    try {
      final (w, h) = size();
      _w = math.max(1, w);
      _h = math.max(1, h);
    } catch (_) {}
    _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
    _modes = term.captureModes();
    term.setRawModes();
    _subs.add(term.sharedStdin().listen((b) {
      _pending.addAll(b);
      _wake();
    }, onError: (_) {}));
    void watch(io.ProcessSignal signal, void Function() onSignal) {
      try {
        _subs.add(signal.watch().listen((_) => onSignal()));
      } catch (_) {}
    }

    // Inline leaves the mouse to the terminal: no pointer reporting.
    watch(io.ProcessSignal.sigwinch, () {
      _repaint = true;
      _dirtyAndWake();
    });
    watch(io.ProcessSignal.sigint, () {
      _signals.add('ctrl+c');
      _wake();
    });
    watch(io.ProcessSignal.sigterm, () => _quitSync(143));
    watch(io.ProcessSignal.sighup, () => _quitSync(129));
    out('\x1b[?25l\x1b[?1004h\x1b[?2004h\x1b[>1u');
    _repaint = true;
    _dirty = true;
    _entered = true;
    _liveH = 0;
    term.TuiBridge.current = this;
  }

  Future<void> _leaveInline() async {
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
    // The transcript stays in the scrollback; just park the cursor below.
    out('\x1b[<u\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?25h\n');
    final modes = _modes;
    if (modes != null) term.restoreModes(modes);
    try {
      await io.stdout.flush();
    } catch (_) {}
    if (identical(term.TuiBridge.current, this)) {
      term.TuiBridge.current = null;
    }
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

  static _Caps get current => of(io.Platform.environment);

  static _Caps of(Map<String, String> env) {
    final noColor = env['NO_COLOR'] != null;
    final colorterm = (env['COLORTERM'] ?? '').toLowerCase();
    final tm = (env['TERM'] ?? '').toLowerCase();
    // The locale that applies: LC_ALL, then LC_CTYPE, then LANG.
    final locale = [env['LC_ALL'], env['LC_CTYPE'], env['LANG']]
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => '')!
        .toLowerCase();
    final truecolor =
        colorterm.contains('truecolor') || colorterm.contains('24bit');
    final color256 = truecolor || tm.contains('256color');
    final ascii = !locale.contains('utf');
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
  TestSession._(this._s, this._out);

  final _Session<S> _s;
  final StringBuffer _out;

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
        painted = _paint();
        _s._dirty = false;
      }
    });
    return painted;
  }

  bool _paint() {
    if (_s.fullscreen) return _s._paintTo(_out);
    final before = _out.length;
    _s._paintInline();
    return _out.length != before;
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
      _paint();
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
          _paint();
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

  /// The terminal changed size: repaint everything at [width]×[height] and
  /// fire `resize`.
  void resize(int width, int height) {
    _s._w = width;
    _s._h = height;
    _s._repaint = true;
    _s._fireLifecycle('resize');
    _s._dirty = true;
  }

  bool get quitRequested => _s._quitFlag;
  S get state => _s._state;
  /// Everything written to the terminal so far (frames, OSC, inline
  /// commits).
  String get output => _out.toString();

  /// Release the shared Console bridge slot.
  void close() {
    if (identical(term.TuiBridge.current, _s)) {
      term.TuiBridge.current = null;
    }
  }
}

/// Build an in-memory [TestSession] (no terminal required); everything the
/// session writes lands in [TestSession.output]. [fullscreen] `false` runs
/// the inline painter; [env] sets the colour and charset capabilities as
/// `TERM`/`COLORTERM`/`NO_COLOR`/`LANG` would. Call [TestSession.close] at the end to release the
/// shared Console bridge slot.
TestSession<S> testSession<S>(S state,
    Screen Function(S state, App<S> app) screen,
    {int width = 80,
    int height = 24,
    Color accent = Color.orange,
    bool fullscreen = true,
    Map<String, String>? env}) {
  final sink = StringBuffer();
  final s = _Session<S>(state, screen,
      out: sink.write,
      size: () => (width, height),
      accent: accent,
      fullscreen: fullscreen);
  s._w = width;
  s._h = height;
  s._grid = List.generate(height, (_) => List.filled(width, _Cell.blank));
  s._testMode = true;
  s._caps = env == null ? _Caps.fallback : _Caps.of(env);
  late Zone z;
  runZoned(() {
    z = Zone.current;
  }, zoneSpecification: s._spec());
  s._zone = z;
  term.TuiBridge.current = s;
  return TestSession<S>._(s, sink);
}

/// Draw an [iw]×[ih] picture into the rest of [r] as half-block cells
/// (two pixel rows per cell), scaled down to fit with its aspect kept.
/// [pixel] returns `(r, g, b)` at `(x, y)`. The engine half of
/// `image.dart`'s `Region.picture`, kept out of `tui` so it doesn't load
/// the image codecs.
Region drawPicture(
    Region r, int iw, int ih, (int, int, int) Function(int x, int y) pixel) {
  final y = r._gy + r._cursor;
  final h = r._h - r._cursor;
  if (h <= 0 || r._w <= 0 || iw <= 0 || ih <= 0) {
    if (!r._open) r._cursor = r._h;
    return r;
  }
  final scale = math.min(1.0, math.min(r._w / iw, 2 * h / ih));
  final cw = math.max(1, (iw * scale).floor());
  final ph = math.max(1, (ih * scale).floor()); // pixel rows shown
  final ch = (ph + 1) ~/ 2;
  if (r._open) {
    r._take(ch);
  } else {
    r._cursor = r._h;
  }
  for (var row = 0; row < ch; row++) {
    final y0 = (2 * row * ih) ~/ ph;
    final y1 = math.min(ih - 1, ((2 * row + 1) * ih) ~/ ph);
    for (var c = 0; c < cw; c++) {
      final x = (c * iw) ~/ cw;
      final (tr, tg, tb) = pixel(x, math.min(ih - 1, y0));
      final (br, bg, bb) = pixel(x, y1);
      final st = r._s._pack(Color.rgb(tr, tg, tb), Color.rgb(br, bg, bb), {});
      r._put(y + row, r._gx + c, '▀', 1, st, null);
    }
  }
  return r;
}
