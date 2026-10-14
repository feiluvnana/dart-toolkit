// Widgets: list, table, input, tabs, scroll, button (+ state objects).
part of '../tui.dart';

/// A list's items and selection. Lives in the app's state object, so the
/// selection (and focus) survives redraws and state switches.
///
/// Appends are O(1) amortised: items live in one growable list and [items]
/// exposes a live [UnmodifiableListView] over it (no copy per [add], unlike
/// the old rebuild-through-[setItems]). Do not hold the view across frames;
/// call [items] again after mutating.
final class Selection<T> {
  Selection([List<T> items = const []]) : _items = List<T>.of(items);

  final List<T> _items;
  var _index = 0;

  List<T> items() => UnmodifiableListView<T>(_items);
  int index() => _index;

  /// The selected item, or null when empty.
  T? selected() =>
      _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

  /// Replace the items, keeping the selected item if it is still there,
  /// else selecting 0.
  Selection<T> setItems(List<T> items) {
    final cur = selected();
    _items
      ..clear()
      ..addAll(items);
    _reselect(cur);
    return this;
  }

  /// Select [index], clamped.
  Selection<T> select(int index) {
    _index = _items.isEmpty ? 0 : index.clamp(0, _items.length - 1);
    return this;
  }

  /// Append [item] in O(1) amortised time; the selection is untouched.
  /// Returns this.
  Selection<T> add(T item) {
    _items.add(item);
    return this;
  }

  /// Append all [items] without rebuilding; the selection is untouched.
  /// Returns this.
  Selection<T> addAll(Iterable<T> items) {
    _items.addAll(items);
    return this;
  }

  /// Remove [item] from the list. Returns this.
  Selection<T> remove(T item) {
    final cur = selected();
    _items.remove(item);
    _reselect(cur);
    return this;
  }

  /// Remove items satisfying [test] in place (one pass, no copy).
  /// Returns this.
  Selection<T> removeWhere(bool Function(T item) test) {
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
final class TextField {
  TextField({String text = '', List<String> history = const []})
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
  TextField setText(String text) {
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
final class ScrollPosition {
  // ignore: prefer_initializing_formals – the public argument stays `follow`.
  ScrollPosition({bool follow = true}) : _follow = follow;

  final bool _follow;
  var _off = 0;
  var _pinned = true;
}

extension RegionWidgets on Region {
    /// A tab row; returns the area below it.
    Region tabs<T>(Selection<T> tabs, String Function(T tab) label) {
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
    Region scroll(ScrollPosition scroll) {
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
  
    void _scrollBy(ScrollPosition scroll, _ScrollCtx ctx, int d) {
      final contentH = math.max(ctx.buf.length, 1);
      final maxOff = math.max(0, contentH - ctx.viewH);
      scroll._off = (scroll._off + d).clamp(0, maxOff);
      scroll._pinned = false;
      _s._dirtyAndWake();
    }
    /// A selectable list.
    Region list<T>(Selection<T> pick, String Function(T item) label,
        {String empty = ''}) {
      final y = _gy + _cursor;
      final h = _listRows(pick, 0, empty);
      _drawList(pick, label, empty, y, h);
      return this;
    }
  
    /// A selectable table.
    Region table<T>(Selection<T> pick, List<String> Function(T item) cells,
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
    int _listRows(Selection<Object?> pick, int head, String empty) {
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
  
    void _drawList<T>(Selection<T> pick, String Function(T item) label, String empty,
        int y, int h,
        {List<String> Function(T item)? cells, List<String>? header}) {
      final order = _s._order++;
      final items = pick.items();
      final headRows = header != null ? 1 : 0;
      final viewH = h - headRows;
      var start = _s._listStart(pick, items.length, math.max(0, viewH));
      // ScrollPosition by the least needed to show the selection, in this frame.
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
    Region input(TextField field,
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
    List<String> _fieldRows(TextField field) => field._text.split('\n');
  
    int _rowOf(TextField field) {
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
    int _colOf(TextField field) {
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
    int _offsetAt(TextField field, int row, int colCells) {
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
    (int, int)? _cursorScreenPos(TextField field, int y0, int lines) {
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
  
    String _tailText(TextField field, int cells) {
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
  
    bool _inputKey(TextField field, _Ev ev, int lines,
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
    int _clickBaseRow(TextField field) => _s._clickBase[field] ?? _gy + _cursor - 1;
  
    int _clickOffset(TextField field, List<String> rows, int row, int xCells) {
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
  
    void _insertText(TextField field, String s) {
      field._histAt = -1;
      final runes = field._text.runes.toList();
      final at = field._cursor.clamp(0, runes.length);
      runes.insertAll(at, s.runes);
      field._text = String.fromCharCodes(runes);
      field._cursor = at + s.runes.length;
    }
  
    void _dropGrapheme(TextField field, int dir) {
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
  
    void _deleteWord(TextField field, int dir) {
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
    /// A static progress snapshot laid out like `Console.progressBar`.
    Region progressBar(int done, int? total, {String? label}) {
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
}
