/// The immediate-mode canvas: widgets paint cells into [grid] inside [bounds],
/// flowing down from the cursor. `split` carves bounded child canvases;
/// `popup` paints centered overlays last. Caller-owned state throughout
/// (`selected`, `FieldState`, focus flags).
///
/// ```dart
/// term.draw((ui) {
///   ui.box(title: 'Menu', build: (menu) {
///     menu.list(['Overview', 'Settings'], selected: sel);
///   });
/// });
/// ```
library;

import '../image/image.dart';
import 'buffer.dart';
import 'events.dart';
import 'layout.dart';
import 'width.dart';

/// Editable single-line text: the caller owns it, paints it with
/// `ui.field(state)`, and feeds it events with `state.handle(ev)`.
final class FieldState {
  String _text;
  int _cursor;

  FieldState([String text = '']) : _text = text, _cursor = text.runes.length;

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
    final runes = _text.runes.toList();
    switch (ev.name) {
      case 'backspace':
        if (_cursor > 0) {
          runes.removeAt(_cursor - 1);
          _text = String.fromCharCodes(runes);
          _cursor--;
        }
        return true;
      case 'delete':
        if (_cursor < runes.length) {
          runes.removeAt(_cursor);
          _text = String.fromCharCodes(runes);
        }
        return true;
      case 'left':
        if (_cursor > 0) _cursor--;
        return true;
      case 'right':
        if (_cursor < runes.length) _cursor++;
        return true;
      case 'home':
        _cursor = 0;
        return true;
      case 'end':
        _cursor = runes.length;
        return true;
      default:
        return false;
    }
  }

  void _insert(String s) {
    final runes = _text.runes.toList();
    runes.insertAll(_cursor, s.runes);
    _text = String.fromCharCodes(runes);
    _cursor += s.runes.length;
  }
}

/// The canvas widgets paint on: a [grid], a clip [bounds], a cursor, the
/// click regions painted this frame, and pending overlays.
final class Canvas {
  final Grid grid;
  Rect bounds;
  int _cy;
  final List<({Rect rect, void Function() onPress})> clickables = [];
  final List<void Function(Canvas)> _overlays = [];

  /// Hardware cursor position (column, row), set by [field] when focused.
  (int, int)? cursorPos;

  Canvas(this.grid, {Rect? bounds})
    : bounds = bounds ?? Rect(0, 0, grid.width, grid.height),
      _cy = (bounds ?? Rect(0, 0, grid.width, grid.height)).y;

  /// A titled frame. With [build], the content paints inside the border;
  /// without it (flat form) content flows until [end].
  /// A too-long title is truncated with `…`, never overflowing.
  void box({String? title, int padding = 0, void Function(Canvas)? build}) {
    if (_cy >= bounds.y + bounds.h) return;
    final w = bounds.w;
    if (w < 2) return;
    final inner = w - 2;
    if (title == null) {
      _rule('┌${'─' * inner}┐');
    } else {
      final label = truncate(' $title ', inner);
      _rule('┌─$label${'─' * (inner - textWidth(label))}┐');
    }
    if (build == null) {
      _open.add(Rect(bounds.x + 1, _cy, inner, bounds.y + bounds.h - _cy));
      return;
    }
    final content = Rect(bounds.x + 1 + padding, _cy, inner - padding * 2, bounds.y + bounds.h - _cy - 1);
    final sub = Canvas(grid, bounds: content);
    build(sub);
    clickables.addAll(sub.clickables);
    _overlays.addAll(sub._overlays);
    if (sub.cursorPos != null) cursorPos = sub.cursorPos;
    _cy = bounds.y + bounds.h - 1;
    _rule('└${'─' * inner}┘');
  }

  final List<Rect> _open = [];

  /// Closes the most recent flat [box]: the bottom rule. (The flat form keeps
  /// the legacy static-frame look — border top and bottom, raw lines between;
  /// nested frames want `box(build:)`.)
  void end() {
    if (_open.isEmpty) return;
    final box = _open.removeLast();
    _rule('└${'─' * box.w}┘');
  }

  void _rule(String line) {
    if (_cy < bounds.y + bounds.h) {
      grid.write(bounds.x, _cy, truncate(line, bounds.w));
      _cy++;
    }
  }

  /// A line of text, wrapped to the bounds.
  void text(String s, {TuiColor? fg, TuiColor? bg, CellStyle style = const CellStyle()}) {
    for (final line in wrap(s, bounds.w)) {
      if (_cy >= bounds.y + bounds.h) return;
      grid.write(bounds.x, _cy, line, fg: fg, bg: bg, attrs: style);
      _cy++;
    }
  }

