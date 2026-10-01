part of '../../tui.dart';

/// Something that takes the focus: keys reach it before `update`, Tab moves between them.
abstract class _Control {
  /// Handles a key, character or paste; `true` when it used it, so `update` does not see it.
  bool _handle(Object event);

  /// A click or wheel at [x], [y] inside it.
  void _mouse(Mouse event, int x, int y) {}
}

/// The state of a [Menu], [Grid] or [Tabs]: the cursor, the filter, the checked items.
///
/// Hold one per list (in the app state or beside it); the widget is rebuilt each frame around it.
/// With [filter], typed text narrows the list; with [multi], Space checks the cursor's item.
///
/// ```dart
/// final pick = Choice(filter: true);
/// … Menu(files, pick) …
/// Key.enter => Tui.quit(files[pick.index]),
/// ```
///
/// {@category CLI}
final class Choice extends _Control {
  /// The cursor's item, as an index into the full list; `-1` when the filter matches nothing.
  int index;

  /// What has been typed into the filter.
  String query = '';

  /// The checked items' indexes, with [multi].
  final Set<int> checked = {};

  final bool filter, multi;

  /// The items shown at the last frame, as indexes into the full list.
  List<int> _shown = const [];
  int _offset = 0, _page = 1;
  bool _horizontal = false;

  /// Where each tab was drawn, and which item each row shows: for clicks.
  List<(int, int)> _tabs = const [];
  List<int> _rows = const [];

  Choice({this.index = 0, this.filter = false, this.multi = false, Iterable<int> checked = const []}) {
    this.checked.addAll(checked);
  }

  /// Settles the cursor and filter on a list of [count] items labelled by [label].
  void _settle(int count, String Function(int) label) {
    final q = query.toLowerCase();
    _shown = [
      for (var i = 0; i < count; i++)
        if (q.isEmpty || _match(label(i).toLowerCase(), q) != null) i,
    ];
    if (_shown.isEmpty) {
      index = -1;
    } else if (!_shown.contains(index)) {
      index = _shown.firstWhere((i) => i >= index, orElse: () => _shown.last);
    }
  }

  int get _pos => _shown.indexOf(index);

  void _move(int by) {
    if (_shown.isEmpty) return;
    index = _shown[(_pos + by).clamp(0, _shown.length - 1)];
  }

  @override
  bool _handle(Object event) {
    final (back, forward) = _horizontal ? (Key.left, Key.right) : (Key.up, Key.down);
    switch (event) {
      case _ when event == back:
        _move(-1);
      case _ when event == forward:
        _move(1);
      case Key.home when !_horizontal:
        _move(-_shown.length);
      case Key.end when !_horizontal:
        _move(_shown.length);
      case Key.pageUp when !_horizontal:
        _move(-_page);
      case Key.pageDown when !_horizontal:
        _move(_page);
      case Char(char: ' ', alt: false) when multi && index >= 0:
        if (!checked.remove(index)) checked.add(index);
      case Char(:final char, alt: false) when filter:
        query += char;
      case Paste(:final text) when filter:
        query += text.replaceAll('\n', ' ');
      case Key.backspace when filter && query.isNotEmpty:
        query = String.fromCharCodes(query.runes.toList()..removeLast());
      default:
        return false;
    }
    return true;
  }

  @override
  void _mouse(Mouse event, int x, int y) {
    switch (event.kind) {
      case MouseKind.wheelUp:
        _move(-1);
      case MouseKind.wheelDown:
        _move(1);
      case MouseKind.press when _horizontal:
        for (final (i, (s, e)) in _tabs.indexed) {
          if (x >= s && x < e) index = i;
        }
      case MouseKind.press:
        if (y < _rows.length) index = _shown[_rows[y]];
      default:
    }
  }
}

