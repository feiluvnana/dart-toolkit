/// The immediate-mode canvas: widgets paint cells into [_grid] inside [_bounds],
/// flowing down from the cursor. `split` carves bounded child canvases;
/// `popup` paints centered overlays last. Caller-owned state throughout
/// (`selected`, `FieldState`, focus flags).
///
/// ```dart
/// term.draw((ui) {
///   ui.box(title: 'Menu', build: (menu) {
///     menu.list(['Overview', 'Settings'], selected: 1);
///   });
/// });
/// ```
part of 'term.dart';

/// The §7 accent, shared with the console look: fills, markers and frames.
const _accent = TuiColor.rgb(217, 119, 87);

/// Editable single-line text: the caller owns it, paints it with
/// `ui.field(state)`, and feeds it events with `state.handle(ev)`. The cursor
/// counts grapheme clusters, so one backspace removes one emoji.
final class FieldState {
  String _text;
  int _cursor;

  FieldState([String text = '']) : _text = text, _cursor = clusters(text).length;

  String get text => _text;
  int get cursor => _cursor;

  /// Edits with [ev]: printable text, backspace/delete, arrows, home/end,
  /// paste. Answers whether the event was consumed.
  bool handle(TuiEvent ev) {
    if (ev is Paste) {
      _insert(ev.text);
      return true;
    }
    if (ev is! KeyPress) return false;
    final typed = ev.text;
    if (typed != null) {
      _insert(typed);
      return true;
    }
    final cls = clusters(_text);
    switch (ev.name) {
      case 'backspace':
        if (_cursor > 0) {
          cls.removeAt(_cursor - 1);
          _text = cls.join();
          _cursor--;
        }
        return true;
      case 'delete':
        if (_cursor < cls.length) {
          cls.removeAt(_cursor);
          _text = cls.join();
        }
        return true;
      case 'left':
        if (_cursor > 0) _cursor--;
        return true;
      case 'right':
        if (_cursor < cls.length) _cursor++;
        return true;
      case 'home':
        _cursor = 0;
        return true;
      case 'end':
        _cursor = cls.length;
        return true;
      default:
        return false;
    }
  }

  void _insert(String s) {
    final cls = clusters(_text);
    final add = clusters(s);
    cls.insertAll(_cursor, add);
    _text = cls.join();
    _cursor += add.length;
  }
}

/// The canvas widgets paint on: a _grid, a clip _bounds, a cursor, the click
/// regions painted this frame, and pending overlays. Only [Term] makes one.
final class Canvas {
  final Grid _grid;
  final Rect _bounds;
  int _cy;
  final List<({Rect rect, void Function() onPress})> _clickables = [];
  final List<void Function(Canvas)> _overlays = [];

  /// Hardware cursor position (column, row), set by [field] when focused.
  (int, int)? cursorPos;

  /// Rows still free below the cursor (0 when full).
  int get rest => _bounds.y + _bounds.h - _cy;

  Canvas._(this._grid, {Rect? bounds})
    : _bounds = bounds ?? Rect(0, 0, _grid.width, _grid.height),
      _cy = (bounds ?? Rect(0, 0, _grid.width, _grid.height)).y;

  /// A titled frame; [build] paints the content inside the border. The sides
  /// continue from the top rule to the bottom one, so frames (popups
  /// included) read as one enclosure. A too-long title is truncated with `…`,
  /// never overflowing.
  void box({String? title, int padding = 0, required void Function(Canvas) build}) {
    if (_cy >= _bounds.y + _bounds.h) return;
    final w = _bounds.w;
    if (w < 2) return;
    final inner = w - 2;
    if (title == null) {
      _rule('┌${'─' * inner}┐');
    } else {
      final label = truncate(' $title ', inner);
      _rule('┌$label${'─' * (inner - textWidth(label))}┐');
    }
    // Continuous sides: the content paints the interior only, so these stand.
    for (var y = _cy; y < _bounds.y + _bounds.h - 1; y++) {
      _grid.set(_bounds.x, y, const Cell('│'));
      _grid.set(_bounds.x + w - 1, y, const Cell('│'));
    }
    final content = Rect(_bounds.x + 1 + padding, _cy, inner - padding * 2, _bounds.y + _bounds.h - _cy - 1);
    final sub = Canvas._(_grid, bounds: content);
    build(sub);
    _clickables.addAll(sub._clickables);
    _overlays.addAll(sub._overlays);
    if (sub.cursorPos != null) cursorPos = sub.cursorPos;
    _cy = _bounds.y + _bounds.h - 1;
    _rule('└${'─' * inner}┘');
  }

