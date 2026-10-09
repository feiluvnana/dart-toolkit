/// What both UIs draw with: `Style` and the `Palette`, the `Tally` that models work in progress
/// and the builder views. `cli` and `tui` each import it, so a script that imports only `core`
/// compiles none of it; the keys and the raw terminal are `keys.dart`'s.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'core.dart';

/// Not API: the terminal facts `cli` and `tui` both draw by.
final class TerminalBridge {
  /// The `Tui` app on screen, while one runs: a console display then draws no live region.
  static Object? app;

  /// [parts] that are not empty, two spaces apart: a line's tail.
  static String joined(Iterable<String> parts) => parts.where((p) => p.isNotEmpty).join('  ');

  /// A line [columns] wide of [head] (a label, kept), a bar of [fraction] in what is left and a
  /// tail [tailWidth] wide: the bar gives way first, then the tail. Answers the head cut to fit
  /// and the bar's glyphs (`''` for none), for a console line and a `Board` row alike.
  static (String head, String bar) fit(int columns, String head, double? fraction, int tailWidth, Palette p) {
    final tail = tailWidth == 0 ? 0 : tailWidth + 2;
    final keep = columns * 2 ~/ 5 > columns - tail - (fraction == null ? 0 : 8)
        ? columns * 2 ~/ 5
        : columns - tail - (fraction == null ? 0 : 8);
    final h = Style.truncate(head, keep < 1 ? 1 : keep, ellipsis: p.ellipsis);
    final room = columns - Style.width(h) - tail - 2;
    return (h, fraction == null || room < 4 ? '' : p.bar.draw(fraction, room < 20 ? room : 20));
  }

  /// How a value is named where it is shown: an enum by its `name`, a duration humanized, a date
  /// in ISO 8601, a row (a map) by its cells; a list's default label and a prompt's hint.
  static String label(Object? value) => switch (value) {
    Enum() => value.name,
    Duration() => value.humanized,
    DateTime() => value.toIso8601String(),
    Map() => value.values.map((v) => v ?? '').join(' '),
    _ => '$value',
  };

  /// Colours the process's terminal shows, from the environment: `NO_COLOR` or a scope's
  /// `color: false` leaves attributes only (0). A scope's terminal shows its own.
  static int depth() {
    if (IoBridge.color == false) return 0;
    if (IoBridge.terminal case final t?) return t.colors;
    if (IoBridge.color == null && Env.has('NO_COLOR')) return 0;
    final ct = Env.get<String>('COLORTERM', or: '');
    if (ct.contains('truecolor') || ct.contains('24bit')) return 1 << 24;
    final term = Env.get<String>('TERM', or: '');
    if (term == 'dumb') return 0;
    return term.contains('256') ? 256 : 16;
  }

  /// Whether the process's terminal draws Unicode: not the Linux console, a non-UTF-8 locale, or
  /// the Windows console outside Windows Terminal.
  static final bool unicode = () {
    String first(List<String> keys) {
      for (final key in keys) {
        final value = Env.get<String>(key, or: '');
        if (value.isNotEmpty) return value;
      }
      return 'UTF-8';
    }

    return Platform.isWindows
        ? Env.get<String>('WT_SESSION', or: '').isNotEmpty ||
              Env.get<String>('TERM_PROGRAM', or: '').isNotEmpty ||
              _utf8CodePage()
        : Env.get<String>('TERM', or: '') != 'linux' &&
              first(const ['LC_ALL', 'LC_CTYPE', 'LANG']).toLowerCase().replaceAll('-', '').contains('utf8');
  }();

  /// Whether what is drawn here draws Unicode: the scope's terminal's answer, else [unicode].
  static bool get drawsUnicode => IoBridge.terminal?.unicode ?? unicode;

  /// [palette] as it is drawn on a terminal that does ([unicode]) or does not draw Unicode: ASCII
  /// under its unset glyphs there.
  static Palette drawable(Palette palette, {bool? unicode}) =>
      (unicode ?? drawsUnicode) ? palette : palette._over(Palette.ascii);

  /// [palette], or an [ArgumentError] naming what cannot be drawn.
  static Palette checked(Palette palette) {
    if (palette.frames.isEmpty) throw ArgumentError.value(palette.frames, 'frames', 'Invalid frames: none');
    if (palette.interval <= Duration.zero) {
      throw ArgumentError.value(palette.interval, 'interval', 'Invalid interval, expected more than zero');
    }
    return palette;
  }

  /// [palette] laid over [base]: what a nested theme's unset tokens take.
  static Palette over(Palette palette, Palette base) => palette._over(base);

  /// The sequence that sets exactly [style] from a reset, at [depth] colours.
  static String sgrOf(Style style, int depth) => style._sgr(depth);

  /// Set while a line is built for a sink that drops escapes: [Style.call] then writes none.
  static bool unstyled = false;

  /// What [build] returns with styling off: for a sink that drops escapes anyway.
  static T plain<T>(T Function() build) {
    final was = unstyled;
    unstyled = true;
    try {
      return build();
    } finally {
      unstyled = was;
    }
  }

