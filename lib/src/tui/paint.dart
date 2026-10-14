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
    animated: false);

/// A terminal colour: a 256-palette index or an RGB triple.
/// Downgraded to the terminal's level at paint time (truecolor → 256 → 16;
/// `NO_COLOR` drops colours and keeps styles).
final class Color {
  static const black = Color._(0, null);
  static const red = Color._(1, null);
  static const green = Color._(2, null);
  static const yellow = Color._(3, null);
  static const blue = Color._(4, null);
  static const magenta = Color._(5, null);
  static const cyan = Color._(6, null);
  static const white = Color._(7, null);
  static const gray = Color._(8, null);

  /// The shared live accent (see `tuiAccent256` in `src/terminal.dart`):
  /// selections, tabs and the title. Also the default [Tui.run] accent.
  static const orange = Color._(term.tuiAccent256, null);

  /// 0–255, else [ArgumentError].
  factory Color.index(int index) {
    if (index < 0 || index > 255) {
      throw ArgumentError.value(index, 'index', 'must be 0..255');
    }
    return Color._(index, null);
  }

  factory Color.rgb(int r, int g, int b) {
    for (final (n, v) in [('r', r), ('g', g), ('b', b)]) {
      if (v < 0 || v > 255) {
        throw ArgumentError.value(v, n, 'must be 0..255');
      }
    }
    return Color._(_rgbTo256(r, g, b), (r, g, b));
  }

  const Color._(this._i, this._rgb);

  final int _i;
  final (int, int, int)? _rgb;

  @override
  bool operator ==(Object other) =>
      other is Color && other._i == _i && other._rgb == _rgb;

  @override
  int get hashCode => Object.hash(_i, _rgb);
}

int _rgbTo256(int r, int g, int b) {
  if (r == g && g == b) {
    if (r < 8) return 16;
    if (r > 248) return 231;
    return 232 + ((r - 8) * 24 ~/ 247).clamp(0, 23);
  }
  int c(int v) => (v / 51).round().clamp(0, 5);
  return 16 + 36 * c(r) + 6 * c(g) + c(b);
}

/// Text styles.
enum Style { bold, dim, italic, underline, strike, reverse }
/// Human-readable byte counts and rates for the status row's bridge bars.
String _fmtSize(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _fmtRate(double bytesPerSec) {
  if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

String _fmtCount(double perSec) {
  if (perSec < 100) return perSec.toStringAsFixed(1);
  return perSec.toStringAsFixed(0);
}
final class _Cell {
  const _Cell(this.ch, this.style, this.width, {this.link});

  static const blank = _Cell(' ', 0, 1);
  static const unknown = _Cell('', -1, -1);

  final String ch;
  final int style;
  final int width;
  final String? link;

  bool get isAscii => ch.length == 1 && ch.codeUnitAt(0) < 0x7f;

  @override
  bool operator ==(Object other) =>
      other is _Cell &&
      other.ch == ch &&
      other.style == style &&
      other.width == width &&
      other.link == link;

  @override
  int get hashCode => Object.hash(ch, style, width, link);
}

final _inlineShown = Expando<List<String>>();

extension _SessionPaint on _Session<dynamic> {
    /// One grid row rendered with SGR (no cursor addressing).
    String _renderRow(List<_Cell> row) {
      final buf = StringBuffer();
      var curSgr = '';
      String? link;
      for (final c in row) {
        if (c.width == 0) continue;
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
      }
      if (link != null) buf.write('\x1b]8;;\x1b\\');
      buf.write('\x1b[0m');
      return buf.toString().trimRight();
    }

    /// Build the frame's output; null when nothing changed.
    String? _buildFrame() {
      final grid = _grid;
      var shown = _shown;
      if (_repaint || shown == null || shown.length != grid.length) {
        shown = _shown =
            List.generate(grid.length, (_) => List.filled(_w, _Cell.unknown));
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
          cx = c.isAscii ? x + 1 : -1;
        }
      }
      if (link != null) buf.write('\x1b]8;;\x1b\\');
      if (buf.isEmpty) return null;
      buf.write('\x1b[0m');
      var s = '\x1b[?2026h$buf\x1b[?2026l';
      final cur = _cursorPos;
      if (cur != null &&
          cur.$2 >= 0 &&
          cur.$2 < _w &&
          cur.$1 >= 0 &&
          cur.$1 < _h) {
        s += '\x1b[${cur.$1 + 1};${cur.$2 + 1}H\x1b[?25h';
      } else {
        s += '\x1b[?25l';
      }
      return s;
    }
  
    void _paint() {
      final s = _buildFrame();
      if (s == null) return;
      out(s);
      _lastPaint = _Session._now();
    }
  
    void _paintNow() {
      if (fullscreen) {
        _paint();
      } else {
        _paintInline();
      }
    }
  
    /// Inline live area below the shell prompt: the content's bottom slice,
    /// capped at the terminal height. Redraws in place; the cursor rests below.
    void _paintInline() {
      // Return a placed hardware cursor below the live area first.
      if (_curR >= 0) {
        out('\r\x1b[${_liveH - _curR}B');
        _curR = -1;
      }
      final contentH = math.max(_usedRows, 1);
      // One row short of the terminal: the parking newline below must never
      // scroll the live area's top row into the scrollback.
      final liveH = math.min(contentH, math.max(1, _h - 1));
      final first = contentH - liveH;
      final prev = _inlineShown[this];
      final same = !_repaint && prev != null && _liveH == liveH;
      _repaint = false;
      final rows = [
        for (var r = 0; r < liveH; r++)
          first + r < _grid.length ? _renderRow(_grid[first + r]) : '',
      ];
      final buf = StringBuffer('\x1b[?2026h');
      if (_liveH > 0) buf.write('\r\x1b[${_liveH}A');
      for (var r = 0; r < liveH; r++) {
        if (!same || prev[r] != rows[r]) buf.write('\r\x1b[2K${rows[r]}');
        if (r + 1 < liveH) buf.write('\n');
      }
      _inlineShown[this] = rows;
      // Park below the live area, then erase any stale lines from a shrink.
      buf.write('\n\x1b[J\x1b[?2026l');
      out(buf.toString());
      _liveH = liveH;
      _lastPaint = _Session._now();
      // Cursor placement for a focused input, relative to the live area.
      final cur = _cursorPos;
      if (cur != null) {
        // _cursorPos is absolute (fullscreen math); inline draws the bottom
        // slice, so rebase rows that fall inside it.
        final rel = cur.$1 - first;
        if (rel >= 0 && rel < liveH && cur.$2 >= 0 && cur.$2 < _w) {
          out('\x1b[${liveH - rel}A\r');
          if (cur.$2 > 0) out('\x1b[${cur.$2}C');
          out('\x1b[?25h');
          _curR = rel;
          return;
        }
      }
      out('\x1b[?25l');
      _curR = -1;
    }
  
    bool _paintTo(StringBuffer sink) {
      final s = _buildFrame();
      if (s == null) return false;
      sink.write(s);
      _lastPaint = _Session._now();
      return true;
    }
  
    String _sgrFor(_Cell c) {
      final (fg, bg, bits) = _unpack(c.style);
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
      if (_caps.truecolor && col._rgb != null) {
        final (r, g, b) = col._rgb;
        return bg ? ';48;2;$r;$g;$b' : ';38;2;$r;$g;$b';
      }
      if (_caps.truecolor || _caps.color256) {
        return bg ? ';48;5;${col._i}' : ';38;5;${col._i}';
      }
      return ';${_basic(col._i, bg)}';
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
