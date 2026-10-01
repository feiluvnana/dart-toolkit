part of '../../tui.dart';

/// Columns a code point takes: ASCII inline, the rest as [Io.width] measures.
int _cellWidth(int rune) => rune >= 0x20 && rune < 0x7f ? 1 : Io.width(String.fromCharCode(rune));

/// [text] as cells: each grapheme (a code point and the zero-width ones joining it) with its width.
Iterable<(String, int)> _graphemes(String text) sync* {
  final runes = text.runes.toList();
  var i = 0;
  while (i < runes.length) {
    final start = i;
    final w = _cellWidth(runes[i]);
    i++;
    while (i < runes.length && (_cellWidth(runes[i]) == 0 || runes[i - 1] == 0x200d)) {
      i++;
    }
    yield (String.fromCharCodes(runes, start, i), w);
  }
}

/// The screen as cells: a grapheme and a style each; `''` is the right half of a wide one.
final class _Buffer {
  final int width, height;
  final List<String> chars;
  final List<Style> styles;

  _Buffer(this.width, this.height)
    : chars = List.filled(width * height, ' '),
      styles = List.filled(width * height, Style.none);

  /// Row [y] as text with SGR at [depth] colours (0: attributes only, -1: none), trailing blanks dropped.
  String row(int y, int depth) {
    var end = (y + 1) * width;
    while (end > y * width && chars[end - 1] == ' ' && (depth < 0 || _isBlank(styles[end - 1]))) {
      end--;
    }
    final out = StringBuffer();
    var current = Style.none;
    for (var i = y * width; i < end; i++) {
      if (chars[i].isEmpty) continue;
      final s = styles[i];
      if (depth >= 0 && s != current) {
        out.write(s == Style.none ? '\x1b[0m' : s._sgr(depth));
        current = s;
      }
      out.write(chars[i]);
    }
    if (current != Style.none) out.write('\x1b[0m');
    return '$out';
  }

  static bool _isBlank(Style s) => s.bg == null && s.reverse != true && s.underline != true;
}

/// What one frame learnt while painting: who can take the focus, where they are, whether to animate.
final class _Frame {
  /// Whether this frame is an app's: a one-off [Widget.render] gives nothing the focus.
  final bool live;
  final _Control? focused;
  final List<(_Control, int, int, int, int)> controls = [];
  final Duration elapsed;
  Duration? animate;
  bool focusPainted = false;

  _Frame(this.focused, this.elapsed, {this.live = true});
}

/// A rectangle of the screen to paint on, in its own coordinates; writes outside it are clipped.
///
/// What a [Paint] widget gets, and what every built-in widget paints with:
///
/// ```dart
/// Paint((c) => c..fill(Style(bg: Color.blue))..text(1, 0, 'hi', c.theme.accent), height: 1)
/// ```
///
/// {@category CLI}
final class Canvas {
  final _Buffer _buf;
  final int _x, _y;
  final int width, height;

  /// The theme in force here: the app's, as overridden by enclosing [Themed] widgets.
  final TuiTheme theme;
  final _Frame _frame;

  Canvas._(this._buf, this._x, this._y, this.width, this.height, this.theme, this._frame);

  /// The part of this canvas at [x], [y], [w] wide and [h] tall, clipped to it.
  Canvas area(int x, int y, [int? w, int? h]) {
    final cx = x.clamp(0, width), cy = y.clamp(0, height);
    final cw = (w ?? width - x).clamp(0, width - cx), ch = (h ?? height - y).clamp(0, height - cy);
    return Canvas._(_buf, _x + cx, _y + cy, cw, ch, theme, _frame);
  }

  /// Writes [text] at [x], [y] in [style] laid over what is there; returns the column after it.
  int text(int x, int y, String text, [Style style = Style.none]) {
    if (y < 0 || y >= height) return x;
    for (final (g, w) in _graphemes(text)) {
      if (g == '\n') break;
      x = _put(x, y, g, w, style);
      if (x >= width) break;
    }
    return x;
  }

  /// [text] for each span, one after another.
  int spans(int x, int y, List<Span> spans, [Style style = Style.none]) {
    for (final s in spans) {
      x = text(x, y, s.text, style + s.style);
    }
    return x;
  }

  int _put(int x, int y, String g, int w, Style style) {
    if (w == 0) return x;
    if (x < 0 || x + w > width) {
      if (x >= 0 && x < width) _set(x, y, ' ', style);
      return x + w;
    }
    _set(x, y, g, style);
    if (w == 2) _set(x + 1, y, '', style);
    return x + w;
  }

  void _set(int x, int y, String g, Style style) {
    final col = _x + x, i = (_y + y) * _buf.width + col, c = _buf.chars;
    // Writing over either half of a wide character blanks the other half.
    if (g.isNotEmpty && c[i].isEmpty && col > 0) c[i - 1] = ' ';
    if (col + 1 < _buf.width && c[i + 1].isEmpty) c[i + 1] = ' ';
    c[i] = g;
    _buf.styles[i] = _buf.styles[i] + style;
  }

  /// Fills the canvas with [char] in [style] — a background, a rule, a blank.
  void fill([Style style = Style.none, String char = ' ']) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (_y + y) * _buf.width + _x + x;
        _buf.chars[i] = char;
        _buf.styles[i] = style;
      }
    }
  }

  /// Draws a border round the edge, [title] in its top edge, and returns the canvas inside it.
  Canvas box({Border? border, Style? style, String? title}) {
    final b = border ?? theme.border;
    final s = style ?? theme.borderStyle;
    if (b.side.isEmpty) {
      if (title != null) text(0, 0, title, s + const Style(bold: true));
      return area(0, title == null ? 0 : 1);
    }
    if (width < 2 || height < 2) return area(0, 0, 0, 0);
    text(0, 0, b.topLeft + b.top * (width - 2) + b.topRight, s);
    for (var y = 1; y < height - 1; y++) {
      text(0, y, b.side, s);
      text(width - 1, y, b.side, s);
    }
    text(0, height - 1, b.bottomLeft + b.top * (width - 2) + b.bottomRight, s);
    if (title != null && width > 4) text(2, 0, ' ${_fit(title, width - 6)} ', s + const Style(bold: true));
    return area(1, 1, width - 2, height - 2);
  }

  /// Paints [widget] on this canvas.
  void draw(Widget widget) {
    if (width > 0 && height > 0) widget.paint(this);
  }

  /// Registers [control] for the focus and the mouse; returns whether it has the focus.
  bool _focus(_Control control) {
    _frame.controls.add((control, _x, _y, width, height));
    final has =
        _frame.live && (identical(_frame.focused, control) || (_frame.focused == null && _frame.controls.length == 1));
    if (has) _frame.focusPainted = true;
    return has;
  }

  /// Asks for another frame in [every]: what an animation calls each time it paints.
  void _animate(Duration every) {
    final a = _frame.animate;
    if (a == null || every < a) _frame.animate = every;
  }
}

int _sum(Iterable<int> xs) {
  var t = 0;
  for (final x in xs) {
    t += x;
  }
  return t;
}

int _max(Iterable<int> xs) {
  var m = 0;
  for (final x in xs) {
    if (x > m) m = x;
  }
  return m;
}

/// [text] cut to [width] columns, ending in `…` when cut.
String _fit(String text, int width) {
  if (width <= 0) return '';
  if (Io.width(text) <= width) return text;
  final out = StringBuffer();
  var w = 0;
  for (final (g, cw) in _graphemes(text)) {
    if (w + cw > width - 1) break;
    out.write(g);
    w += cw;
  }
  return '$out…';
}
