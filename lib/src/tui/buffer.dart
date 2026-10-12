/// The cell grid: what layout paints, what the diff reads, what the terminal
/// gets. A frame is `List<Cell>`; a frame change is the cells that differ;
/// the change encodes as positioned ANSI. Colour falls back 24-bit → 256 →
/// 16 → none (plus `NO_COLOR`); the level is chosen once per terminal, never
/// per cell.
library;

import 'width.dart';

/// How much colour the terminal speaks.
enum ColorLevel {
  /// No colour or styling at all (also when `NO_COLOR` is set).
  none,

  /// The 16 ANSI colours.
  ansi16,

  /// The 256-colour palette.
  ansi256,

  /// 24-bit RGB.
  truecolor,
}

/// A colour: none, one of the 16 ANSI colours, a 256-palette entry, or RGB.
/// Anything resolves down to the terminal's [ColorLevel].
sealed class TuiColor {
  const TuiColor();

  const factory TuiColor.none() = _None._;
  const factory TuiColor.ansi(int index) = _Ansi;
  const factory TuiColor.ansi256(int index) = _Ansi256;
  const factory TuiColor.rgb(int r, int g, int b) = _Rgb;

  static const black = _Ansi(0);
  static const red = _Ansi(1);
  static const green = _Ansi(2);
  static const yellow = _Ansi(3);
  static const blue = _Ansi(4);
  static const magenta = _Ansi(5);
  static const cyan = _Ansi(6);
  static const white = _Ansi(7);
  static const brightBlack = _Ansi(8);
  static const brightRed = _Ansi(9);
  static const brightGreen = _Ansi(10);
  static const brightYellow = _Ansi(11);
  static const brightBlue = _Ansi(12);
  static const brightMagenta = _Ansi(13);
  static const brightCyan = _Ansi(14);
  static const brightWhite = _Ansi(15);
}

final class _None extends TuiColor {
  const _None._();

  @override
  bool operator ==(Object other) => other is _None;

  @override
  int get hashCode => (_None).hashCode;
}

final class _Ansi extends TuiColor {
  final int index;
  const _Ansi(this.index);

  @override
  bool operator ==(Object other) => other is _Ansi && other.index == index;

  @override
  int get hashCode => index.hashCode;
}

final class _Ansi256 extends TuiColor {
  final int index;
  const _Ansi256(this.index);

  @override
  bool operator ==(Object other) => other is _Ansi256 && other.index == index;

  @override
  int get hashCode => index.hashCode ^ 0x100;
}

final class _Rgb extends TuiColor {
  final int r, g, b;
  const _Rgb(this.r, this.g, this.b);

