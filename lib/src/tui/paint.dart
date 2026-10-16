// Paint: cells, diffed flush, colour downgrade.
part of '../tui.dart';

/// Fallback capabilities for the in-memory harness and for sessions before
/// the first real draw: colours on, UTF-8 glyphs. The live session replaces
/// this with [term.TerminalCaps] detected from the environment on every draw.
const _fallbackCaps = term.TerminalCaps(
  truecolor: false,
  color256: true,
  noColor: false,
  ascii: false,
  styled: true,
  animated: false,
);

/// [s] with CRLF line ends as `\n` (the `\r` would draw as a replacement
/// glyph); a lone `\r` stays a control character.
String _lf(String s) => s.contains('\r\n') ? s.replaceAll('\r\n', '\n') : s;

/// Text styles.
enum Style {
  /// Bold.
  bold,

  /// Dim (faint).
  dim,

  /// Italic.
  italic,

  /// Underlined.
  underline,

  /// Struck through.
  strike,

  /// Foreground and background swapped.
  reverse,
}

final class _Cell {
  const _Cell(this.ch, this.style, this.width, {this.link});

  static const blank = _Cell(' ', 0, 1);
  static const unknown = _Cell('', -1, -1);

  final String ch;
  final int style;
  final int width;
  final String? link;

  /// The terminal cursor ends where this cell says: ASCII, box drawing and
  /// block elements (the frames and bars), and wide CJK, kana, Hangul and
  /// fullwidth forms. Emoji, marks and ambiguous-width text re-sync with a
  /// cursor move after them.
  bool get flows {
    if (ch.length != 1) return false;
    final c = ch.codeUnitAt(0);
    if (c < 0x7f) return true;
    if (c >= 0x2500 && c <= 0x259F) return width == 1;
    return width == 2 &&
        ((c >= 0x1100 && c <= 0x115F) ||
            (c >= 0x2E80 && c <= 0xA4CF) ||
            (c >= 0xAC00 && c <= 0xD7A3) ||
            (c >= 0xF900 && c <= 0xFAFF) ||
            (c >= 0xFF00 && c <= 0xFF60));
  }

  @override
  bool operator ==(Object other) =>
      other is _Cell && other.ch == ch && other.style == style && other.width == width && other.link == link;

  @override
  int get hashCode => Object.hash(ch, style, width, link);
}

extension _SessionPaint on _Session<dynamic> {
  /// Build the frame's output; null when nothing changed.
  String? _buildFrame() {
    final grid = _grid;
    var shown = _shown;
    if (_repaint || shown == null || shown.length != grid.length) {
      shown = _shown = List.generate(grid.length, (_) => List.filled(_w, _Cell.unknown));
      _repaint = false;
    }
    final buf = StringBuffer();
    var curSgr = '';
    String? link;
    for (var y = 0; y < grid.length && y < _h; y++) {
      final row = grid[y];
      final was = y < shown.length ? shown[y] : null;
      var cx = -1;
      for (var x = 0; x < row.length && x < _w; x++) {
        final c = row[x];
        if (c.width == 0) continue;
        if (was != null && x < was.length && c == was[x]) continue;
        if (x != cx) buf.write('\x1b[${y + 1};${x + 1}H');
        final sgr = _sgrFor(c);
        if (sgr != curSgr) {
          buf.write(sgr);
          curSgr = sgr;
        }
        if (c.link != link) {
          if (link != null) buf.write('\x1b]8;;\x1b\\');
          link = c.link;
          if (link != null) buf.write('\x1b]8;;$link\x1b\\');
        }
        buf.write(c.ch.isEmpty ? ' ' : c.ch);
        if (was != null && x < was.length) {
          was[x] = c;
          if (c.width == 2 && x + 1 < was.length && x + 1 < row.length) {
            was[x + 1] = row[x + 1];
          }
        }
        cx = c.flows ? x + c.width : -1;
      }
    }
    if (link != null) buf.write('\x1b]8;;\x1b\\');
    final cur = _cursorPos;
    final cursor = cur != null && cur.$2 >= 0 && cur.$2 < _w && cur.$1 >= 0 && cur.$1 < _h
        ? '\x1b[${cur.$1 + 1};${cur.$2 + 1}H\x1b[?25h'
        : '\x1b[?25l';
    // A cursor move with no cell change (arrows in an input) still paints.
    if (buf.isEmpty) {
      if (cursor == _shownCursor) return null;
      return _shownCursor = cursor;
    }
    _shownCursor = cursor;
    buf.write('\x1b[0m');
    return '\x1b[?2026h$buf\x1b[?2026l$cursor';
  }

