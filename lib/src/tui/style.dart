part of '../../tui.dart';

/// A run of text in one [Style], maybe a hyperlink: what [Label.spans] and [Canvas.spans] take.
///
/// {@category CLI}
final class Span {
  final String text;
  final Style style;

  /// Where the text links to (OSC 8): a click opens it in a terminal that supports links.
  final Uri? link;

  const Span(this.text, [this.style = Style.none, this.link]);
}

/// How an app draws: a [Palette] of tokens (shared with `ConsoleTheme`) and a builder for each
/// built-in look, from the same views the console's builders get: [task] (a `Board` row),
/// [batch] (a `Board` header), [item] (a `Menu` row), [tab], [field], [cell], [log] and
/// [button]. A widget's own builder beats the theme's.
///
/// Unset parts inherit, so a [Widget.themed] subtree changes only what it names; each builder
/// getter answers the default when unset, so a builder can wrap it:
///
/// ```dart
/// await Tui.run(s, theme: const TuiTheme(palette: Palette(accent: Style(fg: Color.magenta))), draw: …, update: …);
/// TuiTheme(item: (i) => HStack([Label(i.isSelected ? '▶' : ' ').fixed(2), const TuiTheme().item(i)]))
/// ```
///
/// {@category CLI}
final class TuiTheme {
  final Palette? _palette;
  final Widget Function(TaskView view)? _task;
  final Widget Function(BatchView view)? _batch;
  final Widget Function(ItemView<Object?> view)? _item;
  final Widget Function(ItemView<String> view)? _tab;
  final Widget Function(FieldView view)? _field;
  final Widget Function(CellView view)? _cell;
  final Widget Function(LogView view)? _log;
  final Widget Function(ButtonView view)? _button;

  const TuiTheme({
    Palette? palette,
    Widget Function(TaskView view)? task,
    Widget Function(BatchView view)? batch,
    Widget Function(ItemView<Object?> view)? item,
    Widget Function(ItemView<String> view)? tab,
    Widget Function(FieldView view)? field,
    Widget Function(CellView view)? cell,
    Widget Function(LogView view)? log,
    Widget Function(ButtonView view)? button,
  }) : _palette = palette,
       _task = task,
       _batch = batch,
       _item = item,
       _tab = tab,
       _field = field,
       _cell = cell,
       _log = log,
       _button = button;

  /// The tokens: colours, marks, glyphs.
  Palette get palette => _palette ?? const Palette();

  /// A `Board` row, or a single task's line: `name  ██████░░░░  60%  1.2/2.0 MB`.
  Widget Function(TaskView view) get task => _task ?? _taskRow;

  /// A `Board` header: `⠋ Fetching  ████░░░░  3/8  1 failed`.
  Widget Function(BatchView view) get batch => _batch ?? _batchRow;

  /// A [Menu] row: the pointer, a check box when several are picked, the label with its matches.
  Widget Function(ItemView<Object?> view) get item => _item ?? _menuRow;

  /// A [Tabs] title: the selected one in the accent, bold and underlined.
  Widget Function(ItemView<String> view) get tab => _tab ?? _tabTitle;

  /// A [Field]: its prompt, the text with the cursor, the error under it.
  Widget Function(FieldView view) get field => _field ?? _fieldLine;

  /// A [Grid] cell, the header's included.
  Widget Function(CellView view) get cell => _cell ?? _gridCell;

  /// A warning or a failure under a `Board`'s rows.
  Widget Function(LogView view) get log => _log ?? _logRow;

  /// A [Button]: its label, in a style for each state.
  Widget Function(ButtonView view) get button => _button ?? _buttonFace;

  /// This theme with [base] filling what it leaves unset.
  TuiTheme _over(TuiTheme base) => TuiTheme(
    palette: switch ((_palette, base._palette)) {
      (final mine?, final theirs?) => TerminalBridge.over(mine, theirs),
      (final mine, final theirs) => mine ?? theirs,
    },
    task: _task ?? base._task,
    batch: _batch ?? base._batch,
    item: _item ?? base._item,
    tab: _tab ?? base._tab,
    field: _field ?? base._field,
    cell: _cell ?? base._cell,
    log: _log ?? base._log,
    button: _button ?? base._button,
  );

  /// This theme as a terminal that does or does not draw [unicode] draws it, checked.
  TuiTheme _drawable({required bool unicode}) {
    final palette = TerminalBridge.checked(TerminalBridge.drawable(this.palette, unicode: unicode));
    return TuiTheme(
      palette: palette,
      task: _task,
      batch: _batch,
      item: _item,
      tab: _tab,
      field: _field,
      cell: _cell,
      log: _log,
      button: _button,
    );
  }
}