  @override
  bool operator ==(Object other) => other is _Rgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

/// The SGR parameters painting [fg]/[bg] at [level] (empty when unstyled).
String sgrFor(TuiColor? fg, TuiColor? bg, ColorLevel level, CellStyle attrs) {
  if (level == ColorLevel.none) return '';
  final parts = <String>[];
  if (attrs.bold) parts.add('1');
  if (attrs.dim) parts.add('2');
  if (attrs.italic) parts.add('3');
  if (attrs.underline) parts.add('4');
  if (attrs.reverse) parts.add('7');
  final f = _resolve(fg, level, true);
  if (f != null) parts.add(f);
  final b = _resolve(bg, level, false);
  if (b != null) parts.add(b);
  return parts.join(';');
}

String? _resolve(TuiColor? color, ColorLevel level, bool fg) {
  if (color == null || color is _None) return null;
  if (level == ColorLevel.none) return null;
  if (color is _Ansi) {
    final i = color.index.clamp(0, 15);
    final base = fg ? 30 : 40;
    return i < 8 ? '${base + i}' : '${base + 60 + (i - 8)}';
  }
  if (color is _Ansi256) {
    final i = color.index.clamp(0, 255);
    if (level == ColorLevel.ansi16) return _resolve(_Ansi(_nearest16(_rgbOf256(i))), level, fg);
    return fg ? '38;5;$i' : '48;5;$i';
  }
  if (color is _Rgb) {
    if (level == ColorLevel.truecolor) {
      return fg ? '38;2;${color.r};${color.g};${color.b}' : '48;2;${color.r};${color.g};${color.b}';
    }
    return _resolve(_Ansi256(_to256(color.r, color.g, color.b)), level, fg);
  }
  return null;
}

/// Canonical RGB of the 16 ANSI colours (0-15).
const _ansiTable = [
  [0, 0, 0],
  [170, 0, 0],
  [0, 170, 0],
  [170, 85, 0],
  [0, 0, 170],
  [170, 0, 170],
  [0, 170, 170],
  [170, 170, 170],
  [85, 85, 85],
  [255, 85, 85],
  [85, 255, 85],
  [255, 255, 85],
  [85, 85, 255],
  [255, 85, 255],
  [85, 255, 255],
  [255, 255, 255],
];

int _nearest16(List<int> rgb) {
  var best = 0;
  var bestDist = 1 << 30;
  for (var i = 0; i < 16; i++) {
    final t = _ansiTable[i];
    final d = (t[0] - rgb[0]) * (t[0] - rgb[0]) + (t[1] - rgb[1]) * (t[1] - rgb[1]) + (t[2] - rgb[2]) * (t[2] - rgb[2]);
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return best;
}

List<int> _rgbOf256(int i) {
  if (i < 16) return _ansiTable[i];
  if (i < 232) {
    final v = i - 16;
    int comp(int k) {
      final c = k == 0 ? 0 : 55 + k * 40;
      return c;
    }

    return [comp(v ~/ 36), comp((v ~/ 6) % 6), comp(v % 6)];
  }
  final g = 8 + (i - 232) * 10;
  return [g, g, g];
}

int _to256(int r, int g, int b) {
  // Grayscale ramp when the channels agree closely.
  if ((r - g).abs() < 8 && (g - b).abs() < 8) {
    final v = (r + g + b) ~/ 3;
    if (v < 8) return 16;
    if (v > 248) return 231;
    return 232 + ((v - 8) ~/ 10);
  }
  int comp(int c) => c < 48
      ? 0
      : c < 115
      ? 1
      : c < 155
      ? 2
      : c < 195
      ? 3
      : c < 235
      ? 4
      : 5;
  return 16 + 36 * comp(r) + 6 * comp(g) + comp(b);
}

/// A bar's glyphs: [fill] for the part done, [head] after it (`''` for none),
/// [empty] for the rest. Shared by both UIs (`cli` imports this leaf file;
/// nothing in `tui` imports `cli`). Where the terminal cannot draw Unicode,
/// reach for [BarGlyphs.ascii].
final class BarGlyphs {
  final String fill, empty, head;

  const BarGlyphs(this.fill, this.empty, [this.head = '']);

  /// Classic solid blocks: `█` and `░`.
  static const blocks = BarGlyphs('█', '░');

  /// Sleek horizontal line with tapered tip: `━`, `─`, `╸`.
  static const line = BarGlyphs('━', '─', '╸');

  /// Minimalist line on empty background: `━` and ` `.
  static const solidLine = BarGlyphs('━', ' ');

  /// Dot markers: `●` and `○`.
  static const dots = BarGlyphs('●', '○');

  /// Square markers: `■` and `□`.
  static const squares = BarGlyphs('■', '□');

  /// Arrow progress: `=`, `-`, `>`.
  static const arrow = BarGlyphs('=', '-', '>');

  /// Only ASCII: `#` and `-`.
  static const ascii = BarGlyphs('#', '-');

  /// A bar [width] columns wide, [fraction] of it done.
  String draw(double fraction, int width) {
    if (width <= 0) return '';
    final f = fraction.clamp(0.0, 1.0);
    final done = (f * width + 1e-9).floor().clamp(0, width);
    final tip = head.isNotEmpty && done < width ? 1 : 0;
    return fill * done + head * tip + empty * (width - done - tip);
  }
}

/// A spinner's frames, shown [every] apart. Shared by both UIs like [BarGlyphs]; where the
/// terminal cannot draw Unicode, reach for [SpinGlyphs.ascii].
final class SpinGlyphs {
  final List<String> frames;
  final Duration every;

  const SpinGlyphs(this.frames, {this.every = const Duration(milliseconds: 80)});

  /// Braille dots turning: `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`.
  static const dots = SpinGlyphs(['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']);

  /// A quarter circle going round: `◜◝◞◟`.
  static const arc = SpinGlyphs(['◜', '◝', '◞', '◟'], every: Duration(milliseconds: 120));

  /// Only ASCII: `-\|/`.
  static const ascii = SpinGlyphs(['-', r'\', '|', '/'], every: Duration(milliseconds: 120));

  /// The frame for [at] (now by default): the spinner moves with the clock, so any redraw
  /// shows it turning.
  String frame([DateTime? at]) =>
      frames[(at ?? DateTime.now()).microsecondsSinceEpoch ~/ every.inMicroseconds % frames.length];
}

/// Cell text attributes.
final class CellStyle {
  final bool bold, dim, italic, underline, reverse;
  const CellStyle({
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.reverse = false,
  });

  @override
  bool operator ==(Object other) =>
      other is CellStyle &&
      other.bold == bold &&
      other.dim == dim &&
      other.italic == italic &&
      other.underline == underline &&
      other.reverse == reverse;

  @override
  int get hashCode => Object.hash(bold, dim, italic, underline, reverse);
}

/// One terminal cell: a grapheme ('' marks the continuation of a wide char),
/// colours and attributes.
final class Cell {
  final String text;
  final TuiColor? fg;
  final TuiColor? bg;
  final CellStyle attrs;

  const Cell([this.text = ' ', this.fg, this.bg, this.attrs = const CellStyle()]);

  @override
  bool operator ==(Object other) =>
      other is Cell && other.text == text && other.fg == fg && other.bg == bg && other.attrs == attrs;

  @override
  int get hashCode => Object.hash(text, fg, bg, attrs);
}

/// A writable cell grid of [width] × [height].
final class Grid {
  final int width, height;
  final List<Cell> cells;

  Grid(this.width, this.height) : cells = List<Cell>.filled(width * height, const Cell(), growable: false);

  Cell at(int x, int y) => cells[y * width + x];

  void set(int x, int y, Cell cell) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    cells[y * width + x] = cell;
  }

  /// Writes [text] at ([x], [y]) with the style; wide chars take two cells
  /// (continuation marked ''), overflow clips. Answers columns consumed.
  int write(int x, int y, String text, {TuiColor? fg, TuiColor? bg, CellStyle attrs = const CellStyle()}) {
    var cx = x;
    for (final rune in text.runes) {
      if (cx >= width) break;
      final w = charWidth(rune);
      if (w == 0) {
        // Combining mark: append to the previous cell's text.
        if (cx > x) {
          final prev = at(cx - 1, y);
          set(cx - 1, y, Cell('${prev.text}${String.fromCharCode(rune)}', prev.fg, prev.bg, prev.attrs));
        }
        continue;
      }
      set(cx, y, Cell(String.fromCharCode(rune), fg, bg, attrs));
      if (w == 2) {
        if (cx + 1 < width) set(cx + 1, y, const Cell(''));
        cx += 2;
      } else {
        cx++;
      }
    }
    return cx - x;
  }

  /// Text rows, trailing blanks trimmed: the screenshot tests assert on.
  List<String> get rows {
    final out = <String>[];
    for (var y = 0; y < height; y++) {
      final sb = StringBuffer();
      for (var x = 0; x < width; x++) {
        sb.write(at(x, y).text);
      }
      out.add(sb.toString().replaceAll(RegExp(r' +$'), ''));
    }
    return out;
  }
}

/// One changed cell: what the painter writes.
final class Change {
  final int x, y;
  final Cell cell;
  const Change(this.x, this.y, this.cell);
}

/// Cells where [next] differs from [prev] (same size), row-major. A `null`
/// [prev] means everything changed (first frame, resize).
List<Change> diff(Grid? prev, Grid next) {
  final out = <Change>[];
  for (var y = 0; y < next.height; y++) {
    for (var x = 0; x < next.width; x++) {
      // Wide continuations ride with their base cell: skip them.
      if (next.at(x, y).text == '' && x > 0 && charWidth(next.at(x - 1, y).text.runes.firstOrNull ?? 32) == 2) continue;
      if (prev == null || prev.at(x, y) != next.at(x, y)) out.add(Change(x, y, next.at(x, y)));
    }
  }
  return out;
}

/// [changes] as positioned ANSI at [level]: cursor moves (`\x1b[{r};{c}H`,
/// 1-based) with SGR runs, ending with a reset. Empty changes encode empty.
String encodeChanges(List<Change> changes, ColorLevel level) {
  if (changes.isEmpty) return '';
  final sb = StringBuffer('\x1b[0m');
  var cx = -1, cy = -1;
  String active = '';
  for (final c in changes) {
    if (c.y != cy || c.x != cx) {
      sb.write('\x1b[${c.y + 1};${c.x + 1}H');
      cy = c.y;
      cx = c.x;
    }
    final sgr = sgrFor(c.cell.fg, c.cell.bg, level, c.cell.attrs);
    if (sgr != active) {
      sb.write(sgr.isEmpty ? '\x1b[0m' : '\x1b[${sgr}m');
      active = sgr;
    }
    sb.write(c.cell.text);
    cx += c.cell.text.isEmpty ? 0 : (charWidth(c.cell.text.runes.first) == 2 ? 2 : 1);
  }
  if (active.isNotEmpty) sb.write('\x1b[0m');
  return sb.toString();
}
