// Widgets: list, table, input, tabs, scroll, button (+ state objects).
part of '../tui.dart';

/// A list's items and selection. Lives in the app's state object, so the
/// selection (and focus) survives redraws and state switches.
///
/// Appends are O(1) amortised: items live in one growable list and [items]
/// exposes a live [UnmodifiableListView] over it (no copy per [add]). Do not hold the view across frames;
/// call [items] again after mutating.
final class Pick<T> {
  Pick([List<T> items = const []]) : _items = List<T>.of(items);

  final List<T> _items;
  var _index = 0;

  /// A live read-only view of the items.
  List<T> items() => UnmodifiableListView<T>(_items);

  /// The selected index.
  int index() => _index;

  /// The selected item, or null when empty.
  T? selected() => _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

  /// Replace the items, keeping the selected item if it is still there,
  /// else selecting 0.
  Pick<T> set(List<T> items) {
    final cur = selected();
    _items
      ..clear()
      ..addAll(items);
    _reselect(cur);
    return this;
  }

  /// Select [index], clamped.
  Pick<T> select(int index) {
    _index = _items.isEmpty ? 0 : index.clamp(0, _items.length - 1);
    return this;
  }

  /// Append [item] in O(1) amortised time; the selection is untouched.
  /// Returns this.
  Pick<T> add(T item) {
    _items.add(item);
    return this;
  }

  /// Append all [items] without rebuilding; the selection is untouched.
  /// Returns this.
  Pick<T> addAll(Iterable<T> items) {
    _items.addAll(items);
    return this;
  }

  /// Remove [item] from the list. Returns this.
  Pick<T> remove(T item) {
    final cur = selected();
    _items.remove(item);
    _reselect(cur);
    return this;
  }

  /// Remove items satisfying [test] in place (one pass, no copy).
  /// Returns this.
  Pick<T> removeWhere(bool Function(T item) test) {
    final cur = selected();
    _items.removeWhere(test);
    _reselect(cur);
    return this;
  }

  void _reselect(T? cur) {
    if (_items.isEmpty || cur == null) {
      _index = 0;
      return;
    }
    final at = _items.indexOf(cur);
    _index = at >= 0 ? at : 0;
  }
}

/// An input's text, cursor and history. Lives in the app's state object.
final class Field {
  Field({String text = '', List<String> history = const []})
    : _text = _lf(text),
      _history = List<String>.unmodifiable(history) {
    _cursor = _text.runes.length;
  }

  String _text;
  int _cursor = 0; // rune offset
  List<String> _history;
  int _histAt = -1;
  String _draft = '';
  int _wantCol = -1; // sticky display column for vertical moves
  int _rowOff = 0; // first visible row for multiline inputs

  /// The current text.
  String text() => _text;

  /// Submitted texts, newest first.
  List<String> history() => _history;

