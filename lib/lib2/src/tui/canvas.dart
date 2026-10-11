/// The immediate-mode canvas: widgets paint cells into [grid] inside [bounds],
/// flowing down from the cursor. `split` carves bounded child canvases;
/// `popup` paints centered overlays last. Caller-owned state throughout
/// (`sel`, `FieldState`, focus flags) — the proposal's style.
///
/// ```dart
/// term.draw((ui) {
///   ui.box(title: 'Menu', build: (menu) {
///     menu.list(['Overview', 'Settings'], sel: sel);
///   });
/// });
/// ```
library;

import 'buffer.dart';
import 'events.dart';
import 'layout.dart';
import 'width.dart';

/// A clickable region: painted by [button], fired by `Term.click`.
final class Clickable {
  final Rect rect;
  final void Function() onPressed;
  Clickable(this.rect, this.onPressed);
}

/// A board row: a labeled fraction with trailing text.
final class BoardRow {
  final String label;
  final num val;
  final num max;
  const BoardRow(this.label, this.val, this.max);
}

/// Editable single-line text: the caller owns it, paints it with
/// `ui.field(state)`, and feeds it events with `state.handle(ev)`.
final class FieldState {
  String _text;
  int _cursor;

  FieldState([String text = ''])
      : _text = text,
        _cursor = text.runes.length;

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
  final List<Clickable> clickables = [];
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
  void text(
    Object content, {
    TuiColor? fg,
    TuiColor? bg,
    bool bold = false,
    bool dim = false,
    bool italic = false,
    bool underline = false,
    bool reverse = false,
  }) {
    final style = CellStyle(bold: bold, dim: dim, italic: italic, underline: underline, reverse: reverse);
    for (final line in wrap(content.toString(), bounds.w)) {
      if (_cy >= bounds.y + bounds.h) return;
      grid.write(bounds.x, _cy, line, fg: fg, bg: bg, attrs: style);
      _cy++;
    }
  }

  /// A labeled gauge filling the bounds width.
  void bar({required num val, required num max, String? label, String? unit, int? width}) {
    if (_cy >= bounds.y + bounds.h) return;
    final w = (width ?? bounds.w).clamp(10, bounds.w);
    final ratio = max <= 0 ? 1.0 : (val / max).clamp(0.0, 1.0);
    final pct = '${(ratio * 100).toStringAsFixed(0)}%';
    final suffix = unit == null ? '' : ' $val/$max $unit';
    final fixed = '${label == null ? '' : '$label '}$pct$suffix ';
    final glyphs = (w - textWidth(fixed) - 2).clamp(1, w);
    final filled = (ratio * glyphs).round().clamp(0, glyphs);
    grid.write(bounds.x, _cy, '$fixed[${'█' * filled}${'░' * (glyphs - filled)}]', fg: TuiColor.green);
    _cy++;
  }

  /// A scrollable list: only the viewport rows around [sel] paint, so a
  /// 10 000-row list never ports all rows. The selection is reversed.
  void list(List<String> items, {int sel = 0}) {
    final height = bounds.y + bounds.h - _cy;
    if (height <= 0) return;
    var start = 0;
    if (items.length > height) {
      start = (sel - height ~/ 2).clamp(0, items.length - height);
    }
    for (var i = 0; i < height && start + i < items.length; i++) {
      final index = start + i;
      final marker = index == sel ? '▸' : ' ';
      final line = truncate('$marker ${items[index]}', bounds.w);
      if (index == sel) {
        grid.write(bounds.x, _cy, line, attrs: const CellStyle(reverse: true));
      } else {
        grid.write(bounds.x, _cy, line);
      }
      _cy++;
    }
  }

  /// A selectable menu of values, labeled per row.
  void menu<T>(List<T> items, {required String Function(T) label, required int sel}) =>
      list([for (final item in items) label(item)], sel: sel);

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

  /// [n] blank lines.
  void gap([int n = 1]) {
    for (var i = 0; i < n && _cy < bounds.y + bounds.h; i++) {
      _cy++;
    }
  }

  /// A labeled button: paints (reversed when [focused]) and registers its
  /// region; `Term.click` fires [onPressed] for pointer presses inside it.
  void button(String label, {required void Function() onPressed, bool focused = false}) {
    if (_cy >= bounds.y + bounds.h) return;
    final text = '[ $label ]';
    final x = bounds.x;
    grid.write(x, _cy, truncate(text, bounds.w), attrs: CellStyle(reverse: focused));
    clickables.add(Clickable(Rect(x, _cy, textWidth(text).clamp(0, bounds.w), 1), onPressed));
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
  void tabs(List<String> labels, {required int sel}) {
    if (_cy >= bounds.y + bounds.h) return;
    var x = bounds.x;
    for (var i = 0; i < labels.length; i++) {
      final tab = ' ${labels[i]} ';
      if (x + textWidth(tab) > bounds.x + bounds.w) break;
      grid.write(x, _cy, tab, attrs: CellStyle(reverse: i == sel, bold: i == sel));
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

  /// Status rows: a label and a fraction bar each.
  void board(List<BoardRow> rows) {
    for (final row in rows) {
      if (_cy >= bounds.y + bounds.h) return;
      bar(val: row.val, max: row.max, label: row.label);
    }
  }

  /// Trailing viewport over [lines]: the last rows that fit, scrolled up by
  /// [offset].
  void log(List<String> lines, {int offset = 0}) {
    final height = bounds.y + bounds.h - _cy;
    if (height <= 0) return;
    final end = (lines.length - offset).clamp(0, lines.length);
    final start = (end - height).clamp(0, end);
    for (var i = start; i < end; i++) {
      for (final wrapped in wrap(lines[i], bounds.w)) {
        if (_cy >= bounds.y + bounds.h) return;
        grid.write(bounds.x, _cy, wrapped);
        _cy++;
      }
    }
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

  /// Paints pending overlays (popups) over the main content.
  void paintOverlays() {
    for (final overlay in _overlays) {
      overlay(this);
    }
    _overlays.clear();
  }
}