  /// A spinner and its [label] on one line: the frame comes from the clock, so it turns
  /// whenever the loop redraws (poll with a `timeout` to keep it moving). [fg] colours the
  /// spinner; [style] applies to the label.
  void spinner(String label, {TuiColor? fg, CellStyle style = const CellStyle(), SpinGlyphs glyphs = SpinGlyphs.dots}) {
    if (_cy >= bounds.y + bounds.h) return;
    final frame = glyphs.frame();
    grid.write(bounds.x, _cy, frame, fg: fg);
    final at = textWidth(frame) + 1;
    if (at < bounds.w) grid.write(bounds.x + at, _cy, truncate(label, bounds.w - at), attrs: style);
    _cy++;
  }

  /// A labeled gauge filling the bounds width ([glyphs] picks the set;
  /// [BarGlyphs.ascii] where the terminal cannot draw Unicode).
  void bar(num value, num max, {String? label, String? unit, int? width, BarGlyphs glyphs = BarGlyphs.line}) {
    if (_cy >= bounds.y + bounds.h) return;
    final w = (width ?? bounds.w).clamp(10, bounds.w);
    final ratio = max <= 0 ? 1.0 : (value / max).clamp(0.0, 1.0);
    final pct = '${(ratio * 100).toStringAsFixed(0)}%';
    final suffix = unit == null ? '' : ' $value/$max $unit';
    final fixed = '${label == null ? '' : '$label '}$pct$suffix ';
    final glyphsWidth = (w - textWidth(fixed) - 2).clamp(1, w);
    grid.write(bounds.x, _cy, '$fixed[${glyphs.draw(ratio, glyphsWidth)}]', fg: TuiColor.green);
    _cy++;
  }

  /// A scrollable list: only the viewport rows around [selected] paint, so a
  /// 10 000-row list never ports all rows. The selection is reversed.
  void list(List<String> items, {int selected = 0}) {
    final height = bounds.y + bounds.h - _cy;
    if (height <= 0) return;
    var start = 0;
    if (items.length > height) {
      start = (selected - height ~/ 2).clamp(0, items.length - height);
    }
    for (var i = 0; i < height && start + i < items.length; i++) {
      final index = start + i;
      final marker = index == selected ? '▸' : ' ';
      final line = truncate('$marker ${items[index]}', bounds.w);
      if (index == selected) {
        grid.write(bounds.x, _cy, line, attrs: const CellStyle(reverse: true));
      } else {
        grid.write(bounds.x, _cy, line);
      }
      _cy++;
    }
  }

  /// Splits the remaining bounds: [vert] stacks rows, else columns. Children
  /// paint their share; [flex] weights shares (equal when omitted).
  void split(List<void Function(Canvas)> children, {required bool vert, List<int>? flex}) {
    final rest = Rect(bounds.x, _cy, bounds.w, bounds.y + bounds.h - _cy);
    if (rest.w <= 0 || rest.h <= 0 || children.isEmpty) return;
    final weights = flex ?? List<int>.filled(children.length, 1);
    final sizes = vert ? flexSplit(rest.h, weights) : flexSplit(rest.w, weights);
    var at = vert ? rest.y : rest.x;
    for (var i = 0; i < children.length; i++) {
      final box = vert ? Rect(rest.x, at, rest.w, sizes[i]) : Rect(at, rest.y, sizes[i], rest.h);
      at += sizes[i];
      if (box.w <= 0 || box.h <= 0) continue;
      final sub = Canvas(grid, bounds: box);
      children[i](sub);
      clickables.addAll(sub.clickables);
      _overlays.addAll(sub._overlays);
      if (sub.cursorPos != null) cursorPos = sub.cursorPos;
    }
    _cy = rest.y + rest.h;
  }

  /// A labeled button: paints (reversed when [focused]) and registers its
  /// region; a pointer press inside it fires [onPress].
  void button(String label, {required void Function() onPress, bool focused = false}) {
    if (_cy >= bounds.y + bounds.h) return;
    final text = '[ $label ]';
    final x = bounds.x;
    grid.write(x, _cy, truncate(text, bounds.w), attrs: CellStyle(reverse: focused));
    clickables.add((rect: Rect(x, _cy, textWidth(text).clamp(0, bounds.w), 1), onPress: onPress));
    _cy++;
  }