/// The filter's match in [label]: a substring, else a subsequence, as ranges; `null` for none.
List<(int, int)>? _match(String label, String query) {
  if (query.isEmpty) return const [];
  final at = label.indexOf(query);
  if (at >= 0) return [(at, at + query.length)];
  final ranges = <(int, int)>[];
  var q = 0;
  for (var i = 0; i < label.length && q < query.length; i++) {
    if (label[i] != query[q]) continue;
    q++;
    if (ranges.isNotEmpty && ranges.last.$2 == i) {
      ranges.last = (ranges.last.$1, i + 1);
    } else {
      ranges.add((i, i + 1));
    }
  }
  return q == query.length ? ranges : null;
}

/// What a [Menu] or [Tabs] item builder is given.
///
/// {@category CLI}
final class ItemContext<T> {
  /// Its index in the full list.
  final int index;
  final T value;

  /// Its text: what the filter matched against.
  final String label;

  /// Whether the cursor is on it.
  final bool selected;

  /// Whether it is checked, in a `multi` [Choice].
  final bool checked;

  /// Whether the list has the focus.
  final bool focused;

  /// Where the filter matched [label], as `[start, end)` ranges.
  final List<(int, int)> matches;
  final TuiTheme theme;

  const ItemContext._(
    this.index,
    this.value,
    this.label,
    this.selected,
    this.checked,
    this.focused,
    this.matches,
    this.theme,
  );

  /// [label] as spans, the matched ranges in the theme's accent.
  List<Span> get highlighted {
    if (matches.isEmpty) return [Span(label)];
    final out = <Span>[];
    var at = 0;
    for (final (s, e) in matches) {
      if (s > at) out.add(Span(label.substring(at, s)));
      out.add(Span(label.substring(s, e), theme.accent + const Style(bold: true)));
      at = e;
    }
    if (at < label.length) out.add(Span(label.substring(at)));
    return out;
  }
}

/// A scrolling, selectable list of [items]: arrows, Home/End, PgUp/PgDn, the wheel and clicks
/// move [choice]; it filters and checks as [choice] says.
///
/// [label] names an item (default `toString`, an enum's `name`); [item] replaces the whole row.
///
/// ```dart
/// Menu(servers, pick, label: (s) => s.host)
/// Menu(files, pick, item: (c) => Label('${c.checked ? '[x]' : '[ ]'} ${c.label}', style: c.selected ? c.theme.selected : null))
/// ```
///
/// {@category CLI}
final class Menu<T> extends Widget {
  final List<T> items;
  final Choice choice;
  final String Function(T item)? label;
  final Widget Function(ItemContext<T> item)? item;

  /// Shown when the filter matches nothing.
  final String empty;
  final bool scrollbar;

  const Menu(this.items, this.choice, {this.label, this.item, this.empty = 'No matches', this.scrollbar = true});

  String _label(int i) => label?.call(items[i]) ?? _name(items[i]);

  @override
  int get width {
    var w = 0;
    for (var i = 0; i < items.length; i++) {
      final lw = Io.width(_label(i));
      if (lw > w) w = lw;
    }
    return w + (choice.multi ? 4 : 2) + (scrollbar ? 1 : 0);
  }

  @override
  int heightAt(int width) => items.isEmpty ? 1 : items.length;

  ItemContext<T> _context(int i, bool focused, TuiTheme theme) {
    final l = _label(i);
    return ItemContext._(
      i,
      items[i],
      l,
      i == choice.index,
      choice.checked.contains(i),
      focused,
      _match(l.toLowerCase(), choice.query.toLowerCase()) ?? const [],
      theme,
    );
  }

  Widget _row(ItemContext<T> c) {
    final t = c.theme;
    return Label.spans(
      [
        Span(c.selected ? '${t.pointer} ' : '  ', t.accent),
        if (choice.multi) Span('${c.checked ? t.checked : t.unchecked} ', c.checked ? t.accent : t.muted),
        ...c.highlighted,
      ],
      style: c.selected && c.focused ? t.selected : null,
      wrap: false,
    );
  }

