part of '../../tui.dart';

bool _isControl(int rune) => rune < 0x20 || (rune >= 0x7f && rune < 0xa0);

/// [text] as cells: each grapheme (a code point and the zero-width ones joining it) with its width.
Iterable<(String, int)> _graphemes(String text) sync* {
  final runes = text.runes.toList();
  var i = 0;
  while (i < runes.length) {
    final start = i;
    final w = IoBridge.runeWidth(runes[i]);
    i++;
    // A control (`\n`, `\t`, ESC) is its own grapheme: it never joins the one before it.
    if (!_isControl(runes[start])) {
      while (i < runes.length &&
          !_isControl(runes[i]) &&
          (IoBridge.runeWidth(runes[i]) == 0 || runes[i - 1] == 0x200d)) {
        i++;
      }
    }
    yield (String.fromCharCodes(runes, start, i), w);
  }
}

/// The screen as cells: a grapheme, a style and a link each; `''` is the right half of a wide one.
final class _Buffer {
  final int width, height;
  final List<String> chars;
  final List<Style> styles;
  final List<String?> links;

  _Buffer(this.width, this.height)
    : chars = List.filled(width * height, ' '),
      styles = List.filled(width * height, Style.none),
      links = List.filled(width * height, null);

  /// Row [y] as text with SGR at [depth] colours (0: attributes only, -1: none), trailing blanks dropped.
  String row(int y, int depth) {
    var end = (y + 1) * width;
    while (end > y * width &&
        chars[end - 1] == ' ' &&
        links[end - 1] == null &&
        (depth < 0 || _isBlank(styles[end - 1]))) {
      end--;
    }
    final out = StringBuffer();
    var current = Style.none;
    String? link;
    for (var i = y * width; i < end; i++) {
      if (chars[i].isEmpty) continue;
      final s = styles[i];
      if (depth >= 0 && s != current) {
        out.write(s == Style.none ? '\x1b[0m' : TerminalBridge.sgrOf(s, depth));
        current = s;
      }
      if (depth >= 0 && links[i] != link) out.write(_osc8(link = links[i]));
      out.write(chars[i]);
    }
    if (link != null) out.write(_osc8(null));
    if (current != Style.none) out.write('\x1b[0m');
    return '$out';
  }

  static bool _isBlank(Style s) => s.bg == null && s.reverse != true && s.underline != true;
}

/// The escape that opens a hyperlink to [url], or closes one (`null`).
String _osc8(String? url) => '\x1b]8;;${url ?? ''}\x1b\\';

/// Something on screen the pointer or the keys can reach: a [Focusable], something clickable,
/// or both.
final class _Target {
  final Focusable? control;
  final Object? message;
  final bool clickable;
  final int x, y, w, h;

  const _Target(this.control, this.message, this.clickable, this.x, this.y, this.w, this.h);

  bool contains(int px, int py) => px >= x && px < x + w && py >= y && py < y + h;
}

/// A popup to draw above the rest, and where.
final class _Layer {
  final Widget content;

  /// The anchor's rectangle on screen, or `null` for the middle of the screen.
  final (int, int, int, int)? anchor;

  /// What a click outside it sends, when it has one.
  final Object? dismiss;
  final bool dismissible, modal;

  const _Layer(this.content, this.anchor, this.dismiss, {required this.dismissible, required this.modal});
}

/// What one frame learnt while painting: what the focus and the pointer can reach and where,
/// popups to draw above, tallies drawn, whether to animate.
final class _Frame {
  /// Whether this frame is an app's: a one-off [Widget.render] gives nothing the focus.
  final bool live;
  final Focusable? focused;
  final Duration elapsed;

  /// Where the pointer is, and where a button went down while it is held, on screen.
  final (int, int)? pointer, pressed;
  final List<_Target> targets = [];
  final List<_Layer> popups = [];
  final Set<Tally> tallies = {};
  Duration? animate;
  bool focusPainted = false;