  void _rule(String line) {
    if (_cy < _bounds.y + _bounds.h) {
      _grid.write(_bounds.x, _cy, truncate(line, _bounds.w));
      _cy++;
    }
  }

  /// A line of text, wrapped to the _bounds.
  void text(String s, {TuiColor? fg, TuiColor? bg, CellStyle style = const CellStyle()}) {
    for (final line in wrap(s, _bounds.w)) {
      if (_cy >= _bounds.y + _bounds.h) return;
      _grid.write(_bounds.x, _cy, line, fg: fg, bg: bg, attrs: style);
      _cy++;
    }
  }

  /// A spinner and its [label] on one line: the frame comes from the clock, so it turns
  /// whenever the loop redraws (poll with a `timeout` to keep it moving). The frame is the
  /// §7 accent unless [fg] says otherwise; [style] applies to the label.
  void spinner(String label, {TuiColor? fg, CellStyle style = const CellStyle(), SpinGlyphs glyphs = SpinGlyphs.dots}) {
    if (_cy >= _bounds.y + _bounds.h) return;
    final frame = glyphs.frame();
    _grid.write(_bounds.x, _cy, frame, fg: fg ?? _accent);
    final at = textWidth(frame) + 1;
    if (at < _bounds.w) _grid.write(_bounds.x + at, _cy, truncate(label, _bounds.w - at), attrs: style);
    _cy++;
  }

  /// A labeled gauge filling the _bounds width ([glyphs] picks the set;
  /// [BarGlyphs.ascii] where the terminal cannot draw Unicode). Lays out like
  /// [Cli.bar]: `label  bar  pct  details`, the fill in the §7 accent and the
  /// track dimmed.
  void bar(num value, num max, {String? label, String? unit, int? width, BarGlyphs glyphs = BarGlyphs.line}) {
    if (_cy >= _bounds.y + _bounds.h) return;
    final w = (width ?? _bounds.w).clamp(10, _bounds.w);
    final ratio = max <= 0 ? 1.0 : (value / max).clamp(0.0, 1.0);
    final pct = '${(ratio * 100).toStringAsFixed(0)}%';
    final details = unit == 'B' ? _humanPair(value, max) : (unit == null ? '$value/$max' : '$value/$max $unit');
    final head = label == null ? '' : '$label  ';
    final barW = (w - textWidth('$head  $pct  $details')).clamp(1, w);
    final g = glyphs; // TUI: caller picks ascii where needed
    final done = (ratio * barW).floor().clamp(0, barW);
    final tip = ratio > 0 && done < barW && g.head.isNotEmpty; // no head at 0%
    const accent = TuiColor.rgb(217, 119, 87);
    var x = _bounds.x;
    if (label != null) x += _grid.write(x, _cy, '$label  ');
    x += _grid.write(x, _cy, g.fill * done + (tip ? g.head : ''), fg: accent);
    x += _grid.write(x, _cy, g.empty * (barW - done - (tip ? 1 : 0)), attrs: const CellStyle(dim: true));
    x += _grid.write(x, _cy, '  $pct');
    _grid.write(x, _cy, '  $details', attrs: const CellStyle(dim: true));
    _cy++;
  }

  /// `50.0/100 MB`: both ends at the total's scale, the unit named once
  /// (mirrors `Cli.bar`'s byte details).
  String _humanPair(num value, num max) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var scale = 0;
    var x = max.toDouble();
    while (x >= 1000 && scale < units.length - 1) {
      x /= 1000;
      scale++;
    }

    String fmt(num v) {
      var y = v.toDouble();
      for (var i = 0; i < scale; i++) {
        y /= 1000;
      }
      if (scale == 0) return y.toInt().toString();
      if (y >= 100) return y.toStringAsFixed(0);
      if (y >= 10) return y.toStringAsFixed(1);
      return y.toStringAsFixed(2);
    }