  /// [text] as runs of plain text, each in the style its SGR escapes set: what [Style.call]
  /// wrote, read back. Other escapes are dropped, a hyperlink's text kept.
  static List<(String, Style)> runs(String text) {
    if (!text.contains('\x1b')) return [(text, Style.none)];
    final out = <(String, Style)>[];
    Color? fg, bg;
    bool? bold, dim, italic, underline, reverse;
    var at = 0;
    void flush(int end) {
      if (end > at) {
        out.add((
          text.substring(at, end),
          Style(fg: fg, bg: bg, bold: bold, dim: dim, italic: italic, underline: underline, reverse: reverse),
        ));
      }
    }

    for (final m in TextBridge.escape.allMatches(text)) {
      flush(m.start);
      at = m.end;
      if (m[2] != 'm') continue;
      final codes = [for (final c in m[1]!.split(RegExp('[;:]'))) int.tryParse(c) ?? 0];
      for (var i = 0; i < codes.length; i++) {
        switch (codes[i]) {
          case 0:
            fg = bg = bold = dim = italic = underline = reverse = null;
          case 1:
            bold = true;
          case 2:
            dim = true;
          case 3:
            italic = true;
          case 4:
            underline = true;
          case 7:
            reverse = true;
          case 22:
            bold = dim = false;
          case 23:
            italic = false;
          case 24:
            underline = false;
          case 27:
            reverse = false;
          case final c && (>= 30 && <= 37):
            fg = Color(c - 30);
          case final c && (>= 90 && <= 97):
            fg = Color(c - 82);
          case final c && (>= 40 && <= 47):
            bg = Color(c - 40);
          case final c && (>= 100 && <= 107):
            bg = Color(c - 92);
          case 39:
            fg = null;
          case 49:
            bg = null;
          case final c && (38 || 48):
            final Color? colour;
            if (i + 2 < codes.length && codes[i + 1] == 5) {
              colour = Color(codes[i + 2] & 255);
              i += 2;
            } else if (i + 4 < codes.length && codes[i + 1] == 2) {
              colour = Color.rgb(codes[i + 2], codes[i + 3], codes[i + 4]);
              i += 4;
            } else {
              colour = null;
            }
            c == 38 ? fg = colour : bg = colour;
        }
      }
    }
    flush(text.length);
    return out;
  }

  /// The SGR parameters of a colour — [kind] 0 named (0–15), 1 palette (0–255), 2 RGB
  /// (0xRRGGBB) — as foreground, or background with [bg], at [depth] colours: the nearest it shows.
  static String sgr(int kind, int value, int depth, {bool bg = false}) {
    var (k, v) = (kind, value);
    if (k == 2 && depth < 1 << 24) (k, v) = (1, _rgbTo256(v));
    if (k == 1 && depth < 256) (k, v) = (0, _paletteTo16(v));
    if (k == 1 && v < 16) k = 0;
    return switch (k) {
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
}

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
  String _sgr(int depth, {bool bg = false}) => TerminalBridge.sgr(_kind, _value, depth, bg: bg);

  @override
  bool operator ==(Object other) => other is Color && other._kind == _kind && other._value == _value;

  @override
  int get hashCode => _kind << 24 ^ _value;
}

/// How text looks, in a console line and a Tui cell alike. Unset fields inherit: `base + over`
/// takes [over]'s set fields. Called on text, it styles it for a console line.
///
/// The statics are terminal text, measured in cells and aware of escapes: [width], [plain],
/// [truncate], [pad] and [wrap]; `'docs'.link(url)` makes a hyperlink.
///
/// ```dart
/// const title = Style(fg: Color.cyan, bold: true);
/// Console.line(title('Ready') + ' docs'.link(Uri.parse('https://x.dev')));
/// Style.truncate(name, 20); Style.pad(size, 8, align: Align.right);
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

