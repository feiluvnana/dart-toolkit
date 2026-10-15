// Region: layout.
part of '../tui.dart';

/// C0, DEL and C1: never written raw (a lone U+009B starts a CSI on
/// xterm-like terminals). Every painter skips or replaces them.
bool _isControl(int rune) => rune < 0x20 || rune >= 0x7f && rune <= 0x9f;

/// A rectangle of the screen to draw into; layout methods return sub-regions.
final class Region {
  // ignore: prefer_initializing_formals – internal construction stays positional.
  Region._(
    this._s,
    this._grid,
    this._gx,
    this._gy,
    this._w,
    this._h, {
    bool grow = false,
    bool open = false,
    Region? parent,
    _ScrollCtx? scroll,
    _Popup? pop,
  })
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

  /// The buffer grows as rows are written (scroll).
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

  /// Columns of this region.
  int width() => _w;

  /// Rows of this region.
  int height() => _h;

  /// True when the pointer is inside this region.
  bool hovered() {
    final m = _s._mouse;
    if (m == null) return false;
    return _toLocal(m.$1, m.$2) != null;
  }

  /// True when the session focus belongs to a focusable drawn in this region.
  bool focused() => _s._focusIn(_gx, _gy, _w, _h);

  /// Draw text, wrapping at the right edge (`\n` breaks, `\t` expands,
  /// controls show as `�`, rows past the bottom end with `…`). `link` makes an OSC 8 hyperlink.
  Region write(String text, {Color? color, Color? background, Set<Style> style = const {}, String? link}) {
    final st = _s._pack(color, background, style);
    final parts = text.split('\n');
    final lines = parts.isNotEmpty && parts.last.isEmpty ? parts.sublist(0, parts.length - 1) : parts;
    var overflow = false;
    for (final line in lines) {
      // One rune list per line and a moving index: each wrapped row costs
      // its own runes, not a re-split of the rest (linear, not quadratic).
      final runes = line.runes.toList();
      var at = 0;
      do {
        if (_cursor >= _h) {
          overflow = true;
          _cursor++;
          break;
        }
        _writeRunes(_gy + _cursor++, _gx, _gx + _w, runes, at, st, link);
        if (_used >= runes.length) break;
        at = math.max(_used, at + 1);
      } while (_w > 0);
    }
    if (overflow && _h > 0 && _w > 0) {
      _put(_gy + _h - 1, _gx + _w - 1, '…', 1, st, link);
    }
    return this;
  }

  /// The rest of the region as half-block cells (`▀`) showing [image] (an
  /// `Image` from `image.dart`), scaled down to fit with the aspect kept.
  /// Returns the receiver.
  Region picture(Pixels image) => _drawPicture(this, image.width(), image.height(), image.pixel);

  /// Border the rest of the region, with [title] when given; return the
  /// inside.
  Region box([String title = '']) {
    if (_open) return _measuredRows(const [0], 2, title).single;
    return _boxAt(title, _gy + _cursor, _h - _cursor);
  }

