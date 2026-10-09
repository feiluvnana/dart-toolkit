part of '../../tui.dart';

/// A [Field] as its `field:` builder sees it.
///
/// {@category CLI}
final class FieldView {
  /// The text as shown: masked with a `mask`.
  final String shown;

  /// The cursor, in characters of [shown].
  final int cursor;
  final bool isFocused, isHovered;

  /// What `validate` said, or `null`.
  final String? error;
  final Field field;
  final Palette palette;

  const FieldView._(this.shown, this.cursor, this.isFocused, this.isHovered, this.error, this.field, this.palette);
}

/// A text input, and the widget that shows it: hold it across frames.
///
/// Editing is readline's: arrows, Home/End (^A/^E), Alt/Ctrl+arrows by word, ^W and Alt+Backspace
/// delete a word, ^U/^K to the start/end, Up/Down walk [history]. Enter and Esc reach `update`;
/// so do ^D on an empty input and Tab when nothing takes it.
///
/// With [lines] above 1 it grows to that many lines, wraps, and Shift+Enter (Alt+Enter where the
/// terminal cannot tell Shift+Enter apart) starts a new line while Enter still submits; Up and Down
/// move between lines. [suggest] offers completions for the text in a popup under it: Up/Down
/// choose, Tab or Enter take one, Esc hides them.
///
/// ```dart
/// final input = Field(prompt: '> ', lines: 5, suggest: (t) => [for (final c in commands) if (c.startsWith(t)) c]);
/// … VStack([log.flex(), input]) …
/// KeyPress.enter => (send(input.text), input.text = '').$1,
/// ```
///
/// {@category CLI}
final class Field extends Widget with Focusable {
  final String prompt;
  final String placeholder;

  /// Shown for each character instead of it: `'•'` for a password.
  final String? mask;

  /// An error message for the text, or `null` when it is acceptable; shown under the input.
  final String? Function(String text)? validate;

  /// Replaces how the input is drawn, in place of the theme's.
  final Widget Function(FieldView view)? field;

  /// Earlier entries, oldest first: Up and Down recall them.
  final List<String> history;

  /// The most lines it grows to.
  final int lines;

  /// Completions for the text, shown under it; none hides the popup.
  final List<String> Function(String text)? suggest;

  List<String> _chars;
  int _cursor;
  int _scroll = 0, _top = 0;
  int _recall = -1;

  /// The suggestions for [_suggestedFor], the one picked, and the text they were hidden for.
  List<String> _suggestions = const [];
  String? _suggestedFor, _hiddenFor;
  int _pick = 0;

  Field({
    String text = '',
    this.prompt = '',
    this.placeholder = '',
    this.mask,
    this.validate,
    this.field,
    List<String>? history,
    this.lines = 1,
    this.suggest,
  }) : history = history ?? [],
       _chars = [for (final (g, _) in _graphemes(text)) g],
       _cursor = 0 {
    if (lines < 1) throw ArgumentError.value(lines, 'lines', 'Invalid lines, expected at least 1');
    if (lines > 1 && mask != null) throw ArgumentError.value(mask, 'mask', 'Invalid mask: a masked field is one line');
    _cursor = _chars.length;
  }

  String get text => _chars.join();

  /// Replaces the text, the cursor at its end.
  set text(String value) {
    _chars = [for (final (g, _) in _graphemes(lines > 1 ? value : value.replaceAll('\n', ' '))) g];
    _cursor = _chars.length;
  }

  /// The cursor, in characters.
  int get cursor => _cursor;
  set cursor(int value) => _cursor = value.clamp(0, _chars.length);

  /// What [validate] says of the text now: `null` when it is acceptable.
  String? get error => validate?.call(text);

  /// The completions on show: none once hidden, or when the text is the only one.
  List<String> get suggestions {
    final suggest = this.suggest;
    if (suggest == null) return const [];
    final now = text;
    if (now == _hiddenFor) return const [];
    if (now != _suggestedFor) {
      _suggestedFor = now;
      final all = suggest(now);
      _suggestions = all.length == 1 && all.single == now ? const [] : List.unmodifiable(all);
      _pick = 0;
    }
    return _suggestions;
  }

  bool _isWord(int i) => _chars[i].trim().isNotEmpty;

  int _wordLeft() {
    var i = _cursor;
    while (i > 0 && !_isWord(i - 1)) {
      i--;
    }
    while (i > 0 && _isWord(i - 1)) {
      i--;
    }
    return i;
  }

  int _wordRight() {
    var i = _cursor;
    while (i < _chars.length && !_isWord(i)) {
      i++;
    }
    while (i < _chars.length && _isWord(i)) {
      i++;
    }
    return i;
  }

  void _insert(String s) {
    final gs = [for (final (g, _) in _graphemes(lines > 1 ? s.replaceAll('\r\n', '\n') : s.replaceAll('\n', ' '))) g];
    _chars.insertAll(_cursor, gs);
    _cursor += gs.length;
  }

