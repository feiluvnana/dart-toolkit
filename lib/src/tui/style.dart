part of '../../tui.dart';

/// A terminal colour: one of the sixteen named ones, a 256-palette index, or 24-bit RGB.
///
/// A terminal that cannot show it gets the nearest it can: RGB → 256 → 16 → none (`NO_COLOR`).
///
/// {@category CLI}
final class Color {
  /// 0: named (0–15), 1: palette (0–255), 2: RGB (0xRRGGBB).
  final int _kind;
  final int _value;

  const Color._(this._kind, this._value);

  /// Entry [index] of the 256-colour palette; 0–15 are the named colours.
  const Color(int index) : this._(index < 16 ? 0 : 1, index);

  /// A 24-bit colour.
  const Color.rgb(int r, int g, int b) : this._(2, (r & 255) << 16 | (g & 255) << 8 | (b & 255));

  /// `'#ff8800'` or `'ff8800'`.
  factory Color.hex(String hex) {
    final v = int.parse(hex.startsWith('#') ? hex.substring(1) : hex, radix: 16);
    return Color._(2, v & 0xffffff);
  }

  static const black = Color._(0, 0);
  static const red = Color._(0, 1);
  static const green = Color._(0, 2);
  static const yellow = Color._(0, 3);
  static const blue = Color._(0, 4);
  static const magenta = Color._(0, 5);
  static const cyan = Color._(0, 6);
  static const white = Color._(0, 7);
  static const gray = Color._(0, 8);
  static const brightRed = Color._(0, 9);
  static const brightGreen = Color._(0, 10);
  static const brightYellow = Color._(0, 11);
  static const brightBlue = Color._(0, 12);
  static const brightMagenta = Color._(0, 13);
  static const brightCyan = Color._(0, 14);
  static const brightWhite = Color._(0, 15);

  /// The SGR parameters for this colour as foreground (or background, [bg]) at [depth] colours.
  String _sgr(int depth, {bool bg = false}) {
    var (kind, v) = (_kind, _value);
    if (kind == 2 && depth < 1 << 24) (kind, v) = (1, _rgbTo256(v));
    if (kind == 1 && depth < 256) (kind, v) = (0, _paletteTo16(v));
    if (kind == 1 && v < 16) kind = 0;
    return switch (kind) {
      0 => '${(v < 8 ? 30 : 82) + v + (bg ? 10 : 0)}',
      1 => '${bg ? 48 : 38};5;$v',
      _ => '${bg ? 48 : 38};2;${v >> 16};${v >> 8 & 255};${v & 255}',
    };
  }

  static int _rgbTo256(int v) {
    final (r, g, b) = (v >> 16, v >> 8 & 255, v & 255);
    if (r == g && g == b) {
      if (r < 8) return 16;
      if (r > 248) return 231;
      return 232 + ((r - 8) * 24 / 247).round();
    }
    int c(int x) => x < 48 ? 0 : (x < 115 ? 1 : (x - 35) ~/ 40);
    return 16 + 36 * c(r) + 6 * c(g) + c(b);
  }

  static const _basic = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), //
    (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), //
    (255, 0, 255), (0, 255, 255), (255, 255, 255),
  ];

  static int _paletteTo16(int i) {
    if (i < 16) return i;
    final (r, g, b) = i >= 232
        ? (8 + (i - 232) * 10, 8 + (i - 232) * 10, 8 + (i - 232) * 10)
        : (_cube((i - 16) ~/ 36), _cube((i - 16) ~/ 6 % 6), _cube((i - 16) % 6));
    var best = 0, bestD = 1 << 30;
    for (final (n, (br, bg, bb)) in _basic.indexed) {
      final d = (r - br) * (r - br) + (g - bg) * (g - bg) + (b - bb) * (b - bb);
      if (d < bestD) (best, bestD) = (n, d);
    }
    return best;
  }

  static int _cube(int c) => c == 0 ? 0 : 55 + c * 40;

  @override
  bool operator ==(Object other) => other is Color && other._kind == _kind && other._value == _value;

  @override
  int get hashCode => _kind << 24 ^ _value;
}

/// How a cell looks. Unset fields inherit: `base + over` takes [over]'s set fields.
///
/// ```dart
/// const title = Style(fg: Color.cyan, bold: true);
/// Label('Ready', style: theme.success + const Style(underline: true));
/// ```
///
/// {@category CLI}
final class Style {
  final Color? fg;
  final Color? bg;
  final bool? bold;
  final bool? dim;
  final bool? italic;
  final bool? underline;
  final bool? reverse;

  const Style({this.fg, this.bg, this.bold, this.dim, this.italic, this.underline, this.reverse});

  static const none = Style();

  /// This style with [other]'s set fields on top.
  Style operator +(Style? other) => other == null || identical(other, none)
      ? this
      : identical(this, none)
      ? other
      : Style(
          fg: other.fg ?? fg,
          bg: other.bg ?? bg,
          bold: other.bold ?? bold,
          dim: other.dim ?? dim,
          italic: other.italic ?? italic,
          underline: other.underline ?? underline,
          reverse: other.reverse ?? reverse,
        );

  /// The SGR sequence that sets exactly this style from a reset, at [depth] colours (0: none).
  String _sgr(int depth) {
    final p = <String>[
      '0',
      if (bold == true) '1',
      if (dim == true) '2',
      if (italic == true) '3',
      if (underline == true) '4',
      if (reverse == true) '7',
      if (depth > 0 && fg != null) fg!._sgr(depth),
      if (depth > 0 && bg != null) bg!._sgr(depth, bg: true),
    ];
    return '\x1b[${p.join(';')}m';
  }