  Region _boxAt(String title, int top, int h, {bool open = false}) {
    _cursor = _h;
    if (_w <= 0 || h <= 0) return _sub(_gx, top, 0, 0);
    final right = _gx + _w - 1;
    final bottom = top + h - 1;
    _frame(_s._caps.ascii, top, _gx, bottom, right, (y, x, ch) => _put(y, x, ch, 1, 0, null));
    if (title.isNotEmpty && _w > 5) {
      _writeLine(top, _gx + 2, right, ' $title ', 0, null);
    }
    if (_w < 3 || h < 3) return _sub(_gx, top, 0, 0, open: open);
    return _sub(_gx + 1, top + 1, _w - 2, open ? _unbounded : h - 2, open: open);
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
          Region._(s, <List<_Cell>>[], 0, 0, inner, z > 0 ? z : _unbounded, grow: true, open: true),
      ];
      _cursor = _h; // siblings after this are measured by the next pass
    } else {
      final hs = [for (var k = 0; k < sizes.length; k++) base + k < slots.length ? slots[base + k] : 0];
      final total = hs.fold(0, (a, b) => a + b);
      if (title != null) {
        kids = [_boxAt(title, _gy + at, total + border, open: true)];
      } else {
        kids = [];
        var off = _gy + at;
        for (var k = 0; k < sizes.length; k++) {
          kids.add(_sub(_gx, off, _w, sizes[k] > 0 ? sizes[k] : _unbounded, open: true));
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

  /// A centered modal; drawn last.
  Region popup(String title, {int width = 40, int height = 10}) {
    final w = math.min(width, _s._w);
    final h = math.min(height, _s._h);
    final x = (_s._w - w) ~/ 2;
    final y = (_s._h - h) ~/ 2;
    final buf = <List<_Cell>>[for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)];
    final pop = _Popup(x, y, w, h, buf);
    _s._popups.add(pop);
    _frame(_s._caps.ascii, 0, 0, h - 1, w - 1, (y, x, ch) => _rawPut(buf, y, x, ch, 0, null));
    if (title.isNotEmpty && w > 5) {
      _rawWrite(buf, 0, 2, w - 1, ' $title ', 0, null);
    }
    return Region._(_s, buf, 1, 1, math.max(0, w - 2), math.max(0, h - 2), pop: pop);
  }

  /// Binding events when focused (keys) or under the pointer (mouse).
  Region on(Map<String, Binding> events) {
    _reg(_s._bindId(events), _gx, _gy + _cursor, _w, _h - _cursor, _s._order++, null, onMap: events);
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
      if (sx < sc.gx || sx >= sc.gx + sc.w || sy < sc.gy || sy >= sc.gy + sc.viewH) {
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
  void _reg(
    Object id,
    int x,
    int y,
    int w,
    int h,
    int order,
    bool Function(_Ev ev)? tryKey, {
    Map<String, Binding>? onMap,
  }) {
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
    _s._addFocusable(id, r.$1, r.$2, r.$3, r.$4, order, wrapped, onMap: onMap, fixed: _pop != null);
  }

  Region _sub(int x, int y, int w, int h, {bool? open}) =>
      Region._(_s, _grid, x, y, w, h, grow: _grow, open: open ?? _open, parent: this, scroll: _scroll, pop: _pop);

  List<Region> _split(List<int> sizes, {required bool horizontal}) {
    for (final s in sizes) {
      if (s < 0) {
        throw ArgumentError.value(sizes, 'sizes', 'negative size $s: use 0 for a flex share');
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
      out.add(horizontal ? _sub(_gx, off, _w, size) : _sub(off, _gy + _cursor, size, _h - _cursor));
      off += size;
    }
    _cursor = _h;
    return out;
  }

  int _used = 0; // rune index the last _writeLine/_writeRunes stopped at

  int _writeLine(int row, int from, int end, String text, int style, String? link) =>
      _writeRunes(row, from, end, text.runes.toList(), 0, style, link);

  /// [_writeLine] over `runes[start..]`; [_used] ends as the absolute index
  /// of the first rune not drawn.
  int _writeRunes(int row, int from, int end, List<int> runes, int start, int style, String? link) {
    _used = runes.length;
    if (row < _gy || row >= _gy + _h) return from;
    if (link != null && link.codeUnits.any((c) => c < 0x20 || c == 0x7f || (c >= 0x80 && c <= 0x9f))) {
      link = null;
    }
    _ensureRow(row);
    _bump(row);
    final cap = _grid == _s._grid ? _s._w : _grid[row].length;
    end = math.min(end, _gx + _w);
    if (_grid == _s._grid) end = math.min(end, cap);
    var col = from;
    var i = start;
    while (i < runes.length && col < end) {
      final at = i;
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
      if (_isControl(rune)) {
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
        i = at;
        break;
      }
      _put(row, col, cluster.toString(), w, style, link);
      col += w;
    }
    _used = i;
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
  }

  void _rawPut(List<List<_Cell>> grid, int row, int col, String ch, int style, String? link) {
    if (row < 0 || row >= grid.length) return;
    if (col < 0 || col >= grid[row].length) return;
    grid[row][col] = _Cell(ch, style, 1, link: link);
  }

  void _rawWrite(List<List<_Cell>> grid, int row, int from, int end, String text, int style, String? link) {
    var col = from;
    for (final r in text.runes) {
      if (col >= end || col >= grid[row].length) break;
      if (_isControl(r)) continue; // C0, DEL, C1
      grid[row][col++] = _Cell(String.fromCharCode(r), style, 1, link: link);
    }
  }
}

/// Grapheme helpers shared by [Region] input editing.
int _prevCluster(List<int> runes, int at) {
  var end = at.clamp(0, runes.length);
  if (end <= 0) return 0;
  while (true) {
    while (end > 0 && term.isZeroWidth(runes[end - 1]) && runes[end - 1] != 0x200D) {
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
  while (i < runes.length && term.isZeroWidth(runes[i]) && runes[i] != 0x200D) {
    i++;
  }
  while (i < runes.length && runes[i] == 0x200D) {
    i++;
    if (i < runes.length) i++;
    while (i < runes.length && term.isZeroWidth(runes[i]) && runes[i] != 0x200D) {
      i++;
    }
  }
  return i;
}

bool _isWordChar(int r) =>
    (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || r == 0x5F || (r >= 0x61 && r <= 0x7A);

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
  _ScrollCtx(this.scroll, this.buf, this.gx, this.gy, this.w, this.viewH, this.order);

  final Scroll scroll;
  final List<List<_Cell>> buf;
  final int gx;
  final int gy;
  final int w;
  final int viewH;
  final int order;
}

/// A popup buffer, composited after the main draw. [anchored] popups sit
/// next to content (suggest lists) and move with it; the rest are centered.
final class _Popup {
  _Popup(this.x, this.y, this.w, this.h, this.buf, {this.anchored = false});

  final int x;
  int y;
  final bool anchored;
  final int w;
  final int h;
  final List<List<_Cell>> buf;
}

/// Draw an [iw]×[ih] picture into the rest of [r] as half-block cells
/// (two pixel rows per cell), scaled down to fit with its aspect kept.
/// [pixel] returns `(r, g, b)` at `(x, y)`. The engine half of
/// `image.dart`'s `Region.picture`, kept out of `tui` so it doesn't load
/// the image codecs.
Region _drawPicture(Region r, int iw, int ih, (int, int, int) Function(int x, int y) pixel) {
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