  /// [text] in this style, at the colours the terminal shows, closing what it opens and reopening
  /// it after a reset inside [text], so styles nest. Plain where colour is off.
  String call(String text) {
    if (TerminalBridge.unstyled || IoBridge.color == false || identical(this, none)) return text;
    final open = _sgr(TerminalBridge.depth());
    return '$open${text.replaceAll('\x1B[0m', '\x1B[0m$open')}\x1B[0m';
  }

  /// The columns [text] takes on a terminal: escapes none, East Asian wide characters two.
  static int width(String text) => TextBridge.width(text);

  /// [text] without its escapes: styles, cursor moves, hyperlinks (their text kept).
  static String plain(String text) => TextBridge.stripAnsi(text);

  /// [text] cut to [width] columns, ending in [ellipsis] when cut, between graphemes and with its
  /// styles still closed.
  static String truncate(String text, int width, {String ellipsis = '…'}) {
    if (ellipsis == '…' || TextBridge.width(text) <= width) return TextBridge.truncate(text, width);
    final room = width - TextBridge.width(ellipsis) + 1;
    if (room < 1) {
      // Not even the ellipsis fits: as much of it as does, never the default glyph.
      final out = StringBuffer();
      var used = 0;
      for (final rune in TextBridge.stripAnsi(ellipsis).runes) {
        used += IoBridge.runeWidth(rune);
        if (used > width) break;
        out.writeCharCode(rune);
      }
      return '$out';
    }
    final cut = TextBridge.truncate(text, room);
    final at = cut.lastIndexOf('…');
    return at < 0 ? cut : cut.replaceRange(at, at + 1, ellipsis);
  }

  /// [text] filled with spaces to [width] columns, placed by [align]; wider text is kept whole.
  static String pad(String text, int width, {Align align = Align.left}) => TextBridge.pad(text, width, align: align);

  /// [text] in lines of at most [width] columns, broken at spaces and at its own newlines.
  static List<String> wrap(String text, int width) => TextBridge.wrap(text, width);

  /// The last sum and its terms: a run of text lays one style over one background, cell by cell.
  static Style? _base, _over, _sum;

  /// This style with [other]'s set fields on top.
  Style operator +(Style? other) {
    if (other == null || identical(other, none)) return this;
    if (identical(this, none)) return other;
    if (identical(this, _base) && identical(other, _over)) return _sum!;
    _base = this;
    _over = other;
    return _sum = Style(
      fg: other.fg ?? fg,
      bg: other.bg ?? bg,
      bold: other.bold ?? bold,
      dim: other.dim ?? dim,
      italic: other.italic ?? italic,
      underline: other.underline ?? underline,
      reverse: other.reverse ?? reverse,
    );
  }

  /// The sequences built so far, at the depth [_sgrDepth]: a screen has a handful of styles.
  static final Map<Style, String> _sgrs = {};
  static int _sgrDepth = -1;

  /// The SGR sequence that sets exactly this style from a reset, at [depth] colours (0: none).
  String _sgr(int depth) {
    if (depth != _sgrDepth || _sgrs.length > 256) {
      _sgrs.clear();
      _sgrDepth = depth;
    }
    return _sgrs[this] ??= _build(depth);
  }

  String _build(int depth) {
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
      identical(this, other) ||
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

/// Colour and emphasis on text, for a console line: `'failed'.red.bold`. Each is a [Style]
/// called on the text, so styles nest and drop away where colour is off.
///
/// {@category CLI}
extension StringStyles on String {
  String get red => const Style(fg: Color.red)(this);
  String get green => const Style(fg: Color.green)(this);
  String get yellow => const Style(fg: Color.yellow)(this);
  String get blue => const Style(fg: Color.blue)(this);
  String get magenta => const Style(fg: Color.magenta)(this);
  String get cyan => const Style(fg: Color.cyan)(this);
  String get gray => const Style(fg: Color.gray)(this);
  String get bold => const Style(bold: true)(this);
  String get dim => const Style(dim: true)(this);
  String get italic => const Style(italic: true)(this);
  String get underline => const Style(underline: true)(this);

  /// On a background of that colour: `' FAIL '.onRed.bold`.
  String get onRed => const Style(bg: Color.red)(this);
  String get onGreen => const Style(bg: Color.green)(this);
  String get onYellow => const Style(bg: Color.yellow)(this);
  String get onBlue => const Style(bg: Color.blue)(this);
  String get onMagenta => const Style(bg: Color.magenta)(this);
  String get onCyan => const Style(bg: Color.cyan)(this);
  String get onGray => const Style(bg: Color.gray)(this);

  /// In 24-bit colour, or the nearest of the 256 or 16 the terminal shows; plain under `NO_COLOR`.
  String rgb(int r, int g, int b) => Style(fg: Color.rgb(r, g, b))(this);

  /// On a 24-bit background, falling back as [rgb] does.
  String onRgb(int r, int g, int b) => Style(bg: Color.rgb(r, g, b))(this);

  /// A hyperlink to [url] (OSC 8): a click opens it where the terminal supports links; where
  /// colour is off (a log, a pipe, `NO_COLOR`) it is the text alone.
  ///
  /// ```dart
  /// Console.line('the docs'.link(Uri.parse('https://dart.dev')));
  /// ```
  String link(Uri url) {
    if (TerminalBridge.unstyled || IoBridge.color == false || TerminalBridge.depth() == 0) return this;
    return '\x1B]8;;$url\x1B\\$this\x1B]8;;\x1B\\';
  }
}

// ---- the palette -----------------------------------------------------------------------------

/// The marks a log line starts with, and that an indicator ends with.
///
/// {@category CLI}
final class Marks {
  final String ok, info, warn, error, debug;

  const Marks({this.ok = '✓', this.info = 'ℹ', this.warn = '⚠', this.error = '✖', this.debug = '·'});

  /// Only ASCII.
  static const ascii = Marks(ok: '+', info: 'i', warn: '!', error: 'x', debug: '.');

  /// The mark of [level].
  String of(LogLevel level) => switch (level) {
    LogLevel.debug => debug,
    LogLevel.info => info,
    LogLevel.ok => ok,
    LogLevel.warn => warn,
    LogLevel.error || LogLevel.silent => error,
  };
}

/// A bar's glyphs: [fill] for the part done, [head] after it (`''` for none), [empty] for the rest.
///
/// {@category CLI}
final class BarGlyphs {
  final String fill, empty, head;

  const BarGlyphs(this.fill, this.empty, [this.head = '']);

  /// Only ASCII.
  static const ascii = BarGlyphs('#', '-');

  /// A bar [width] columns wide, [fraction] of it done.
  String draw(double fraction, int width) {
    if (width <= 0) return '';
    final done = (fraction * width + 1e-9).floor().clamp(0, width);
    final tip = head.isNotEmpty && done < width ? 1 : 0;
    return fill * done + head * tip + empty * (width - done - tip);
  }
}

/// The tokens both UIs draw with: colours, marks, bar glyphs, the border, a spinner's frames and
/// its interval, a list's pointer and check boxes, a scrollbar and the ellipsis. One palette is
/// shared by `ConsoleTheme` and `TuiTheme`, which hold only their builders.
///
/// A palette names only what it changes; unset tokens are the defaults, or [ascii]'s where the
/// terminal cannot draw Unicode (the Linux console, a non-UTF-8 locale, the old Windows console).
///
/// ```dart
/// const palette = Palette(accent: Style(fg: Color.magenta), bar: BarGlyphs('=', ' ', '>'));
/// await Console.scope(() => work(), theme: const ConsoleTheme(palette: palette));
/// ```
///
/// {@category CLI}
final class Palette {
  final Style? _text, _muted, _accent, _success, _warning, _danger, _selected, _focused, _borderStyle;
  final Marks? _marks;
  final BarGlyphs? _bar;
  final Border? _border;
  final List<String>? _frames;
  final Duration? _interval;
  final String? _pointer, _checked, _unchecked, _scrollTrack, _scrollThumb, _ellipsis;

  const Palette({
    Style? text,
    Style? muted,
    Style? accent,
    Style? success,
    Style? warning,
    Style? danger,
    Style? selected,
    Style? focused,
    Style? borderStyle,
    Marks? marks,
    BarGlyphs? bar,
    Border? border,
    List<String>? frames,
    Duration? interval,
    String? pointer,
    String? checked,
    String? unchecked,
    String? scrollTrack,
    String? scrollThumb,
    String? ellipsis,
  }) : _text = text,
       _muted = muted,
       _accent = accent,
       _success = success,
       _warning = warning,
       _danger = danger,
       _selected = selected,
       _focused = focused,
       _borderStyle = borderStyle,
       _marks = marks,
       _bar = bar,
       _border = border,
       _frames = frames,
       _interval = interval,
       _pointer = pointer,
       _checked = checked,
       _unchecked = unchecked,
       _scrollTrack = scrollTrack,
       _scrollThumb = scrollThumb,
       _ellipsis = ellipsis;

  /// Only ASCII glyphs: what is drawn under a palette's unset glyphs where Unicode would not draw.
  static const ascii = Palette(
    marks: Marks.ascii,
    bar: BarGlyphs.ascii,
    border: Border.ascii,
    frames: [r'-', r'\', r'|', r'/'],
    pointer: '>',
    checked: '*',
    unchecked: 'o',
    scrollTrack: '|',
    scrollThumb: '#',
    ellipsis: '...',
  );

  /// Plain text.
  Style get text => _text ?? Style.none;

  /// Secondary text: debug lines, hints, live indicators, placeholders.
  Style get muted => _muted ?? const Style(dim: true);

  /// What should catch the eye: info lines, frames, titles, a list's cursor, filter matches.
  Style get accent => _accent ?? const Style(fg: Color.cyan);

  Style get success => _success ?? const Style(fg: Color.green);
  Style get warning => _warning ?? const Style(fg: Color.yellow);
  Style get danger => _danger ?? const Style(fg: Color.red);

  /// The cursor row of a focused list or table.
  Style get selected => _selected ?? const Style(reverse: true);

  /// The border and title of a box holding the focus.
  Style get focused => _focused ?? const Style(fg: Color.cyan);

  /// Borders.
  Style get borderStyle => _borderStyle ?? Style.none;

  /// The marks of the log levels: `✓ ℹ ⚠ ✖ ·`.
  Marks get marks => _marks ?? const Marks();

  /// A bar's glyphs: `█` and `░`.
  BarGlyphs get bar => _bar ?? const BarGlyphs('█', '░');

  /// A box's, a table's and a rule's border.
  Border get border => _border ?? Border.rounded;

  /// A spinner's frames, one cell each, [interval] apart.
  List<String> get frames => _frames ?? const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  /// How often live work is redrawn, and a spinner's frame changes.
  Duration get interval => _interval ?? const Duration(milliseconds: 80);

  /// A list's cursor, and its checked and unchecked boxes.
  String get pointer => _pointer ?? '›';
  String get checked => _checked ?? '◉';
  String get unchecked => _unchecked ?? '○';

  /// A scrollbar's track and thumb.
  String get scrollTrack => _scrollTrack ?? '│';
  String get scrollThumb => _scrollThumb ?? '┃';

  /// What ends text cut to fit.
  String get ellipsis => _ellipsis ?? '…';

  /// The frame of [frames] at [elapsed].
  String frameAt(Duration elapsed) => frames[elapsed.inMicroseconds ~/ interval.inMicroseconds % frames.length];

  Palette _over(Palette base) => Palette(
    text: _text ?? base._text,
    muted: _muted ?? base._muted,
    accent: _accent ?? base._accent,
    success: _success ?? base._success,
    warning: _warning ?? base._warning,
    danger: _danger ?? base._danger,
    selected: _selected ?? base._selected,
    focused: _focused ?? base._focused,
    borderStyle: _borderStyle ?? base._borderStyle,
    marks: _marks ?? base._marks,
    bar: _bar ?? base._bar,
    border: _border ?? base._border,
    frames: _frames ?? base._frames,
    interval: _interval ?? base._interval,
    pointer: _pointer ?? base._pointer,
    checked: _checked ?? base._checked,
    unchecked: _unchecked ?? base._unchecked,
    scrollTrack: _scrollTrack ?? base._scrollTrack,
    scrollThumb: _scrollThumb ?? base._scrollThumb,
    ellipsis: _ellipsis ?? base._ellipsis,
  );
}

/// Severity levels for the console's log verbs, from most to least verbose.
///
/// {@category CLI}
enum LogLevel {
  /// Everything, `Console.debug` included (`-v`).
  debug,

  /// Information and above: the default.
  info,

  /// Successes (`Console.ok`, how drawn work ends) and above.
  ok,

  /// Warnings and errors only (`-q`).
  warn,

  /// Errors only.
  error,

  /// Nothing.
  silent;

  /// The palette's colour for this level.
  Style styleIn(Palette palette) => switch (this) {
    debug => palette.muted,
    info => palette.accent,
    ok => palette.success,
    warn => palette.warning,
    error || silent => palette.danger,
  };
}

// ---- the tally -------------------------------------------------------------------------------

/// A rate over a sliding window of one second, from samples of a count that only grows: a
/// stall decays to nothing as its samples slide out.
final class _Meter {
  static const _window = Duration(seconds: 1);

  /// The span below which there is no rate yet.
  static const _least = Duration(milliseconds: 250);

  final _samples = ListQueue<(Duration, int)>();

  void add(Duration at, int count) {
    if (_samples.isNotEmpty) {
      final (last, _) = _samples.last;
      if (at < last) return;
      // Reports in a burst are one sample: the window stays a few dozen long.
      if (_samples.length > 1 && at - last < const Duration(milliseconds: 20)) _samples.removeLast();
    }
    _samples.add((at, count));
    // One sample at or before the window's start stays, so the whole window is measured.
    while (_samples.length > 2 && at - _samples.elementAt(1).$1 >= _window) {
      _samples.removeFirst();
    }
  }

  /// Per second, or `null` until the samples span a quarter of a second.
  double? get rate {
    if (_samples.length < 2) return null;
    final (t0, c0) = _samples.first;
    final (t1, c1) = _samples.last;
    final span = t1 - t0;
    return span < _least ? null : (c1 - c0) * 1e6 / span.inMicroseconds;
  }

  void reset() => _samples.clear();
}

Duration _span(num seconds) => Duration(microseconds: (seconds * 1e6).round().clamp(0, 1 << 52));

/// One item a [Tally] has heard of: its latest status and amounts, and its own rate.
///
/// {@category CLI}
final class TallyItem {
  final Tally _tally;

  /// What the work is about: the batch's input, or the task's item.
  final Object? item;

  String _label;
  Status<Object?, Object?> _status;
  int _received = 0;
  int? _total;
  Unit _unit = Unit.none;
  String? _step;
  final Duration _started;
  Duration? _ended;
  bool _ran = false;

  /// Its rate while it runs; an item that has ended keeps none.
  _Meter? _meter;

  /// What it adds to the tally's sized total, or -1 while its size is unknown.
  int _counted = -1;

  TallyItem._(this._tally, this.item, this._label, this._status, this._started);

  /// How a row names it: its status's label.
  String get label => _label;

  /// What it last reported, [Warned] notes aside.
  Status<Object?, Object?> get status => _status;

  /// Amounts as the last [Running] said, in [unit].
  int get received => _received;
  int? get total => _total;
  Unit get unit => _unit;

  /// The phase it is on: `'verifying'`.
  String? get step => _step;

  /// Whether it has ended: [Done], [Skipped], [Failed] or [Stopped].
  bool get isOver => _status.isFinal;

  /// Since it was first heard of, until it ended.
  Duration get elapsed => (_ended ?? _tally._now) - _started;

  /// [unit]s per second over the last second; `null` until known.
  double? get rate => isOver ? null : _meter?.rate;

  /// Time left at [rate], or `null` while either is unknown.
  Duration? get eta => switch ((_total, rate)) {
    (final all?, final r?) when r > 0 && !isOver => _span((all - _received).clamp(0, all) / r),
    _ => null,
  };

  /// Its size once known: the total it said, or what it received by the end.
  int? get _size => _total ?? (isOver ? _received : null);
}

/// The one model of work in progress, with no renderer: it hears [Status]es (from a [Task], a
/// [Batch], or [add] by hand) and keeps the counts, the amounts, a windowed rate, the time left,
/// the failures and the items under way. The console and the TUI both draw a tally: `show()`,
/// `Console.bar` and `Board(tally)`.
///
/// Producers report amounts; the tally measures rates over a sliding second, sampled on every
/// [sample] (a display's tick), so a stall decays. Time is [Clock.current]'s. An item that has
/// ended is let go once no row shows it: a million items cost what the running ones do.
///
/// ```dart
/// final tally = Tally.batch(urls.parallelize((u) => u.download(into: 'out')));
/// await tally.over;
/// print('${tally.done} of ${tally.count}, ${tally.failed} failed');
/// ```
///
/// {@category CLI}
final class Tally {
  final Clock _clock = Clock.current;
  late final Duration _start = _clock.elapsed;
  final int? _given;
  final int? Function()? _known;

  /// Whether this is one task's: its statuses are about one item, drawn as one line.
  final bool isTask;

  /// The items not yet ended, by their slot in the batch (equal inputs apart), else their item.
  final _items = <Object?, TallyItem>{};
  final _live = <TallyItem>{};
  final _failures = <Failed<Object?, Object?>>[];
  final _notes = <Status<Object?, Object?>>[];
  final _changes = StreamController<Status<Object?, Object?>>.broadcast(sync: true);
  final _over = Completer<void>();
  final _amounts = _Meter(), _ends = _Meter();
  final List<TallyItem> _shown = [];
  TallyItem? _latest;
  Duration? _endedAt;
  int _heard = 0, _done = 0, _failed = 0, _skipped = 0, _stopped = 0;

  /// Bytes received now, as the latest reports say; and moved in all, a restart not taking any back.
  int _received = 0, _moved = 0;
  bool _bytes = false;

  /// The sizes known so far, summed, and how many items have none yet.
  int _sized = 0, _unsized = 0;

  /// A tally fed by hand with [add], of [count] items when that is known; [close] ends it.
  Tally({int? count}) : _given = count, _known = null, isTask = false {
    if (count != null && count < 0) throw ArgumentError.value(count, 'count', 'Invalid count, expected at least 0');
    _start;
  }

  /// [task]'s statuses, as one item. The same task gives the same tally, so a view can ask for
  /// it on every frame (a job run again after it ended gets a fresh one).
  factory Tally.task(Task<Object?> task) {
    final kept = _ofTask[task];
    if (kept != null && !(kept.isOver && !task.status.isFinal)) return kept;
    return _ofTask[task] = Tally._task(task);
  }

  Tally._task(Task<Object?> task) : _given = 1, _known = null, isTask = true {
    _start;
    // The tally holds how it ended: a failure is in it, not an unhandled error.
    task.settled.ignore();
    task.statuses.listen((s) => _apply(s, null), onDone: _end);
  }

  /// [batch]'s statuses, one item each; the count is the batch's once it knows it. The same
  /// batch gives the same tally.
  factory Tally.batch(Batch<Object?, Object?> batch) => _ofBatch[batch] ??= Tally._batch(batch);

  Tally._batch(Batch<Object?, Object?> batch) : _given = null, _known = (() => batch.count), isTask = false {
    _start;
    batch.settled.ignore();
    if (StatusInternals.slotted(batch) case final slotted?) {
      slotted.listen((s) => _apply(s.$2, s.$1), onDone: _end);
    } else {
      batch.statuses.listen((s) => _apply(s, s.item), onDone: _end);
    }
  }

  static final _ofTask = Expando<Tally>('tally');
  static final _ofBatch = Expando<Tally>('tally');

  Duration get _now => _clock.elapsed;

  /// Items in all: as given, as the batch knows it, or once it is over, as many as were heard.
  int? get count => _given ?? _known?.call() ?? (isOver ? _heard : null);

  /// The item heard of last: a task's one item.
  TallyItem? get latest => _latest;

  /// Items ended, and of them done, failed, skipped and stopped.
  int get ended => _done + _failed + _skipped + _stopped;
  int get done => _done;
  int get failed => _failed;
  int get skipped => _skipped;
  int get stopped => _stopped;

  /// Items under way.
  int get running => _live.length;

  /// Bytes received in all, as the items' latest reports say.
  int get received => _received;

  /// Bytes in all, once every item is known and sized; `null` before.
  int? get total {
    final n = count;
    if (!_bytes || n == null || _heard < n || _unsized > 0) return null;
    return _sized;
  }

  /// Bytes per second over the last second; `null` until known, or without bytes.
  double? get rate => _bytes && !isOver ? _amounts.rate : null;

  /// Items ended per second over the last second; `null` until known.
  double? get itemRate => isOver ? null : _ends.rate;

  /// Time left: by bytes when every size is known, else by items; `null` while unknown.
  Duration? get eta {
    if (isOver) return null;
    if (isTask) return _latest?.eta;
    if ((total, rate) case (final all?, final r?) when r > 0) return _span((all - _received).clamp(0, all) / r);
    if ((count, itemRate) case (final n?, final r?) when r > 0) return _span((n - ended).clamp(0, n) / r);
    return null;
  }

  /// Since the tally was made, until the work ended.
  Duration get elapsed => (_endedAt ?? _now) - _start;

  /// Whether the work has ended (a hand-fed tally: whether it is [close]d).
  bool get isOver => _over.isCompleted;

  /// Completes when the work ends.
  Future<void> get over => _over.future;

  /// Every [Failed], in the order they came.
  List<Failed<Object?, Object?>> get failures => UnmodifiableListView(_failures);

  /// The latest hundred [Warned] notes and [Failed] items, in the order they came: what a
  /// display prints above or under what it draws.
  List<Status<Object?, Object?>> get notes => UnmodifiableListView(_notes);

  void _note(Status<Object?, Object?> status) {
    if (_notes.length >= 100) _notes.removeAt(0);
    _notes.add(status);
  }

  /// Each status as it is taken in, [Warned] notes included: what a display redraws on.
  Stream<Status<Object?, Object?>> get changes => _changes.stream;

  /// Takes in [status], by hand: statuses of one item share its `item`, and a status after the
  /// one that ended it is another item's. A tally that is over is a [StateError].
  void add(Status<Object?, Object?> status) {
    if (isOver) throw StateError('Cannot add $status: the tally is closed');
    if (_known != null || isTask) throw StateError('Cannot add $status: the tally hears its own work');
    _apply(status, status.item);
  }

  /// Ends a tally fed by hand.
  void close() {
    if (_known != null || isTask) throw StateError('Cannot close a tally that hears its own work');
    _end();
  }

  /// Records the time now for the rates: a display calls it on every tick, so a stall decays.
  void sample() {
    final now = _now;
    _amounts.add(now, _moved);
    _ends.add(now, ended);
    for (final item in _live) {
      item._meter?.add(now, item._received);
    }
  }

  /// At most [max] items to draw as rows, and how many running ones are left out. A running row
  /// keeps its place; a new item takes a free row, else the one that ended longest ago.
  ({List<TallyItem> rows, int more}) rows(int max) {
    if (max < 1) throw ArgumentError.value(max, 'max', 'Invalid rows, expected at least 1');
    final shown = _shown;
    final placed = shown.toSet();
    for (final item in _live) {
      if (placed.contains(item)) continue;
      if (shown.length < max) {
        shown.add(item);
        placed.add(item);
        continue;
      }
      var oldest = -1;
      for (var i = 0; i < shown.length; i++) {
        final ended = shown[i]._ended;
        if (ended != null && (oldest < 0 || ended < shown[oldest]._ended!)) oldest = i;
      }
      if (oldest < 0) break;
      placed.remove(shown[oldest]);
      shown[oldest] = item;
      placed.add(item);
    }
    while (shown.length > max) {
      final ended = shown.indexWhere((i) => i.isOver);
      shown.removeAt(ended >= 0 ? ended : shown.length - 1);
    }
    var more = 0;
    for (final item in _live) {
      if (!placed.contains(item)) more++;
    }
    return (rows: List.unmodifiable(shown), more: more);
  }

  /// Takes in [status] of the item at [key].
  void _apply(Status<Object?, Object?> status, Object? key) {
    if (status is Warned) {
      _note(status);
      _changes.add(status);
      return;
    }
    final now = _now;
    var entry = _items[key];
    if (entry == null) {
      entry = TallyItem._(this, status.item, status.label, Waiting(status.item, label: status.label), now);
      _heard++;
      _unsized++;
      if (!status.isFinal) _items[key] = entry;
    }
    entry._label = status.label;
    switch (status) {
      case Running(:final received, :final total, :final unit, :final step):
        if (!entry._ran) _live.add(entry);
        entry._ran = true;
        if (entry._unit == Unit.bytes) _received -= entry._received;
        if (unit == Unit.bytes) {
          _bytes = true;
          _received += received;
          if (entry._unit == Unit.bytes && received > entry._received) _moved += received - entry._received;
          if (entry._unit != Unit.bytes) _moved += received;
        }
        // A restart (a retry from zero) measures again from where it is.
        final meter = entry._meter ??= _Meter();
        if (received < entry._received || unit != entry._unit) meter.reset();
        entry
          .._received = received
          .._total = total
          .._unit = unit
          .._step = step;
        meter.add(now, received);
      case Done():
        _done++;
        // Done is all of it: the last report may have come a chunk before the end.
        if ((entry._unit, entry._total) case (Unit.bytes, final all?) when entry._received < all) {
          _received += all - entry._received;
          _moved += all - entry._received;
          entry._received = all;
        }
      case Skipped():
        _skipped++;
      case final Failed<Object?, Object?> failed:
        _failed++;
        _failures.add(failed);
        if (!isTask) _note(failed);
      case Stopped():
        _stopped++;
      case Waiting() || Paused() || Warned():
    }
    entry._status = status;
    if (status.isFinal) {
      entry
        .._ended = now
        .._meter = null;
      _live.remove(entry);
      _items.remove(key);
      _ends.add(now, ended);
    }
    _resize(entry);
    _amounts.add(now, _moved);
    _latest = entry;
    _changes.add(status);
  }

  /// Keeps [_sized] and [_unsized] as [entry]'s size now says.
  void _resize(TallyItem entry) {
    final size = entry._size;
    if (entry._counted >= 0) {
      _sized -= entry._counted;
    } else {
      _unsized--;
    }
    if (size == null) {
      _unsized++;
      entry._counted = -1;
    } else {
      _sized += size;
      entry._counted = size;
    }
  }

  void _end() {
    if (_over.isCompleted) return;
    _endedAt = _now;
    _live.clear();
    _over.complete();
    _changes.close();
  }
}

// ---- the views builders are handed -----------------------------------------------------------

/// `1.2 MB/2.0 GB`, `12/50`, `12.0 KB` while the size is unknown, or `''`.
String _amounts(int received, int? total, Unit unit) => switch (unit) {
  Unit.bytes when total != null && total > 0 => '${received.humanBytes}/${total.humanBytes}',
  Unit.bytes when received > 0 => received.humanBytes,
  Unit.items when total != null => '$received/$total',
  Unit.items when received > 0 => '$received',
  _ => '',
};

/// `3.1 MB/s`, `12/s`, or `''` while unknown.
String _pace(double? rate, Unit unit) => switch (rate) {
  final r? when r > 0 && unit == Unit.bytes => '${r.humanBytes}/s',
  final r? when r > 0 => '${r >= 10 ? r.round() : r.toStringAsFixed(1)}/s',
  _ => '',
};

/// What [TaskView] and [BatchView] draw their fraction with.
mixin _Drawn {
  double? get fraction;
  Palette get palette;
  Duration get elapsed;

  /// The fraction in whole percent, or `null` while unknown.
  int? get percent => switch (fraction) {
    final f? => (f * 100 + 1e-9).floor(),
    _ => null,
  };

  /// The spinner's frame now.
  String get frame => palette.frameAt(elapsed);

  /// A bar [width] columns wide, in the palette's glyphs.
  String bar(int width) => palette.bar.draw(fraction ?? 0, width);
}

/// One task's progress, for a `task:` builder: a single task's line, or a row of a batch.
///
/// {@category CLI}
final class TaskView with _Drawn {
  /// The line's title for a single task, the item's label for a row.
  final String label;

  /// What it last reported: `switch` on it.
  final Status<Object?, Object?> status;

  /// Amounts in [unit].
  final int received;
  final int? total;
  final Unit unit;
  final String? step;

  /// [unit]s per second over the last second, and the time left; `null` while unknown.
  final double? rate;
  final Duration? eta;
  @override
  final Duration elapsed;

  /// Whether this is a row under a batch's header.
  final bool isRow;

  /// Whether it is redrawn in place, or a line a log keeps (no terminal).
  final bool isLive;

  /// Columns the line may use.
  final int columns;
  @override
  final Palette palette;

  const TaskView({
    required this.label,
    required this.status,
    this.received = 0,
    this.total,
    this.unit = Unit.none,
    this.step,
    this.rate,
    this.eta,
    this.elapsed = Duration.zero,
    this.isRow = false,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  });

  /// [item] as it stands, under [label] when given.
  TaskView.of(
    TallyItem item, {
    String? label,
    this.isRow = false,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  }) : label = label ?? item.label,
       status = item.status,
       received = item.received,
       total = item.total,
       unit = item.unit,
       step = item.step,
       rate = item.rate,
       eta = item.eta,
       elapsed = item.elapsed;

  /// From 0.0 to 1.0, or `null` while the size is unknown.
  @override
  double? get fraction => switch (status) {
    Done() || Skipped() => 1.0,
    _ => switch (total) {
      final all? when all > 0 => (received / all).clamp(0.0, 1.0),
      _ => null,
    },
  };

  /// `1.2 MB/2.0 GB`, `3/8`, or `''`.
  String get amounts => _amounts(received, total, unit);

  /// `3.1 MB/s`, or `''`.
  String get pace => _pace(rate, unit);
}

/// A batch as it stands, for a `batch:` builder: its header.
///
/// {@category CLI}
final class BatchView with _Drawn {
  final String title;

  /// Items in all, or `null` while unknown.
  final int? count;

  /// Items ended, and of them done, failed, skipped and stopped; items under way.
  final int ended, done, failed, skipped, stopped, running;

  /// Running items without a row: `+N more`.
  final int more;

  /// Bytes so far, and in all once every item is sized.
  final int received;
  final int? total;

  /// Bytes and items per second over the last second, and the time left; `null` while unknown.
  final double? rate, itemRate;
  final Duration? eta;
  @override
  final Duration elapsed;

  /// The label of the item heard of last: a hand-fed bar's latest tick.
  final String? latest;

  final bool isLive;
  final int columns;
  @override
  final Palette palette;

  const BatchView({
    required this.title,
    this.count,
    this.ended = 0,
    this.done = 0,
    this.failed = 0,
    this.skipped = 0,
    this.stopped = 0,
    this.running = 0,
    this.more = 0,
    this.received = 0,
    this.total,
    this.rate,
    this.itemRate,
    this.eta,
    this.elapsed = Duration.zero,
    this.latest,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  });

  /// [tally] as it stands, under [title].
  BatchView.of(
    Tally tally, {
    required this.title,
    this.more = 0,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  }) : count = tally.count,
       ended = tally.ended,
       done = tally.done,
       failed = tally.failed,
       skipped = tally.skipped,
       stopped = tally.stopped,
       running = tally.running,
       received = tally.received,
       total = tally.total,
       rate = tally.rate,
       itemRate = tally.itemRate,
       eta = tally.eta,
       elapsed = tally.elapsed,
       latest = tally.latest?.label;

  /// Items ended of [count], from 0.0 to 1.0; `null` while the count is unknown.
  @override
  double? get fraction => switch (count) {
    null => null,
    0 => 1.0,
    final n => (ended / n).clamp(0.0, 1.0),
  };

  /// `120.0 MB/400.0 MB` once sized, `120.0 MB` before, or `''` without bytes.
  String get amounts => _amounts(received, total, Unit.bytes);

  /// Bytes per second when bytes move, else items per second, or `''`.
  String get pace => received > 0 && rate != null ? _pace(rate, Unit.bytes) : _pace(itemRate, Unit.items);
}

/// A row of a list to pick from: `list.pick`'s, a `Menu`'s, a `Tabs` title.
///
/// {@category CLI}
final class ItemView<T> {
  /// Its index in the full list.
  final int index;
  final T value;

  /// Its text: what the filter matched against.
  final String label;

  /// Whether the cursor is on it.
  final bool isSelected;

  /// Whether it is checked; `null` unless several are picked.
  final bool? isChecked;

  /// Whether the list has the focus, and whether the pointer is over this row.
  final bool isFocused, isHovered;

  /// Where the filter matched [label], as `[start, end)` ranges.
  final List<(int, int)> matches;
  final Palette palette;

  const ItemView({
    required this.index,
    required this.value,
    required this.label,
    this.isSelected = false,
    this.isChecked,
    this.isFocused = true,
    this.isHovered = false,
    this.matches = const [],
    this.palette = const Palette(),
  });

  /// [label] in parts, each with whether the filter matched it.
  List<(String, bool)> get parts {
    if (matches.isEmpty) return [(label, false)];
    final out = <(String, bool)>[];
    var at = 0;
    for (final (s, e) in matches) {
      if (s > at) out.add((label.substring(at, s), false));
      out.add((label.substring(s, e), true));
      at = e;
    }
    if (at < label.length) out.add((label.substring(at), false));
    return out;
  }
}

/// A line that stays, for a `log:` builder: a log verb's, how drawn work ends, a warning or a
/// failure printed above live work.
///
/// {@category CLI}
final class LogView {
  final LogLevel level;
  final String message;

  /// How long the work this line ends took; `null` on a line that ends nothing.
  final Duration? elapsed;
  final Palette palette;

  const LogView(this.level, this.message, {this.elapsed, this.palette = const Palette()});

  /// The palette's mark for [level].
  String get mark => palette.marks.of(level);

  /// The palette's colour for [level].
  Style get style => level.styleIn(palette);
}

/// Whether the Windows console's output code page is UTF-8 (65001), as `chcp` reports it: asked
/// once, and only where neither Windows Terminal nor another emulator says so first. A process,
/// not `kernel32`'s `GetConsoleOutputCP`, because `dart:ffi` costs every `cli` script 40 ms of
/// startup; a console that cannot answer answers no.
bool _utf8CodePage() {
  try {
    final out = Process.runSync('chcp.com', const []).stdout;
    return out is String && RegExp(r'(\d+)\D*$').firstMatch(out.trim())?[1] == '65001';
  } on Exception catch (_) {
    return false; // no chcp: the code page is unknown, so not UTF-8
  }
}
