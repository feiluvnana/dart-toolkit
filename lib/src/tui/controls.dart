part of '../../tui.dart';

/// [item]'s label as spans, the filter's matches in the accent.
List<Span> _highlighted(ItemView<Object?> item) => [
  for (final (text, matched) in item.parts)
    Span(text, matched ? item.palette.accent + const Style(bold: true) : Style.none),
];

/// A scrolling, selectable list of [choice]'s items: arrows, Home/End, PgUp/PgDn, the wheel and
/// clicks move it; it filters and checks as [choice] says. [item] draws a row in place of the
/// theme's.
///
/// ```dart
/// final pick = Choice(servers, label: (s) => s.host, filter: true);
/// … Menu(pick) …
/// Menu(files, item: (c) => Label('${c.isChecked! ? '[x]' : '[ ]'} ${c.label}'))
/// ```
///
/// {@category CLI}
final class Menu<T> extends Widget {
  final Choice<T> choice;
  final Widget Function(ItemView<T> view)? item;

  /// Shown when the filter matches nothing.
  final String empty;
  final bool scrollbar;

  const Menu(this.choice, {this.item, this.empty = 'No matches', this.scrollbar = true});

  @override
  int get width => KeysBridge.widest(choice) + (choice.multi ? 4 : 2) + (scrollbar ? 1 : 0);

  /// The rows the filter leaves, or one for [empty].
  @override
  int heightAt(int width) => choice.shown.isEmpty ? 1 : choice.shown.length;

  @override
  void paint(Canvas canvas) {
    final focused = canvas.focus(choice);
    final shown = choice.shown;
    if (shown.isEmpty) {
      canvas.text(2, 0, empty, canvas.palette.muted);
      return;
    }
    _list(canvas, choice, shown.length, scrollbar, (n, w, hovered) {
      final i = shown[n];
      final view = ItemView<T>(
        index: i,
        value: choice.items[i],
        label: choice.label(i),
        isSelected: i == choice.index,
        isChecked: choice.multi ? choice.checked.contains(i) : null,
        isFocused: focused,
        isHovered: hovered,
        matches: choice.matchesOf(i),
        palette: canvas.palette,
      );
      return item?.call(view) ?? canvas.theme.item(view);
    });
  }
}

/// Paints [count] rows built by [row] with [choice]'s cursor kept in view, and a scrollbar.
void _list(
  Canvas canvas,
  Choice<Object?> choice,
  int count,
  bool scrollbar,
  Widget Function(int n, int width, bool hovered) row,
) {
  final layout = KeysBridge.layout(choice);
  final pos = KeysBridge.position(choice).clamp(0, count - 1);
  final bar = scrollbar && count > canvas.height ? 1 : 0;
  final w = canvas.width - bar;
  if (pos < layout.offset) layout.offset = pos;
  // Rows can be taller than one line: walk back from the cursor until the screen is full.
  var used = 0, first = pos;
  for (var n = pos; n >= 0; n--) {
    used += row(n, w, false).heightAt(w);
    if (used > canvas.height) break;
    first = n;
  }
  if (layout.offset < first) layout.offset = first;
  if (layout.offset > count - 1) layout.offset = count - 1;
  var y = 0;
  var n = layout.offset;
  final rows = <int>[];
  for (; n < count && y < canvas.height; n++) {
    final probe = row(n, w, false);
    final h = probe.heightAt(w);
    final area = canvas.area(0, y, w, h);
    area.draw(area.isHovered ? row(n, w, true) : probe);
    y += h;
    rows.addAll(List.filled(h, n));
  }
  layout.rows = rows;
  layout.page = (n - layout.offset).clamp(1, count);
  if (bar == 1) _scrollbar(canvas, layout.offset, layout.page, count);
}

/// A scrollbar down the canvas's last column: a thumb for [page] of [count] rows from [offset].
void _scrollbar(Canvas canvas, int offset, int page, int count) {
  final p = canvas.palette;
  final thumb = (canvas.height * canvas.height / count).ceil().clamp(1, canvas.height);
  final top = ((canvas.height - thumb) * offset / (count - page).clamp(1, count)).round();
  for (var y = 0; y < canvas.height; y++) {
    final on = y >= top && y < top + thumb;
    canvas.text(canvas.width - 1, y, on ? p.scrollThumb : p.scrollTrack, on ? p.text : p.muted);
  }
}

String _name(Object? v) => v is Enum ? v.name : '$v';

/// `› ◉ label`: the pointer on the cursor's row, a check box when several are picked, the
/// matches lit; the hovered row underlined.
Widget _menuRow(ItemView<Object?> c) {
  final p = c.palette;
  return Label.spans(
    [
      Span(c.isSelected ? '${p.pointer} ' : '  ', p.accent),
      if (c.isChecked case final checked?) Span('${checked ? p.checked : p.unchecked} ', checked ? p.accent : p.muted),
      ..._highlighted(c),
    ],
    style: c.isSelected && c.isFocused ? p.selected : (c.isHovered ? const Style(underline: true) : null),
    wrap: false,
  );
}