  /// Where a modal popup's targets start: those before it are out of reach.
  int? modalFrom;

  _Frame(this.focused, this.elapsed, {this.live = true, this.pointer, this.pressed});

  /// The targets the keys and the pointer can reach.
  Iterable<_Target> get reachable => modalFrom == null ? targets : targets.skip(modalFrom!);

  Iterable<Focusable> get focusables sync* {
    for (final t in reachable) {
      if (t.control case final c?) yield c;
    }
  }
}

/// A rectangle of the screen to paint on, in its own coordinates; writes outside it are clipped.
///
/// What a [Paint] widget gets, and what every built-in widget paints with:
///
/// ```dart
/// Paint((c) => c..fill(Style(bg: Color.blue))..text(1, 0, 'hi', c.palette.accent), height: 1)
/// ```
///
/// {@category CLI}
final class Canvas {
  final _Buffer _buf;
  final int _x, _y;
  final int width, height;

  /// The theme in force here: the app's, as overridden by enclosing [Widget.themed] subtrees.
  final TuiTheme theme;
  final _Frame _frame;

  Canvas._(this._buf, this._x, this._y, this.width, this.height, this.theme, this._frame);

  /// The theme's palette.
  Palette get palette => theme.palette;

  /// The part of this canvas at [x], [y], [w] wide and [h] tall, clipped to it.
  Canvas area(int x, int y, [int? w, int? h]) {
    final cx = x.clamp(0, width), cy = y.clamp(0, height);
    final cw = (w ?? width - x).clamp(0, width - cx), ch = (h ?? height - y).clamp(0, height - cy);
    return Canvas._(_buf, _x + cx, _y + cy, cw, ch, theme, _frame);
  }

  /// The part of this canvas [widget] takes at its own size: what a click on it reaches.
  Canvas _natural(Widget widget) {
    final w = widget.width;
    final cw = w > 0 && w < width ? w : width;
    final h = widget.heightAt(cw);
    return area(0, 0, cw, h > 0 && h < height ? h : height);
  }

  /// Whether the pointer is over this canvas (with `mouse: true`).
  bool get isHovered => switch (_frame.pointer) {
    (final px, final py) => _inside(px, py),
    null => false,
  };

  /// Whether a mouse button went down on this canvas and is still held over it.
  bool get isPressed => switch (_frame.pressed) {
    (final px, final py) => _inside(px, py) && isHovered,
    null => false,
  };

  bool _inside(int px, int py) => px >= _x && px < _x + width && py >= _y && py < _y + height;

  /// Writes [text] at [x], [y] in [style] laid over what is there, linking to [link] when given;
  /// returns the column after it. A styled string's own styles go over [style].
  int text(int x, int y, String text, [Style? style, Uri? link]) {
    final base = style ?? Style.none;
    if (y < 0 || y >= height) return x;
    if (text.contains('\x1b')) {
      for (final (t, s) in TerminalBridge.runs(text)) {
        x = this.text(x, y, t, base + s, link);
      }
      return x;
    }
    final url = link?.toString();
    for (final (g, w) in _graphemes(text)) {
      if (g == '\n') break;
      x = _put(x, y, g, w, base, url);
      if (x >= width) break;
    }
    return x;
  }

  /// [text] for each span, one after another.
  int spans(int x, int y, List<Span> spans, [Style? style]) {
    for (final s in spans) {
      x = text(x, y, s.text, (style ?? Style.none) + s.style, s.link);
    }
    return x;
  }

  int _put(int x, int y, String g, int w, Style style, [String? link]) {
    if (w == 0) return x;
    if (x < 0 || x + w > width) {
      if (x >= 0 && x < width) _set(x, y, ' ', style, link);
      return x + w;
    }
    _set(x, y, g, style, link);
    if (w == 2) _set(x + 1, y, '', style, link);
    return x + w;
  }