  @override
  void paint(Canvas canvas) {
    choice._settle(items.length, _label);
    final focused = canvas._focus(choice);
    final shown = choice._shown;
    if (shown.isEmpty) {
      canvas.text(2, 0, empty, canvas.theme.muted);
      return;
    }
    _list(canvas, choice, shown.length, scrollbar, (n, w) {
      final c = _context(shown[n], focused, canvas.theme);
      return (item ?? _row)(c);
    });
  }
}

/// Paints [count] rows built by [row] with [choice]'s cursor kept in view, and a scrollbar.
void _list(Canvas canvas, Choice choice, int count, bool scrollbar, Widget Function(int n, int width) row) {
  final pos = choice._pos.clamp(0, count - 1);
  final bar = scrollbar && count > canvas.height ? 1 : 0;
  final w = canvas.width - bar;
  if (pos < choice._offset) choice._offset = pos;
  // Rows can be taller than one line: walk back from the cursor until the screen is full.
  var used = 0, first = pos;
  for (var n = pos; n >= 0; n--) {
    used += row(n, w).heightAt(w);
    if (used > canvas.height) break;
    first = n;
  }
  if (choice._offset < first) choice._offset = first;
  if (choice._offset > count - 1) choice._offset = count - 1;
  var y = 0;
  var n = choice._offset;
  final rows = <int>[];
  for (; n < count && y < canvas.height; n++) {
    final r = row(n, w);
    final h = r.heightAt(w);
    canvas.area(0, y, w, h).draw(r);
    y += h;
    rows.addAll(List.filled(h, n));
  }
  choice._rows = rows;
  choice._page = (n - choice._offset).clamp(1, count);
  if (bar == 1) {
    final t = canvas.theme;
    final thumb = (canvas.height * canvas.height / count).ceil().clamp(1, canvas.height);
    final top = ((canvas.height - thumb) * choice._offset / (count - choice._page).clamp(1, count)).round();
    for (var y = 0; y < canvas.height; y++) {
      final on = y >= top && y < top + thumb;
      canvas.text(canvas.width - 1, y, on ? t.scrollThumb : t.scrollTrack, on ? t.text : t.muted);
    }
  }
}

String _name(Object? v) => v is Enum ? v.name : '$v';

/// What a [Grid] cell or header builder is given.
///
/// {@category CLI}
final class CellContext {
  /// The row in [Grid.rows], or `-1` for the header.
  final int row;
  final int column;
  final Object? value;

  /// Whether the cursor is on this row.
  final bool selected;
  final bool focused;
  final TuiTheme theme;

  const CellContext._(this.row, this.column, this.value, this.selected, this.focused, this.theme);
}

/// A table: [columns] names the header, [rows] the cells; with a [choice] it is selectable and scrolls.
///
/// Column widths fit the content unless [widths] says; a `0` in it takes what is left.
///
/// ```dart
/// Grid([for (final f in files) [f.name, f.size.humanBytes]], columns: ['Name', 'Size'], choice: pick)
/// ```
///
/// {@category CLI}
final class Grid extends Widget {
  final List<List<Object?>> rows;
  final List<String>? columns;
  final List<int>? widths;
  final Choice? choice;
  final Widget Function(CellContext cell)? cell;
  final Widget Function(CellContext cell)? header;
  final int gap;
  final bool scrollbar;

  const Grid(
    this.rows, {
    this.columns,
    this.widths,
    this.choice,
    this.cell,
    this.header,
    this.gap = 2,
    this.scrollbar = true,
  });

  int get _count => _max([columns?.length ?? 0, for (final r in rows) r.length]);

  List<int> _natural() {
    const t = TuiTheme();
    int w(int row, int col, Object? v, Widget Function(CellContext)? build) =>
        build == null ? Io.width(_name(v ?? '')) : build(CellContext._(row, col, v, false, false, t)).width;
    return [
      for (var c = 0; c < _count; c++)
        _max([
          if (columns != null && c < columns!.length) w(-1, c, columns![c], header),
          for (final (i, r) in rows.indexed)
            if (c < r.length) w(i, c, r[c], cell),
        ]),
    ];
  }