/// ` Logs `: the selected tab in the accent, bold and underlined, the rest muted.
Widget _tabTitle(ItemView<String> c) => Label(
  ' ${c.label} ',
  style: c.isSelected
      ? c.palette.accent + const Style(bold: true, underline: true)
      : (c.isHovered ? c.palette.text : c.palette.muted),
  wrap: false,
);

/// A cell's value at its column's alignment, a header's in the accent and bold.
Widget _gridCell(CellView c) => Label(
  _name(c.value ?? ''),
  align: c.align,
  wrap: false,
  style: c.isHeader ? c.palette.accent + const Style(bold: true) : null,
);

/// A [Grid] cell, the header's too, for its `cell:` builder.
///
/// {@category CLI}
final class CellView {
  /// The row's index in the grid's rows, or `-1` for the header.
  final int row;
  final int column;

  /// The cell's value; a header cell's is its column name.
  final Object? value;

  /// How the column sits: [Grid.align]'s, else right for a column of numbers.
  final Align align;

  /// Whether the cursor is on this row, the grid has the focus, the pointer is over the row.
  final bool isSelected, isFocused, isHovered;
  final Palette palette;

  const CellView({
    required this.row,
    required this.column,
    required this.value,
    this.align = Align.left,
    this.isSelected = false,
    this.isFocused = false,
    this.isHovered = false,
    this.palette = const Palette(),
  });

  bool get isHeader => row < 0;
}

/// A table: [rows] under a header of [columns]; with a [choice] over the same rows it is
/// selectable, filters and scrolls. A `Table` draws as `Grid(table.columns, table.rows)`.
///
/// Column widths fit the content unless [widths] says; a `0` in it takes what is left. [align]
/// places a column by name; a column of numbers is right-aligned unless it says.
///
/// ```dart
/// final pick = Choice(table.rows, filter: true);
/// Grid(table.columns, table.rows, choice: pick)
/// ```
///
/// {@category CLI}
final class Grid extends Widget {
  final List<String> columns;
  final List<Map<String, Object?>> rows;
  final List<int>? widths;
  final Map<String, Align> align;

  /// Where the cursor and the filter stand over [rows]: a [Choice] of these same rows.
  final Choice<Map<String, Object?>>? choice;

  /// Draws a cell, the header's included, in place of the theme's.
  final Widget Function(CellView view)? cell;
  final int gap;
  final bool scrollbar;

  Grid(
    this.columns,
    this.rows, {
    this.widths,
    this.align = const {},
    this.choice,
    this.cell,
    this.gap = 2,
    this.scrollbar = true,
  }) {
    if (choice case final c? when !identical(c.items, rows)) {
      throw ArgumentError.value(choice, 'choice', 'Invalid choice: its items are not these rows');
    }
  }

  /// Each row's cells, in [columns] order.
  late final List<List<Object?>> _cells = [
    for (final r in rows) [for (final c in columns) r[c]],
  ];

  /// How each column sits: [align]'s, else right for a column of numbers.
  late final List<Align> _aligns = [
    for (final (i, c) in columns.indexed)
      align[c] ?? (_cells.isNotEmpty && _cells.every((r) => r[i] == null || r[i] is num) ? Align.right : Align.left),
  ];

  int get _count => columns.length;

  /// Each column's widest cell, built in [t]: what the canvas draws them in.
  List<int> _natural([TuiTheme t = const TuiTheme()]) {
    final build = cell ?? t.cell;
    final plain = identical(build, _gridCell);
    final ws = List.filled(_count, 0);
    void fit(int row, int col, Object? v) {
      final cw = plain
          ? Style.width(_name(v ?? ''))
          : build(CellView(row: row, column: col, value: v, align: _aligns[col], palette: t.palette)).width;
      if (cw > ws[col]) ws[col] = cw;
    }

    for (final (c, v) in columns.indexed) {
      fit(-1, c, v);
    }
    for (final (i, r) in _cells.indexed) {
      for (final (c, v) in r.indexed) {
        fit(i, c, v);
      }
    }
    return ws;
  }