  @override
  bool operator ==(Object other) =>
      other is Style &&
      other.fg == fg &&
      other.bg == bg &&
      other.bold == bold &&
      other.dim == dim &&
      other.italic == italic &&
      other.underline == underline &&
      other.reverse == reverse;

  @override
  int get hashCode => Object.hash(fg, bg, bold, dim, italic, underline, reverse);
}

/// A run of text in one [Style]: what [Label.spans] and [Canvas.spans] take.
///
/// {@category CLI}
final class Span {
  final String text;
  final Style style;

  const Span(this.text, [this.style = Style.none]);
}

/// The glyphs a box is drawn with.
///
/// {@category CLI}
final class Border {
  final String topLeft, top, topRight, side, bottomLeft, bottomRight;

  const Border(this.topLeft, this.top, this.topRight, this.side, this.bottomLeft, this.bottomRight);

  static const rounded = Border('╭', '─', '╮', '│', '╰', '╯');
  static const square = Border('┌', '─', '┐', '│', '└', '┘');
  static const double = Border('╔', '═', '╗', '║', '╚', '╝');
  static const heavy = Border('┏', '━', '┓', '┃', '┗', '┛');
  static const ascii = Border('+', '-', '+', '|', '+', '+');

  /// No glyphs and no space: a [Box] with it is only its padding and title.
  static const none = Border('', '', '', '', '', '');
}

/// The tokens every widget shares: palette and glyph sets. A widget's own parameters and builders
/// are its tweaks; this is what keeps a screen of them consistent.
///
/// Unset tokens inherit, so a [Themed] subtree changes only what it names:
///
/// ```dart
/// await Tui.run(s, theme: TuiTheme(accent: Style(fg: Color.magenta)), view: …, update: …);
/// Themed(TuiTheme(border: Border.double), sidebar)
/// ```
///
/// {@category CLI}
final class TuiTheme {
  final Style? _text, _muted, _accent, _selected, _focused, _border, _success, _warning, _error;
  final Border? _borders;
  final String? _scrollTrack, _scrollThumb, _barFill, _barEmpty, _barHead, _checked, _unchecked, _pointer;
  final List<String>? _spinner;

  const TuiTheme({
    Style? text,
    Style? muted,
    Style? accent,
    Style? selected,
    Style? focused,
    Style? border,
    Style? success,
    Style? warning,
    Style? error,
    Border? borders,
    String? scrollTrack,
    String? scrollThumb,
    String? barFill,
    String? barEmpty,
    String? barHead,
    String? checked,
    String? unchecked,
    String? pointer,
    List<String>? spinner,
  }) : _text = text,
       _muted = muted,
       _accent = accent,
       _selected = selected,
       _focused = focused,
       _border = border,
       _success = success,
       _warning = warning,
       _error = error,
       _borders = borders,
       _scrollTrack = scrollTrack,
       _scrollThumb = scrollThumb,
       _barFill = barFill,
       _barEmpty = barEmpty,
       _barHead = barHead,
       _checked = checked,
       _unchecked = unchecked,
       _pointer = pointer,
       _spinner = spinner;

  /// Plain text.
  Style get text => _text ?? Style.none;

  /// Secondary text: placeholders, hints, unfocused chrome.
  Style get muted => _muted ?? const Style(dim: true);

  /// What should catch the eye: titles, matched filter characters, the active tab.
  Style get accent => _accent ?? const Style(fg: Color.cyan);

  /// The cursor row of a focused list or table.
  Style get selected => _selected ?? const Style(reverse: true);

  /// The border and title of a box holding the focus.
  Style get focused => _focused ?? const Style(fg: Color.cyan);

  /// Every other border.
  Style get border => _border ?? Style.none;

  Style get success => _success ?? const Style(fg: Color.green);
  Style get warning => _warning ?? const Style(fg: Color.yellow);
  Style get error => _error ?? const Style(fg: Color.red);

  /// The glyphs a [Box] draws with unless it names its own.
  Border get borders => _borders ?? Border.rounded;

  String get scrollTrack => _scrollTrack ?? '│';
  String get scrollThumb => _scrollThumb ?? '┃';
  String get barFill => _barFill ?? '█';
  String get barEmpty => _barEmpty ?? '░';
  String get barHead => _barHead ?? '';
  String get checked => _checked ?? '◉';
  String get unchecked => _unchecked ?? '○';
  String get pointer => _pointer ?? '›';
  List<String> get spinner => _spinner ?? const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  /// This theme with [base] filling what it leaves unset.
  TuiTheme _over(TuiTheme base) => TuiTheme(
    text: _text ?? base._text,
    muted: _muted ?? base._muted,
    accent: _accent ?? base._accent,
    selected: _selected ?? base._selected,
    focused: _focused ?? base._focused,
    border: _border ?? base._border,
    success: _success ?? base._success,
    warning: _warning ?? base._warning,
    error: _error ?? base._error,
    borders: _borders ?? base._borders,
    scrollTrack: _scrollTrack ?? base._scrollTrack,
    scrollThumb: _scrollThumb ?? base._scrollThumb,
    barFill: _barFill ?? base._barFill,
    barEmpty: _barEmpty ?? base._barEmpty,
    barHead: _barHead ?? base._barHead,
    checked: _checked ?? base._checked,
    unchecked: _unchecked ?? base._unchecked,
    pointer: _pointer ?? base._pointer,
    spinner: _spinner ?? base._spinner,
  );
}