  void _set(int x, int y, String g, Style style, [String? link]) {
    final col = _x + x, i = (_y + y) * _buf.width + col, c = _buf.chars;
    // Writing over either half of a wide character blanks the other half.
    if (g.isNotEmpty && c[i].isEmpty && col > 0) c[i - 1] = ' ';
    if (col + 1 < _buf.width && c[i + 1].isEmpty) c[i + 1] = ' ';
    c[i] = g;
    _buf.styles[i] = _buf.styles[i] + style;
    _buf.links[i] = link;
  }

  /// Fills the canvas with [char] in [style]: a background, a rule, a blank.
  void fill([Style style = Style.none, String char = ' ']) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (_y + y) * _buf.width + _x + x;
        _buf.chars[i] = char;
        _buf.styles[i] = style;
        _buf.links[i] = null;
      }
    }
  }

  /// Lays [style] over every cell of the canvas, keeping what is drawn: a hover, a highlight.
  void tint(Style style) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (_y + y) * _buf.width + _x + x;
        _buf.styles[i] = _buf.styles[i] + style;
      }
    }
  }

  /// Draws a border round the edge, [title] in its top edge, and returns the canvas inside it.
  Canvas _box({Border? border, Style? style, String? title}) {
    final b = border ?? palette.border;
    final s = style ?? palette.borderStyle;
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
    if (title != null && width > 4) {
      text(2, 0, ' ${Style.truncate(title, width - 6, ellipsis: palette.ellipsis)} ', s + const Style(bold: true));
    }
    return area(1, 1, width - 2, height - 2);
  }

  /// Copies [from]'s rows from [top] on into this canvas, as many as fit.
  void _blit(_Buffer from, int top) {
    final w = width < from.width ? width : from.width;
    for (var y = 0; y < height && top + y < from.height; y++) {
      final src = (top + y) * from.width, dst = (_y + y) * _buf.width + _x;
      for (var x = 0; x < w; x++) {
        _buf.chars[dst + x] = from.chars[src + x];
        _buf.styles[dst + x] = from.styles[src + x];
        _buf.links[dst + x] = from.links[src + x];
      }
    }
  }

  /// Paints [widget] on this canvas.
  void draw(Widget widget) {
    // A popup at a position or in the middle takes no room, and still draws.
    if ((width > 0 && height > 0) || widget is Popup) widget.paint(this);
  }

  /// Registers [control] for the keys and the pointer over this canvas; returns whether it has
  /// the focus. A [Focusable] widget calls it when it paints.
  bool focus(Focusable control) => _register(control, null, false);

  /// Makes this canvas send [message] to the app when clicked.
  void _clickable(Object? message, [Focusable? control]) => _register(control, message, true);

  bool _register(Focusable? control, Object? message, bool clickable) {
    _frame.targets.add(_Target(control, message, clickable, _x, _y, width, height));
    if (control == null) return false;
    final first = _frame.focusables.firstOrNull;
    final has =
        _frame.live && (identical(_frame.focused, control) || (_frame.focused == null && identical(first, control)));
    if (has) _frame.focusPainted = true;
    return has;
  }

  /// Asks for another frame in [every]: what an animation calls each time it paints.
  void animate(Duration every) {
    if (every <= Duration.zero) throw ArgumentError.value(every, 'every', 'Invalid interval, expected more than zero');
    final a = _frame.animate;
    if (a == null || every < a) _frame.animate = every;
  }

  /// Redraws when [tally] changes, while it is drawn.
  void _watch(Tally tally) => _frame.tallies.add(tally);

  /// Draws [content] above everything once the frame is painted, below or above this canvas.
  void _popup(Widget content, {Object? dismiss, bool dismissible = false, bool modal = false, bool center = false}) =>
      _frame.popups.add(
        _Layer(content, center ? null : (_x, _y, width, height), dismiss, dismissible: dismissible, modal: modal),
      );
}

int _sum(Iterable<int> xs) => xs.fold(0, (a, b) => a + b);

int _max(Iterable<int> xs) => xs.fold(0, (a, b) => a > b ? a : b);