    return '${fmt(value)}/${fmt(max)} ${units[scale]}';
  }

  /// A scrollable list: only the viewport rows around [selected] paint, so a
  /// 10 000-row list never ports all rows. The selection is reversed.
  void list(List<String> items, {int selected = 0}) {
    final height = _bounds.y + _bounds.h - _cy;
    if (height <= 0) return;
    var start = 0;
    if (items.length > height) {
      start = (selected - height ~/ 2).clamp(0, items.length - height);
    }
    for (var i = 0; i < height && start + i < items.length; i++) {
      final index = start + i;
      final marker = index == selected ? '❯' : ' ';
      if (index == selected) {
        // The marker wears the §7 accent, like the console's ❯.
        _grid.write(_bounds.x, _cy, marker, fg: _accent, attrs: const CellStyle(reverse: true));
        final rest = truncate(items[index], _bounds.w - 2);
        _grid.write(_bounds.x + 1, _cy, ' $rest', attrs: const CellStyle(reverse: true));
      } else {
        _grid.write(_bounds.x, _cy, truncate('$marker ${items[index]}', _bounds.w));
      }
      _cy++;
    }
  }

  /// Splits the remaining bounds: [vert] stacks rows, else columns. Children
  /// paint their share; [flex] weights shares (equal when omitted).
  void split(List<void Function(Canvas)> children, {required bool vert, List<int>? flex}) {
    final rest = Rect(_bounds.x, _cy, _bounds.w, _bounds.y + _bounds.h - _cy);
    if (rest.w <= 0 || rest.h <= 0 || children.isEmpty) return;
    final weights = flex ?? List<int>.filled(children.length, 1);
    final sizes = vert ? flexSplit(rest.h, weights) : flexSplit(rest.w, weights);
    var at = vert ? rest.y : rest.x;
    for (var i = 0; i < children.length; i++) {
      final box = vert ? Rect(rest.x, at, rest.w, sizes[i]) : Rect(at, rest.y, sizes[i], rest.h);
      at += sizes[i];
      if (box.w <= 0 || box.h <= 0) continue;
      final sub = Canvas._(_grid, bounds: box);
      children[i](sub);
      _clickables.addAll(sub._clickables);
      _overlays.addAll(sub._overlays);
      if (sub.cursorPos != null) cursorPos = sub.cursorPos;
    }
    _cy = rest.y + rest.h;
  }

  /// A labeled button: paints (reversed when [focused]) and registers its
  /// region; a pointer press inside it fires [onPress].
  void button(String label, {required void Function() onPress, bool focused = false}) {
    if (_cy >= _bounds.y + _bounds.h) return;
    final text = '[ $label ]';
    final x = _bounds.x;
    _grid.write(
      x,
      _cy,
      truncate(text, _bounds.w),
      fg: focused ? _accent : null,
      attrs: CellStyle(reverse: focused),
    );
    _clickables.add((rect: Rect(x, _cy, textWidth(text).clamp(0, _bounds.w), 1), onPress: onPress));
    _cy++;
  }

  /// An editable field: paints [state] with a block cursor when [focused] and
  /// records the hardware cursor position for the terminal. Text wider than
  /// the field scrolls to keep the cursor in view.
  void field(FieldState state, {bool focused = false, int? width}) {
    if (_cy >= _bounds.y + _bounds.h) return;
    final w = (width ?? _bounds.w).clamp(1, _bounds.w);
    final cls = clusters(state.text);
    final widths = [for (final c in cls) clusterWidth(c)];
    var cursorX = 0;
    for (var i = 0; i < state.cursor && i < widths.length; i++) {
      cursorX += widths[i];
    }
    // Scroll: the window starts as far right as needed to show the cursor.
    var start = 0;
    var startX = 0;
    while (start < cls.length && cursorX - startX >= w) {
      startX += widths[start];
      start++;
    }
    final shown = StringBuffer();
    var used = 0;
    for (var i = start; i < cls.length; i++) {
      if (used + widths[i] > w) break;
      shown.write(cls[i]);
      used += widths[i];
    }
    _grid.write(_bounds.x, _cy, shown.toString().padRight(w));
    if (focused) {
      final col = (cursorX - startX).clamp(0, w - 1);
      final prev = _grid.at(_bounds.x + col, _cy);
      _grid.set(_bounds.x + col, _cy, Cell(prev.text, prev.fg, prev.bg, const CellStyle(reverse: true)));
      cursorPos = (_bounds.x + col, _cy);
    }
    _cy++;
  }

  /// A tab row; the selected tab is reversed.
  void tabs(List<String> labels, {int selected = 0}) {
    if (_cy >= _bounds.y + _bounds.h) return;
    var x = _bounds.x;
    for (var i = 0; i < labels.length; i++) {
      final tab = ' ${labels[i]} ';
      if (x + textWidth(tab) > _bounds.x + _bounds.w) break;
      _grid.write(
        x,
        _cy,
        tab,
        fg: i == selected ? _accent : null,
        attrs: CellStyle(reverse: i == selected, bold: i == selected),
      );
      x += textWidth(tab) + 1;
    }
    _cy++;
  }

  /// A plain table: rows of cells padded to column widths.
  void table(List<List<String>> rows) {
    if (rows.isEmpty) return;
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final widths = List<int>.filled(cols, 0);
    for (final row in rows) {
      for (var i = 0; i < row.length; i++) {
        final w = textWidth(row[i]);
        if (w > widths[i]) widths[i] = w;
      }
    }
    for (final row in rows) {
      if (_cy >= _bounds.y + _bounds.h) return;
      final sb = StringBuffer();
      for (var i = 0; i < cols; i++) {
        final cell = i < row.length ? row[i] : '';
        sb.write(cell.padRight(widths[i] + (i < cols - 1 ? 2 : 0)));
      }
      _grid.write(_bounds.x, _cy, truncate(sb.toString(), _bounds.w));
      _cy++;
    }
  }

  /// A centered overlay frame painted after the main content; [build] draws
  /// inside its border. Dismissal (Esc, outside click) stays caller-owned.
  void popup({String? title, int width = 40, int height = 10, required void Function(Canvas) build}) {
    final w = width.clamp(4, _grid.width);
    final h = height.clamp(3, _grid.height);
    final box = Rect((_grid.width - w) ~/ 2, (_grid.height - h) ~/ 2, w, h);
    _overlays.add((Canvas ui) {
      final overlay = Canvas._(ui._grid, bounds: box);
      // Shade the frame area first so content behind does not peek through.
      for (var y = box.y; y < box.y + box.h; y++) {
        for (var x = box.x; x < box.x + box.w; x++) {
          ui._grid.set(x, y, const Cell(' '));
        }
      }
      // The frame swallows clicks: registered before the popup's own buttons,
      // so in reverse paint order its buttons win, then the shade, and nothing
      // behind the popup ever fires.
      ui._clickables.add((rect: box, onPress: () {}));
      overlay.box(title: title, build: build);
      ui._clickables.addAll(overlay._clickables);
      if (overlay.cursorPos != null) ui.cursorPos = overlay.cursorPos;
    });
  }

  /// Minimal Markdown: `#`/`##` headings bold, `- ` bullets, `**bold**`,
  /// `` `code` `` reversed, `> ` quotes dimmed. Runs share rows: one line of
  /// source wraps as one combined line, word breaks where they fall.
  void markdown(String source) {
    for (final raw in source.split('\n')) {
      var line = raw;
      var bold = false;
      var dim = false;
      if (line.startsWith('### ')) {
        line = line.substring(4);
        bold = true;
      } else if (line.startsWith('## ')) {
        line = line.substring(3);
        bold = true;
      } else if (line.startsWith('# ')) {
        line = line.substring(2);
        bold = true;
      } else if (line.startsWith('- ')) {
        line = '• ${line.substring(2)}';
      } else if (line.startsWith('> ')) {
        line = line.substring(2);
        dim = true;
      }
      // Words keep their run's style; spaces collapse, as in [wrap].
      final words = <(String, bool, bool)>[];
      for (final run in _inline(line)) {
        for (final piece in run.$1.split(' ')) {
          if (piece.isEmpty) continue;
          words.add((piece, run.$2, run.$3));
        }
      }
      if (words.isEmpty) continue;
      var x = 0;
      var fresh = true;
      void newline() {
        _cy++;
        x = 0;
        fresh = true;
      }

      for (final word in words) {
        var rest = word.$1;
        final wb = bold || word.$2, wc = word.$3;
        CellStyle style() => CellStyle(bold: wb, reverse: wc, dim: dim);
        while (true) {
          if (_cy >= _bounds.y + _bounds.h) return;
          if (!fresh && x + 1 + textWidth(rest) <= _bounds.w) {
            _grid.write(_bounds.x + x, _cy, ' $rest', attrs: style());
            x += 1 + textWidth(rest);
            break;
          }
          if (fresh && textWidth(rest) <= _bounds.w - x) {
            _grid.write(_bounds.x + x, _cy, rest, attrs: style());
            x += textWidth(rest);
            fresh = false;
            break;
          }
          if (fresh) {
            // An overlong word hard-cuts across rows.
            var piece = takeWidth(rest, _bounds.w - x);
            if (piece.isEmpty) piece = _head(rest); // wider than the row: clipped, but consumed
            _grid.write(_bounds.x + x, _cy, piece, attrs: style());
            x += textWidth(piece);
            fresh = false;
            rest = rest.substring(piece.length);
            if (rest.isNotEmpty) {
              newline();
            } else {
              break;
            }
          } else {
            newline();
          }
        }
      }
      _cy++;
    }
  }

  /// The first rune of [s], a surrogate pair kept whole.
  String _head(String s) {
    if (s.isEmpty) return s;
    final c = s.codeUnitAt(0);
    if (c >= 0xD800 && c <= 0xDBFF && s.length > 1) {
      final lo = s.codeUnitAt(1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) return s.substring(0, 2);
    }
    return s.substring(0, 1);
  }

  /// Splits [line] into (text, bold, code) runs on `**` and backticks.
  List<(String, bool, bool)> _inline(String line) {
    final out = <(String, bool, bool)>[];
    final buf = StringBuffer();
    var bold = false;
    var code = false;
    void flush() {
      if (buf.isNotEmpty) {
        out.add((buf.toString(), bold, code));
        buf.clear();
      }
    }

    var i = 0;
    while (i < line.length) {
      if (line.startsWith('**', i)) {
        flush();
        bold = !bold;
        i += 2;
      } else if (line[i] == '`') {
        flush();
        code = !code;
        i++;
      } else {
        buf.write(line[i]);
        i++;
      }
    }
    flush();
    return out;
  }

  /// Pixels drawn as half-block cells: two picture rows a cell, the upper
  /// pixel `▀`'s foreground and the lower its background (a lone lower pixel
  /// is `▄`). [frames] are images of one size (else an [ArgumentError]); more
  /// than one animates, [every] apart (frame picked by the clock). A pixel
  /// more than half transparent shows what is behind it (the cell is left
  /// alone). Larger than the _bounds, it scales down to fit. Sixel output
  /// stays deferred (terminal support matrix + image pipeline).
  void picture(List<Frame> frames, {Duration every = const Duration(milliseconds: 100)}) {
    if (frames.isEmpty) throw ArgumentError.value(frames, 'frames', 'Invalid frames: none');
    final width = frames.first.w, height = frames.first.h;
    if (width < 1 || height < 1) {
      throw ArgumentError.value((width, height), 'size', 'Invalid size, expected at least 1×1');
    }
    for (final f in frames) {
      if (f.w != width || f.h != height) {
        throw ArgumentError.value((f.w, f.h), 'frames', 'Invalid frame: every frame is $width×$height');
      }
    }
    if (every <= Duration.zero) throw ArgumentError.value(every, 'every', 'Invalid interval, expected more than zero');
    final frame = frames.length == 1
        ? frames[0].rgba
        : frames[DateTime.now().microsecondsSinceEpoch ~/ every.inMicroseconds % frames.length].rgba;
    final availH = (_bounds.y + _bounds.h - _cy) * 2;
    if (_bounds.w <= 0 || availH <= 0) return;
    final fit = [width / _bounds.w, height / availH, 1.0].reduce((a, b) => a > b ? a : b);
    final w = (width / fit).floor(), h = (height / fit).floor();
    TuiColor? at(int x, int y) {
      if (y >= h) return null;
      final i = (((y * fit).floor().clamp(0, height - 1)) * width + (x * fit).floor().clamp(0, width - 1)) * 4;
      return frame[i + 3] < 128 ? null : TuiColor.rgb(frame[i], frame[i + 1], frame[i + 2]);
    }

    for (var cy = 0; cy * 2 < h; cy++) {
      if (_cy >= _bounds.y + _bounds.h) return;
      for (var x = 0; x < w && _bounds.x + x < _bounds.x + _bounds.w; x++) {
        final top = at(x, cy * 2), bottom = at(x, cy * 2 + 1);
        if (top == null && bottom == null) continue;
        if (top == null) {
          _grid.set(_bounds.x + x, _cy, Cell('▄', bottom, null, const CellStyle()));
        } else {
          _grid.set(_bounds.x + x, _cy, Cell('▀', top, bottom, const CellStyle()));
        }
      }
      _cy++;
    }
  }

  /// Paints pending overlays (popups) over the main content.
  void _paintOverlays() {
    for (final overlay in _overlays) {
      overlay(this);
    }
    _overlays.clear();
  }
}