  List<int> _widths(int width, TuiTheme theme) {
    final n = _count;
    final room = width - gap * (n - 1).clamp(0, n) - (choice != null ? 2 : 0);
    final avail = room < 0 ? 0 : room;
    final base = widths ?? _natural(theme);
    final ws = [...base, for (var i = base.length; i < n; i++) 0];
    if (widths != null) {
      final rest = avail - _sum(ws);
      final zeros = ws.where((w) => w == 0).length;
      for (var i = 0; i < n; i++) {
        if (ws[i] == 0 && zeros > 0) ws[i] = (rest ~/ zeros).clamp(0, avail);
      }
      return ws;
    }
    // Too wide: take columns from the widest first.
    var total = _sum(ws);
    while (total > avail && total > 0) {
      var widest = 0;
      for (var i = 1; i < n; i++) {
        if (ws[i] > ws[widest]) widest = i;
      }
      if (ws[widest] <= 3) break;
      ws[widest]--;
      total--;
    }
    return ws;
  }

  @override
  int get width {
    final ws = _natural();
    return _sum(ws) + gap * (ws.length - 1).clamp(0, ws.length) + (choice != null ? 2 : 0) + 1;
  }

  @override
  int heightAt(int width) => rows.length + 1;

  Widget _line(List<int> ws, int row, bool selected, bool focused, bool hovered, TuiTheme t) {
    final values = row < 0 ? columns : _cells[row];
    final p = t.palette;
    return Paint((c) {
      if (selected && focused) c.fill(p.selected);
      var x = choice != null ? 2 : 0;
      if (selected) c.text(0, 0, '${p.pointer} ', p.accent);
      final build = cell ?? t.cell;
      for (var col = 0; col < ws.length; col++) {
        final value = col < values.length ? values[col] : null;
        final area = c.area(x, 0, ws[col], 1);
        // The default look, drawn straight: a grid repaints every cell every frame.
        if (!identical(build, _gridCell)) {
          area.draw(
            build(
              CellView(
                row: row,
                column: col,
                value: value,
                align: _aligns[col],
                isSelected: selected,
                isFocused: focused,
                isHovered: hovered,
                palette: p,
              ),
            ),
          );
        } else {
          final text = Style.truncate(_name(value ?? ''), ws[col], ellipsis: p.ellipsis);
          area.text(
            0,
            0,
            Style.pad(text, ws[col], align: _aligns[col]),
            row < 0 ? p.accent + const Style(bold: true) : (hovered ? const Style(underline: true) : p.text),
          );
        }
        x += ws[col] + gap;
      }
    });
  }

  @override
  void paint(Canvas canvas) {
    final t = canvas.theme;
    final body = canvas.area(0, 1);
    final pick = choice;
    final focused = pick != null && body.focus(pick);
    final bar = scrollbar && rows.length > body.height ? 1 : 0;
    final ws = _widths(canvas.width - bar, t);
    canvas.area(0, 0, canvas.width - bar, 1).draw(_line(ws, -1, false, focused, false, t));
    if (pick == null) {
      for (var y = 0; y < body.height && y < rows.length; y++) {
        body.area(0, y, canvas.width - bar, 1).draw(_line(ws, y, false, false, false, t));
      }
      if (bar == 1) _scrollbar(body, 0, body.height, rows.length);
      return;
    }
    final shown = pick.shown;
    if (shown.isEmpty) return;
    _list(
      body,
      pick,
      shown.length,
      scrollbar,
      (n, w, hovered) => _line(ws, shown[n], shown[n] == pick.index, focused, hovered, t),
    );
  }
}

/// A row of tabs, [choice]'s items their titles; it picks one (Left/Right while it has the
/// focus, or a click).
///
/// ```dart
/// final tab = Choice(['Logs', 'Stats']);
/// VStack([Tabs(tab), [logs, stats][tab.index].flex()])
/// ```
///
/// {@category CLI}
final class Tabs extends Widget {
  final Choice<String> choice;
  final Widget Function(ItemView<String> view)? tab;
  final String divider;

  const Tabs(this.choice, {this.tab, this.divider = '│'});

  List<String> get _titles => choice.items;

  @override
  int get width => _sum(_titles.map((t) => Style.width(t) + 2)) + (_titles.length - 1).clamp(0, _titles.length);

  @override
  void paint(Canvas canvas) {
    final layout = KeysBridge.layout(choice)..horizontal = true;
    final focused = canvas.focus(choice);
    final p = canvas.palette;
    var x = 0;
    final spans = <(int, int)>[];
    for (final (i, title) in _titles.indexed) {
      if (i > 0) x = canvas.text(x, 0, divider, p.muted);
      ItemView<String> view(bool hovered) => ItemView<String>(
        index: i,
        value: title,
        label: title,
        isSelected: i == choice.index,
        isFocused: focused,
        isHovered: hovered,
        palette: p,
      );
      final probe = (tab ?? canvas.theme.tab)(view(false));
      final area = canvas.area(x, 0, probe.width, 1);
      area.draw(area.isHovered ? (tab ?? canvas.theme.tab)(view(true)) : probe);
      spans.add((x, x + probe.width));
      x += probe.width;
    }
    layout.tabs = spans;
  }
}