  /// Replace the text; the cursor goes to the end.
  Field set(String text) {
    _text = _lf(text);
    _cursor = _text.runes.length;
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

extension RegionWidgets on Region {
  /// A tab row; returns the area below it. [color], [background] and
  /// [style] paint the tabs as in `write`; [highlight] backs the selected
  /// one (default: the accent, else reverse video).
  Region tabs<T>(
    Pick<T> tabs,
    String Function(T tab) label, {
    Color? highlight,
    Color? color,
    Color? background,
    Set<Style> style = const {},
  }) {
    final y = _gy + _cursor;
    final h = _h - _cursor;
    _cursor = _h;
    if (h <= 0 || _w <= 0 || tabs.items().isEmpty) {
      return _sub(_gx, y, _w, math.max(0, h - 1));
    }
    final order = _s._order++;
    _reg(tabs, _gx, y, _w, 1, order, (ev) {
      if (ev is _ClickEv) {
        var x = _gx;
        for (var k = 0; k < tabs.items().length; k++) {
          final w = term.displayWidth(' ${label(tabs.items()[k])} ');
          if (ev.x >= x && ev.x < x + w) {
            tabs.select(k);
            _s._setFocus(tabs);
            _s._dirtyAndWake();
            return true;
          }
          x += w;
        }
        return false;
      }
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
      final st = sel ? _s._selected(highlight, color, style) : _s._pack(color, background, style);
      x = _writeLine(y, x, _gx + _w, t, st, null);
    }
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
    final buf = <List<_Cell>>[for (var k = 0; k < viewH; k++) List.filled(_w, _Cell.blank)];
    final ctx = _ScrollCtx(scroll, buf, _gx, y, _w, viewH, _s._order++);
    _s._scrolls.add(ctx);
    _reg(scroll, _gx, y, _w, viewH, ctx.order, (ev) {
      if (ev is _ClickEv) {
        _s._setFocus(scroll);
        // The scrollbar: jump there, and a drag moves it. A click on the
        // content still reaches the screen's bindings.
        if (ev.x != _gx + _w - 1 || ctx.buf.length <= viewH) return false;
        _s._dragging = scroll;
        _s._scrollTo(ctx, ev.y);
        return true;
      }
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
    // The last column belongs to the scrollbar.
    return Region._(_s, buf, 0, 0, math.max(0, _w - 1), _unbounded, grow: true, open: true, scroll: ctx);
  }

  void _scrollBy(Scroll scroll, _ScrollCtx ctx, int d) {
    final contentH = math.max(ctx.buf.length, 1);
    final maxOff = math.max(0, contentH - ctx.viewH);
    scroll._off = (scroll._off + d).clamp(0, maxOff);
    scroll._pinned = false;
    _s._dirtyAndWake();
  }

  /// A selectable list. [color], [background] and [style] paint the rows
  /// as in `write`; [highlight] backs the selected row (default: the
  /// accent, else reverse video).
  Region list<T>(
    Pick<T> pick,
    String Function(T item) label, {
    String empty = '',
    Color? highlight,
    Color? color,
    Color? background,
    Set<Style> style = const {},
  }) {
    final y = _gy + _cursor;
    final h = _listRows(pick, 0, empty);
    _drawList(pick, label, empty, y, h, paint: (highlight, color, background, style));
    return this;
  }

  /// A selectable table, painted like [list].
  Region table<T>(
    Pick<T> pick,
    List<String> Function(T item) cells, {
    List<String>? header,
    String empty = '',
    Color? highlight,
    Color? color,
    Color? background,
    Set<Style> style = const {},
  }) {
    final y = _gy + _cursor;
    final h = _listRows(pick, header == null ? 0 : 1, empty);
    // Columns as wide as their widest cell, the widest shrunk to fit. Only
    // rows within a screen of the selection are measured (whatever this
    // frame can show), on top of what this pick measured before: O(screen)
    // per frame however many items, and columns never jump back.
    final items = pick.items();
    final memo = _tableWidths[pick];
    // A pick that lost items (cleared, refilled) is measured afresh.
    final widths = memo != null && memo.$1 <= items.length ? List.of(memo.$2) : <int>[];
    final from = math.max(0, pick.index() - h), to = math.min(items.length, pick.index() + h + 1);
    for (final row in [?header, for (var i = from; i < to; i++) cells(items[i])]) {
      for (var k = 0; k < row.length; k++) {
        final w = term.displayWidth(row[k]);
        if (k == widths.length) {
          widths.add(w);
        } else if (w > widths[k]) {
          widths[k] = w;
        }
      }
    }
    _tableWidths[pick] = (items.length, List.of(widths));
    while (widths.fold(0, (a, w) => a + w + 2) - 2 > _w) {
      final k = widths.indexOf(widths.reduce(math.max));
      if (widths[k] <= 4) break;
      widths[k]--;
    }
    String line(List<String> row) => [
      for (var k = 0; k < row.length; k++)
        k == row.length - 1 ? row[k] : _padCells(term.truncateWidth(row[k], widths[k]), widths[k]),
    ].join('  ');
    _drawList(
      pick,
      (t) => line(cells(t)),
      empty,
      y,
      h,
      header: header == null ? null : [line(header)],
      paint: (highlight, color, background, style),
    );
    return this;
  }

  static final _tableWidths = Expando<(int, List<int>)>();

  static String _padCells(String s, int cells) => s + ' ' * math.max(0, cells - term.displayWidth(s));

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

  void _drawList<T>(
    Pick<T> pick,
    String Function(T item) label,
    String empty,
    int y,
    int h, {
    List<String> Function(T item)? cells,
    List<String>? header,
    required (Color?, Color?, Color?, Set<Style>) paint,
  }) {
    final (highlight, color, background, style) = paint;
    final plain = _s._pack(color, background, style);
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
        _writeLine(y, _gx, _gx + _w, empty, _s._pack(color, background, {...style, Style.dim}), null);
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
      _writeLine(row++, _gx, _gx + _w, _rowText(header), _s._pack(color, background, {...style, Style.bold}), null);
    }
    final sel = pick.index();
    final focused = _sameId(_s._focusId, pick);
    for (var r = 0; r < viewH && start + r < items.length; r++) {
      final idx = start + r;
      final isSel = idx == sel;
      final st = isSel
          ? (focused
                ? _s._selected(highlight, color, style)
                : _s._pack(color, background, {...style, Style.reverse, Style.dim}))
          : plain;
      final text = cells == null ? label(items[idx]) : _rowText(cells(items[idx]));
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
  /// answers are dropped). `enter` runs [onSubmit] when given, else bubbles
  /// to `keys`; [hint] shows dimmed while the field is empty. Text editing is by
  /// grapheme: `backspace`/`delete`, `left` `right` `home` `end`, `ctrl+a`
  /// `ctrl+e`, word jumps (`ctrl`/`alt` + arrows) and kills (`ctrl+w`,
  /// `alt+backspace`, `ctrl+u`, `ctrl+k`); `shift+enter`, `alt+enter` or `\`
  /// then `enter` insert a newline. `up`/`down` move between lines, and at
  /// the first or last line they walk the history.
  Region input(
    Field field, {
    String hint = '',
    int lines = 1,
    FutureOr<List<String>> Function(String word)? suggest,
    FutureOr<void> Function()? onSubmit,
    Color? color,
    Color? background,
    Set<Style> style = const {},
  }) {
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
    _reg(
      field,
      _gx,
      y,
      _w,
      math.max(0, math.min(reserve, rem)),
      order,
      (ev) => _inputKey(field, ev, lines, suggest, onSubmit),
    );
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
      final text = field._rowOff + r < rows.length ? rows[field._rowOff + r] : '';
      final isHint = field._text.isEmpty && r == 0;
      String shown;
      if (isHint) {
        shown = hint;
      } else if (lines == 1) {
        shown = _tailText(field, _w - 1);
      } else {
        shown = _fitCells(text, _w - 1);
      }
      final st = _s._pack(color, background, {...style, if (isHint) Style.dim});
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
    final rowRunes = curRow < rows.length ? rows[curRow].runes.toList() : <int>[];
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

  bool _inputKey(
    Field field,
    _Ev ev,
    int lines,
    FutureOr<List<String>> Function(String word)? suggest, [
    FutureOr<void> Function()? onSubmit,
  ]) {
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

    bool moved(int to, {bool refresh = true}) {
      field._cursor = to;
      field._wantCol = -1;
      if (refresh && suggest != null) _s._refreshSuggest(field, suggest);
      _s._dirtyAndWake();
      return true;
    }

    switch (ev.name) {
      case 'backspace':
        return edited(() => _dropGrapheme(field, -1));
      case 'delete':
        return edited(() => _dropGrapheme(field, 1));
      case 'left':
        return moved(_prevCluster(runes, field._cursor));
      case 'right':
        return moved(_nextCluster(runes, field._cursor));
      case 'home':
      case 'ctrl+a':
        return moved(_lineStart(runes, field._cursor), refresh: false);
      case 'end':
      case 'ctrl+e':
        return moved(_lineEnd(runes, field._cursor), refresh: false);
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
        if (multi && ((goUp && curRow > 0) || (!goUp && curRow < rows.length - 1))) {
          if (field._wantCol < 0) field._wantCol = _colOf(field);
          field._cursor = _offsetAt(field, curRow + (goUp ? -1 : 1), field._wantCol);
          if (suggest != null) _s._refreshSuggest(field, suggest);
          _s._dirtyAndWake();
          return true;
        }
        if (!_recall(field, older: goUp)) return false;
        return moved(field._text.runes.length);
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
        if (ev.name.endsWith('left')) return moved(_prevWord(runes, field._cursor));
        if (ev.name.endsWith('right')) return moved(_nextWord(runes, field._cursor));
        return false;
    }
  }

  /// Step [field] through its history ([older] = up), keeping the draft
  /// typed before the first step; false when there is nowhere to go.
  bool _recall(Field field, {required bool older}) {
    if (field._history.isEmpty) return false;
    if (field._histAt < 0) {
      if (!older) return false;
      field._draft = field._text;
      field._histAt = 0;
    } else {
      field._histAt += older ? 1 : -1;
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
    return true;
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

  void _insertText(Field field, String text) {
    final s = _lf(text);
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

  static String _oneLine(String text) =>
      text.replaceAll('\r\n', ' ').replaceAll(_lineBreaksRe, ' ').replaceAll(_controlsRe, '');

  /// A button. Runs [action] on click or on enter/space while focused.
  /// [color], [background] and [style] paint it as in `write`.
  Region button(
    String label,
    FutureOr<void> Function() action, {
    Color? color,
    Color? background,
    Set<Style> style = const {},
  }) {
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
    _writeLine(
      y,
      _gx,
      _gx + _w,
      '[ $label ]',
      _s._pack(color, background, {...style, if (focused) Style.reverse}),
      null,
    );
    return this;
  }

  /// [meter]'s progress laid out like `Console.bar`: its count, total
  /// and rate, read in its unit (`1.2/4.0 MB  1.2 MB/s`, `12/40  3.1/s`,
  /// `1:12/4:30  3.4×`). A count kept by hand is `Meter()..update(done,
  /// total)` (no rate until it steps). It keeps to one row: the bar shrinks, then the label is cut
  /// with `…`. [color], [background], [style] and [on] as in `write`.
  Region bar(
    Meter meter, {
    String? label,
    Color? color,
    Color? background,
    Set<Style> style = const {},
    Map<String, Binding>? on,
  }) {
    final line = term.barLine(
      _w - _col,
      label: label,
      done: meter.done(),
      total: meter.total(),
      unit: progress.unitOf(meter),
      rate: progress.paceOf(meter),
      ascii: _s._caps.ascii,
    );
    write(line, color: color, background: background, style: style, on: on);
    return this;
  }

  /// Every live `Console.bar` (and future watched with one), a row each:
  /// a spinner until it counts, then `label ━━╸── counts  rate`, as
  /// `Console.bar` draws it. A bar that ended shows its ✓/✗ row for 2 s
  /// (unless it was `keep: false` and succeeded). Drawing this takes the
  /// bars out of the status row. [color], [background] and [style] as in
  /// `write`.
  Region bars({Color? color, Color? background, Set<Style> style = const {}}) {
    _s._barsShown = true;
    final rows = _s._barRows();
    if (rows.isNotEmpty) _s._spinVisible = true; // spinners and the 2 s ✓ rows need frames
    return lines(rows.length, (row, i) => row.write(rows[i](row.width()), color: color, background: background, style: style));
  }

  /// Every `Console.log` line of the run that passes [only], a row each
  /// with its time; inside a `scroll` that follows, the newest stays in
  /// view. A failed line (`Console.log(line, failed: true)`) is bold, in
  /// [failures] when given; others in [color]. Drawing this takes Console's
  /// lines out of the status row.
  Region log({
    bool Function(({DateTime at, String text, bool failed}) line)? only,
    Color? color,
    Color? failures,
  }) {
    _s._logShown = true;
    final shown = only == null ? logbook : [for (final l in logbook) if (only(l)) l];
    return lines(shown.length, (row, i) {
      final l = shown[i];
      row.write('${l.at.format('HH:mm:ss')}  ', inline: true, style: {Style.dim});
      row.write(l.text, color: l.failed ? failures : color, style: l.failed ? {Style.bold} : const {});
    });
  }

  /// A static spinner snapshot; the frame advances while visible. With
  /// [since], the elapsed time follows the label (`Thinking… (12 s)`, as
  /// `Duration.human()` says it). [color], [background], [style] and [on]
  /// as in `write`.
  Region spin(
    String label, {
    DateTime? since,
    Color? color,
    Color? background,
    Set<Style> style = const {},
    Map<String, Binding>? on,
  }) {
    _s._spinVisible = true;
    final frames = fmt.spinFrames(ascii: _s._caps.ascii);
    final time = since == null ? '' : ' (${DateTime.now().difference(since).human()})';
    write(
      '${frames[_s._spinTick % frames.length]} $label$time',
      color: color,
      background: background,
      style: style,
      on: on,
    );
    return this;
  }
}

/// One-line field text: breaks become spaces, other controls go (compiled once).
final _lineBreaksRe = RegExp('[\r\n\t]');
final _controlsRe = RegExp('[\x00-\x1f\x7f]');