  void _paint() {
    if (_suspending) return; // the terminal is the shell's until the stop
    final s = _buildFrame();
    if (s == null) return;
    out(s);
    _lastPaint = _Session._now();
  }

  bool _paintTo(StringBuffer sink) {
    final s = _buildFrame();
    if (s == null) return false;
    sink.write(s);
    _lastPaint = _Session._now();
    return true;
  }

  String _sgrFor(_Cell c) {
    if (!identical(_sgrCaps, _caps)) {
      _sgrCache.clear();
      _sgrCaps = _caps;
    }
    return _sgrCache[c.style] ??= _buildSgr(c.style);
  }

  String _buildSgr(int style) {
    final (fg, bg, bits) = _unpack(style);
    final b = StringBuffer('\x1b[0');
    if (bits & 1 != 0) b.write(';1');
    if (bits & 2 != 0) b.write(';2');
    if (bits & 4 != 0) b.write(';3');
    if (bits & 8 != 0) b.write(';4');
    if (bits & 16 != 0) b.write(';9');
    if (bits & 32 != 0) b.write(';7');
    if (!_caps.noColor) {
      b.write(_colorSgr(fg, false));
      b.write(_colorSgr(bg, true));
    }
    b.write('m');
    return b.toString();
  }

  String _colorSgr(Color? col, bool bg) {
    if (col == null) return '';
    if (_caps.truecolor && term.colorRgb(col) != null) {
      final (r, g, b) = term.colorRgb(col)!;
      return bg ? ';48;2;$r;$g;$b' : ';38;2;$r;$g;$b';
    }
    if (_caps.truecolor || _caps.color256) {
      return bg ? ';48;5;${term.colorCode(col)}' : ';38;5;${term.colorCode(col)}';
    }
    return ';${_basic(term.colorCode(col), bg)}';
  }

  static int _basic(int i, bool bg) {
    int c;
    if (i < 16) {
      c = i;
    } else if (i >= 232) {
      c = i < 244 ? 0 : 7;
    } else {
      final v = i - 16;
      final r = v ~/ 36, g = (v % 36) ~/ 6, bl = v % 6;
      final m = math.max(r, math.max(g, bl));
      if (m == 0) {
        c = 0;
      } else if (r == m && g == m && bl == m) {
        c = 7;
      } else if (r == m && g == m) {
        c = 3;
      } else if (r == m && bl == m) {
        c = 5;
      } else if (g == m && bl == m) {
        c = 6;
      } else if (r == m) {
        c = 1;
      } else if (g == m) {
        c = 2;
      } else {
        c = 4;
      }
      if (m >= 3) c += 8;
    }
    if (c < 8) return (bg ? 40 : 30) + c;
    return (bg ? 100 : 90) + (c - 8);
  }
}

/// Draw the one-cell border of `[top, bottom] x [left, right]` through [put].
void _frame(bool ascii, int top, int left, int bottom, int right, void Function(int y, int x, String ch) put) {
  final (hz, vt, tl, tr, bl, br) = ascii ? ('-', '|', '+', '+', '+', '+') : ('─', '│', '┌', '┐', '└', '┘');
  for (var x = left; x <= right; x++) {
    put(top, x, hz);
    put(bottom, x, hz);
  }
  for (var y = top; y <= bottom; y++) {
    put(y, left, vt);
    put(y, right, vt);
  }
  put(top, left, tl);
  put(top, right, tr);
  put(bottom, left, bl);
  put(bottom, right, br);
}