  List<int> _widths(int width) {
    final n = _count;
    final avail = width - gap * (n - 1).clamp(0, n) - (choice != null ? 2 : 0);
    final ws = List.of(widths ?? _natural());
    while (ws.length < n) {
      ws.add(0);
    }
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
  int heightAt(int width) => rows.length + (columns != null ? 1 : 0);

  Widget _line(List<int> ws, int row, bool selected, bool focused, TuiTheme t) {
    final values = row < 0 ? columns! : rows[row];
    return Paint((c) {
      if (selected && focused) c.fill(t.selected);
      var x = choice != null ? 2 : 0;
      if (selected) c.text(0, 0, '${t.pointer} ', t.accent);
      for (var col = 0; col < ws.length; col++) {
        final ctx = CellContext._(row, col, col < values.length ? values[col] : null, selected, focused, t);
        final build = row < 0 ? header : cell;
        final area = c.area(x, 0, ws[col], 1);
        if (build != null) {
          area.draw(build(ctx));
        } else {
          area.text(0, 0, _fit(_name(ctx.value ?? ''), ws[col]), row < 0 ? t.accent + const Style(bold: true) : t.text);
        }
        x += ws[col] + gap;
      }
    });
  }

  @override
  void paint(Canvas canvas) {
    final t = canvas.theme;
    final body = columns == null ? canvas : canvas.area(0, 1);
    final focused = choice != null && body._focus(choice!);
    final bar = scrollbar && rows.length > body.height ? 1 : 0;
    final ws = _widths(canvas.width - bar);
    if (columns != null) canvas.area(0, 0, canvas.width - bar, 1).draw(_line(ws, -1, false, focused, t));
    final pick = choice ?? Choice();
    if (choice != null) pick._settle(rows.length, (i) => rows[i].map(_name).join(' '));
    if (choice == null) pick._shown = [for (var i = 0; i < rows.length; i++) i];
    final shown = pick._shown;
    if (shown.isEmpty) return;
    _list(
      body,
      pick,
      shown.length,
      scrollbar,
      (n, w) => _line(ws, shown[n], choice != null && shown[n] == pick.index, focused, t),
    );
  }
}

/// A row of tabs; [choice] picks one (Left/Right while it has the focus, or a click).
///
/// ```dart
/// VStack([Tabs(['Logs', 'Stats'], tab), [logs, stats][tab.index].flex()])
/// ```
///
/// {@category CLI}
final class Tabs extends Widget {
  final List<String> titles;
  final Choice choice;
  final Widget Function(ItemContext<String> tab)? tab;
  final String divider;

  const Tabs(this.titles, this.choice, {this.tab, this.divider = '│'});

  @override
  int get width => _sum(titles.map((t) => Io.width(t) + 2)) + (titles.length - 1).clamp(0, titles.length);

  @override
  void paint(Canvas canvas) {
    choice
      .._horizontal = true
      .._settle(titles.length, (i) => titles[i]);
    final focused = canvas._focus(choice);
    final t = canvas.theme;
    var x = 0;
    final spans = <(int, int)>[];
    for (final (i, title) in titles.indexed) {
      if (i > 0) x = canvas.text(x, 0, divider, t.muted);
      final c = ItemContext<String>._(i, title, title, i == choice.index, false, focused, const [], t);
      final start = x;
      if (tab != null) {
        final w = tab!(c);
        final tw = w.width;
        canvas.area(x, 0, tw, 1).draw(w);
        x += tw;
      } else {
        x = canvas.text(x, 0, ' $title ', c.selected ? t.accent + const Style(bold: true, underline: true) : t.muted);
      }
      spans.add((start, x));
    }
    choice._tabs = spans;
  }
}
