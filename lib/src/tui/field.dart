part of '../../tui.dart';

/// What a [Field]'s `render` builder is given.
///
/// {@category CLI}
final class FieldContext {
  /// The text as shown: masked with a `mask`.
  final String shown;

  /// The cursor, in characters of [shown].
  final int cursor;
  final bool focused;

  /// What `validate` said, or `null`.
  final String? error;
  final Field field;
  final TuiTheme theme;

  const FieldContext._(this.shown, this.cursor, this.focused, this.error, this.field, this.theme);
}

/// A one-line text input, and the widget that shows it: hold it across frames.
///
/// Editing is readline's: arrows, Home/End (^A/^E), Alt/Ctrl+arrows by word, ^W and Alt+Backspace
/// delete a word, ^U/^K to the start/end, Up/Down walk [history]. Enter, Esc and Tab reach `update`.
///
/// ```dart
/// final name = Field(prompt: 'Name: ', placeholder: 'your name', validate: (v) => v.isEmpty ? 'required' : null);
/// … VStack([name, …]) …
/// Key.enter when name.isValid => Tui.quit(name.text),
/// ```
///
/// {@category CLI}
final class Field extends Widget implements _Control {
  final String prompt;
  final String placeholder;

  /// Shown for each character instead of it: `'•'` for a password.
  final String? mask;

  /// An error message for the text, or `null` when it is acceptable; shown under the input.
  final String? Function(String text)? validate;

  /// Replaces how the input is drawn.
  final Widget Function(FieldContext field)? builder;
  final Style? style;

  /// Earlier entries, oldest first: Up and Down recall them.
  final List<String> history;

  List<String> _chars;
  int _cursor;
  int _scroll = 0;
  int _recall = -1;

  Field({
    String text = '',
    this.prompt = '',
    this.placeholder = '',
    this.mask,
    this.validate,
    this.builder,
    this.style,
    List<String>? history,
  }) : history = history ?? [],
       _chars = [for (final (g, _) in _graphemes(text)) g],
       _cursor = 0 {
    _cursor = _chars.length;
  }

  String get text => _chars.join();

  /// Replaces the text, the cursor at its end.
  set text(String value) {
    _chars = [for (final (g, _) in _graphemes(value)) g];
    _cursor = _chars.length;
  }

  /// The cursor, in characters.
  int get cursor => _cursor;
  set cursor(int value) => _cursor = value.clamp(0, _chars.length);

  /// What [validate] says of the text now.
  String? get error => validate?.call(text);

  bool get isValid => error == null;

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
    final gs = [for (final (g, _) in _graphemes(s.replaceAll('\n', ' '))) g];
    _chars.insertAll(_cursor, gs);
    _cursor += gs.length;
  }

  void _cut(int from, int to) {
    if (from < to) _chars.removeRange(from, to);
    _cursor = from;
  }

  @override
  bool _handle(Object event) {
    switch (event) {
      case Char(:final char, alt: false):
        _insert(char);
      case Paste(:final text):
        _insert(text);
      case Key.left || const Key('b', ctrl: true):
        cursor = _cursor - 1;
      case Key.right || const Key('f', ctrl: true):
        cursor = _cursor + 1;
      case Key(name: 'left', ctrl: true) || Key(name: 'left', alt: true) || Char(char: 'b', alt: true):
        _cursor = _wordLeft();
      case Key(name: 'right', ctrl: true) || Key(name: 'right', alt: true) || Char(char: 'f', alt: true):
        _cursor = _wordRight();
      case Key.home || const Key('a', ctrl: true):
        _cursor = 0;
      case Key.end || const Key('e', ctrl: true):
        _cursor = _chars.length;
      case Key.backspace || const Key('h', ctrl: true):
        if (_cursor > 0) _cut(_cursor - 1, _cursor);
      case Key.delete || const Key('d', ctrl: true):
        if (_cursor < _chars.length) _chars.removeAt(_cursor);
      case const Key('w', ctrl: true) || const Key('backspace', alt: true):
        _cut(_wordLeft(), _cursor);
      case Char(char: 'd', alt: true) || Key(name: 'delete', ctrl: true):
        _chars.removeRange(_cursor, _wordRight());
      case const Key('u', ctrl: true):
        _cut(0, _cursor);
      case const Key('k', ctrl: true):
        _chars.removeRange(_cursor, _chars.length);
      case Key.up when history.isNotEmpty:
        _recall = _recall < 0 ? history.length - 1 : (_recall - 1).clamp(0, history.length - 1);
        text = history[_recall];
      case Key.down when _recall >= 0:
        _recall++;
        text = _recall < history.length ? history[_recall] : '';
        if (_recall >= history.length) _recall = -1;
      default:
        return false;
    }
    return true;
  }

  @override
  void _mouse(Mouse event, int x, int y) {
    if (event.kind != MouseKind.press) return;
    var col = Io.width(prompt) - _scroll;
    for (var i = 0; i < _chars.length; i++) {
      if (col >= x) {
        cursor = i;
        return;
      }
      col += mask == null ? _cellWidth(_chars[i].runes.first) : Io.width(mask!);
    }
    _cursor = _chars.length;
  }

  @override
  int get width => Io.width(prompt) + _max([Io.width(placeholder), Io.width(text) + 1]);

  @override
  int heightAt(int width) => error != null && _chars.isNotEmpty ? 2 : 1;

  @override
  void paint(Canvas canvas) {
    final focused = canvas._focus(this);
    final t = canvas.theme;
    final shown = mask == null ? _chars : List.filled(_chars.length, mask!);
    final err = _chars.isEmpty ? null : error;
    if (builder != null) return canvas.draw(builder!(FieldContext._(shown.join(), _cursor, focused, err, this, t)));
    final base = t.text + style;
    final x = canvas.text(0, 0, prompt, t.accent);
    final room = canvas.width - x - 1;
    if (_chars.isEmpty) {
      canvas.text(x, 0, placeholder, t.muted);
      final first = placeholder.isEmpty ? ' ' : String.fromCharCode(placeholder.runes.first);
      if (focused) canvas.text(x, 0, first, t.selected);
    } else {
      // Scroll so the cursor stays in view.
      var before = 0;
      for (var i = 0; i < _cursor; i++) {
        before += Io.width(shown[i]);
      }
      if (before - _scroll > room) _scroll = before - room;
      if (before < _scroll) _scroll = before;
      var col = 0;
      for (var i = 0; i <= shown.length; i++) {
        final g = i < shown.length ? shown[i] : ' ';
        final w = Io.width(g);
        if (col >= _scroll && col + w - _scroll <= room + 1) {
          canvas.text(x + col - _scroll, 0, g, focused && i == _cursor ? base + t.selected : base);
        }
        col += w;
      }
    }
    if (err != null) canvas.text(0, 1, err, t.error);
  }
}