  void _cut(int from, int to) {
    if (from < to) _chars.removeRange(from, to);
    _cursor = from;
  }

  /// Where each visual line starts, at [room] columns: lines break at a newline and wrap.
  List<int> _starts(int room) {
    final starts = [0];
    var w = 0;
    for (var i = 0; i < _chars.length; i++) {
      final g = _chars[i];
      if (g == '\n') {
        starts.add(i + 1);
        w = 0;
        continue;
      }
      final gw = Style.width(mask ?? g);
      if (w + gw > room && w > 0) {
        starts.add(i);
        w = 0;
      }
      w += gw;
    }
    return starts;
  }

  /// The visual line the cursor is on, and its column there.
  (int, int) _where(List<int> starts) {
    var line = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= _cursor) line = i;
    }
    var col = 0;
    for (var i = starts[line]; i < _cursor; i++) {
      col += Style.width(mask ?? _chars[i]);
    }
    return (line, col);
  }

  /// The columns the text gets beside the prompt, as last painted.
  int _room = 1 << 20;

  /// Moves the cursor [by] visual lines; `false` at the first or last.
  bool _lineMove(int by) {
    if (lines == 1) return false;
    final starts = _starts(_room);
    final (line, col) = _where(starts);
    final target = line + by;
    if (target < 0 || target >= starts.length) return false;
    final end = target + 1 < starts.length ? starts[target + 1] : _chars.length;
    var i = starts[target], w = 0;
    while (i < end && _chars[i] != '\n' && w + Style.width(_chars[i]) <= col) {
      w += Style.width(_chars[i]);
      i++;
    }
    _cursor = i;
    return true;
  }

  static const _newline = [KeyPress('enter', shift: true), KeyPress('enter', alt: true)];

  @override
  bool handle(TuiEvent<Object?> event) {
    final offered = suggestions;
    if (offered.isNotEmpty) {
      switch (event) {
        case KeyPress.tab || KeyPress.enter:
          text = offered[_pick];
          return true;
        case KeyPress.up:
          _pick = (_pick - 1).clamp(0, offered.length - 1);
          return true;
        case KeyPress.down:
          _pick = (_pick + 1).clamp(0, offered.length - 1);
          return true;
        case KeyPress.esc:
          _hiddenFor = text;
          return true;
        case _:
      }
    }
    switch (event) {
      case _ when lines > 1 && _newline.contains(event):
        _insert('\n');
      case Char(:final char, alt: false):
        _insert(char);
      case Paste(:final text):
        _insert(text);
      case KeyPress.left || const KeyPress('b', ctrl: true):
        cursor = _cursor - 1;
      case KeyPress.right || const KeyPress('f', ctrl: true):
        cursor = _cursor + 1;
      case KeyPress(name: 'left', ctrl: true) || KeyPress(name: 'left', alt: true) || Char(char: 'b', alt: true):
        _cursor = _wordLeft();
      case KeyPress(name: 'right', ctrl: true) || KeyPress(name: 'right', alt: true) || Char(char: 'f', alt: true):
        _cursor = _wordRight();
      case KeyPress.home || const KeyPress('a', ctrl: true):
        _cursor = 0;
      case KeyPress.end || const KeyPress('e', ctrl: true):
        _cursor = _chars.length;
      case KeyPress.backspace || const KeyPress('h', ctrl: true):
        if (_cursor > 0) _cut(_cursor - 1, _cursor);
      // ^D on an empty input is readline's end of input: it reaches `update`.
      case KeyPress.delete || const KeyPress('d', ctrl: true) when event == KeyPress.delete || _chars.isNotEmpty:
        if (_cursor < _chars.length) _chars.removeAt(_cursor);
      case const KeyPress('w', ctrl: true) || const KeyPress('backspace', alt: true):
        _cut(_wordLeft(), _cursor);
      case Char(char: 'd', alt: true) || KeyPress(name: 'delete', ctrl: true):
        _chars.removeRange(_cursor, _wordRight());
      case const KeyPress('u', ctrl: true):
        _cut(0, _cursor);
      case const KeyPress('k', ctrl: true):
        _chars.removeRange(_cursor, _chars.length);
      case KeyPress.up when _lineMove(-1):
        break;
      case KeyPress.down when _lineMove(1):
        break;
      case KeyPress.up when history.isNotEmpty:
        _recall = _recall < 0 ? history.length - 1 : (_recall - 1).clamp(0, history.length - 1);
        text = history[_recall];
      case KeyPress.down when _recall >= 0:
        _recall++;
        text = _recall < history.length ? history[_recall] : '';
        if (_recall >= history.length) _recall = -1;
      default:
        return false;
    }
    return true;
  }

  @override
  void mouse(Mouse event, int x, int y) {
    if (event.kind != MouseKind.press) return;
    final starts = _starts(_room);
    final line = (_top + y).clamp(0, starts.length - 1);
    var col = Style.width(prompt) - (lines == 1 ? _scroll : 0);
    final end = line + 1 < starts.length ? starts[line + 1] : _chars.length;
    for (var i = starts[line]; i < end; i++) {
      if (col >= x || _chars[i] == '\n') {
        cursor = i;
        return;
      }
      col += Style.width(mask ?? _chars[i]);
    }
    _cursor = end;
  }

  @override
  int get width => Style.width(prompt) + _max([Style.width(placeholder), Style.width(text) + 1]);

  @override
  int heightAt(int width) {
    final err = error != null && _chars.isNotEmpty ? 1 : 0;
    if (lines == 1) return 1 + err;
    final room = width - Style.width(prompt) - 1;
    return _starts(room < 1 ? 1 : room).length.clamp(1, lines) + err;
  }

  @override
  void paint(Canvas canvas) {
    final focused = canvas.focus(this);
    final shown = mask == null ? text : mask! * _chars.length;
    final err = _chars.isEmpty ? null : error;
    canvas.draw(
      (field ?? canvas.theme.field)(FieldView._(shown, _cursor, focused, canvas.isHovered, err, this, canvas.palette)),
    );
    final offered = focused ? suggestions : const <String>[];
    if (offered.isNotEmpty) canvas._popup(_Suggestions(offered, _pick));
  }

  /// The default look: [prompt], the text kept in view around the cursor, the error under it.
  void _draw(Canvas canvas, FieldView view) {
    final p = view.palette;
    final focused = view.isFocused;
    final x = canvas.text(0, 0, prompt, p.accent);
    final room = canvas.width - x - 1;
    _room = room < 1 ? 1 : room;
    final rows = canvas.height - (view.error == null ? 0 : 1);
    if (_chars.isEmpty) {
      canvas.text(x, 0, placeholder, p.muted);
      final first = placeholder.isEmpty ? ' ' : String.fromCharCode(placeholder.runes.first);
      if (focused) canvas.text(x, 0, first, p.selected);
    } else if (lines == 1) {
      final shown = mask == null ? _chars : List.filled(_chars.length, mask!);
      var before = 0;
      for (var i = 0; i < _cursor; i++) {
        before += Style.width(shown[i]);
      }
      if (before - _scroll > room) _scroll = before - room;
      if (before < _scroll) _scroll = before;
      var col = 0;
      for (var i = 0; i <= shown.length; i++) {
        final g = i < shown.length ? shown[i] : ' ';
        final w = Style.width(g);
        if (col >= _scroll && col + w - _scroll <= room + 1) {
          canvas._put(x + col - _scroll, 0, g, w, focused && i == _cursor ? p.text + p.selected : p.text);
        }
        col += w;
      }
    } else {
      final starts = _starts(_room);
      final (line, _) = _where(starts);
      if (line < _top) _top = line;
      if (line >= _top + rows) _top = line - rows + 1;
      for (var r = 0; r < rows && _top + r < starts.length; r++) {
        final from = starts[_top + r];
        final to = _top + r + 1 < starts.length ? starts[_top + r + 1] : _chars.length;
        var col = x;
        for (var i = from; i < to && _chars[i] != '\n'; i++) {
          final g = _chars[i];
          col = canvas._put(col, r, g, Style.width(g), focused && i == _cursor ? p.text + p.selected : p.text);
        }
        // The cursor past the line's last character: at the end of the text, or on its newline.
        final last = _top + r == starts.length - 1;
        final here =
            _cursor >= from && ((last && _cursor == _chars.length) || (_cursor < to && _chars[_cursor] == '\n'));
        if (focused && here) canvas._put(col, r, ' ', 1, p.text + p.selected);
      }
    }
    if (view.error case final err?) canvas.text(0, canvas.height - 1, err, p.danger);
  }
}

Widget _fieldLine(FieldView f) => Paint((c) => f.field._draw(c, f));

/// A [Field]'s completions, in a popup under it: the picked one selected.
final class _Suggestions extends Widget {
  final List<String> items;
  final int pick;

  const _Suggestions(this.items, this.pick);

  @override
  int get width => _max(items.map(Style.width)) + 2;

  @override
  int heightAt(int width) => items.length < 8 ? items.length : 8;

  @override
  void paint(Canvas canvas) {
    final p = canvas.palette;
    final first = pick < canvas.height ? 0 : pick - canvas.height + 1;
    for (var y = 0; y < canvas.height && first + y < items.length; y++) {
      final row = canvas.area(0, y, canvas.width, 1);
      final on = first + y == pick;
      row.fill(on ? p.selected : p.muted + const Style(reverse: true));
      row.text(1, 0, items[first + y]);
    }
  }
}