  /// An editable field: paints [state] with a block cursor when [focused] and
  /// records the hardware cursor position for the terminal.
  void field(FieldState state, {bool focused = false, int? width}) {
    if (_cy >= bounds.y + bounds.h) return;
    final w = (width ?? bounds.w).clamp(1, bounds.w);
    final shown = truncate(state.text, w);
    grid.write(bounds.x, _cy, shown.padRight(w));
    if (focused) {
      // Cursor column in display cells (rune-aware).
      var col = 0;
      var i = 0;
      for (final rune in state.text.runes) {
        if (i >= state.cursor) break;
        col += charWidth(rune);
        i++;
      }
      col = col.clamp(0, w - 1);
      final prev = grid.at(bounds.x + col, _cy);
      grid.set(bounds.x + col, _cy, Cell(prev.text, prev.fg, prev.bg, const CellStyle(reverse: true)));
      cursorPos = (bounds.x + col, _cy);
    }
    _cy++;
  }

  /// A tab row; the selected tab is reversed.
  void tabs(List<String> labels, {required int selected}) {
    if (_cy >= bounds.y + bounds.h) return;
    var x = bounds.x;
    for (var i = 0; i < labels.length; i++) {
      final tab = ' ${labels[i]} ';
      if (x + textWidth(tab) > bounds.x + bounds.w) break;
      grid.write(
        x,
        _cy,
        tab,
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
      if (_cy >= bounds.y + bounds.h) return;
      final sb = StringBuffer();
      for (var i = 0; i < cols; i++) {
        final cell = i < row.length ? row[i] : '';
        sb.write(cell.padRight(widths[i] + (i < cols - 1 ? 2 : 0)));
      }
      grid.write(bounds.x, _cy, truncate(sb.toString(), bounds.w));
      _cy++;
    }
  }

  /// A centered overlay frame painted after the main content; [build] draws
  /// inside its border. Dismissal (Esc, outside click) stays caller-owned.
  void popup({String? title, int width = 40, int height = 10, required void Function(Canvas) build}) {
    final w = width.clamp(4, grid.width);
    final h = height.clamp(3, grid.height);
    final box = Rect((grid.width - w) ~/ 2, (grid.height - h) ~/ 2, w, h);
    _overlays.add((Canvas ui) {
      final overlay = Canvas(ui.grid, bounds: box);
      // Shade the frame area first so content behind does not peek through.
      for (var y = box.y; y < box.y + box.h; y++) {
        for (var x = box.x; x < box.x + box.w; x++) {
          ui.grid.set(x, y, const Cell(' '));
        }
      }
      overlay.box(title: title, build: build);
      ui.clickables.addAll(overlay.clickables);
      if (overlay.cursorPos != null) ui.cursorPos = overlay.cursorPos;
    });
  }

  /// Minimal Markdown: `#`/`##` headings bold, `- ` bullets, `**bold**`,
  /// `` `code` `` reversed, `> ` quotes dimmed.
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
      for (final piece in _inline(line)) {
        if (_cy >= bounds.y + bounds.h) return;
        for (final wrapped in wrap(piece.$1, bounds.w)) {
          if (_cy >= bounds.y + bounds.h) return;
          grid.write(
            bounds.x,
            _cy,
            wrapped,
            attrs: CellStyle(bold: bold || piece.$2, reverse: piece.$3, dim: dim),
          );
          _cy++;
        }
      }
    }
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
  /// alone). Larger than the bounds, it scales down to fit. Sixel output
  /// stays deferred (terminal support matrix + image pipeline).
  void picture(List<Image> frames, {Duration every = const Duration(milliseconds: 100)}) {
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
    final availH = (bounds.y + bounds.h - _cy) * 2;
    if (bounds.w <= 0 || availH <= 0) return;
    final fit = [width / bounds.w, height / availH, 1.0].reduce((a, b) => a > b ? a : b);
    final w = (width / fit).floor(), h = (height / fit).floor();
    TuiColor? at(int x, int y) {
      if (y >= h) return null;
      final i = (((y * fit).floor().clamp(0, height - 1)) * width + (x * fit).floor().clamp(0, width - 1)) * 4;
      return frame[i + 3] < 128 ? null : TuiColor.rgb(frame[i], frame[i + 1], frame[i + 2]);
    }

    for (var cy = 0; cy * 2 < h; cy++) {
      if (_cy >= bounds.y + bounds.h) return;
      for (var x = 0; x < w && bounds.x + x < bounds.x + bounds.w; x++) {
        final top = at(x, cy * 2), bottom = at(x, cy * 2 + 1);
        if (top == null && bottom == null) continue;
        if (top == null) {
          grid.set(bounds.x + x, _cy, Cell('▄', bottom, null, const CellStyle()));
        } else {
          grid.set(bounds.x + x, _cy, Cell('▀', top, bottom, const CellStyle()));
        }
      }
      _cy++;
    }
  }

  /// Paints pending overlays (popups) over the main content.
  void paintOverlays() {
    for (final overlay in _overlays) {
      overlay(this);
    }
    _overlays.clear();
  }
}
