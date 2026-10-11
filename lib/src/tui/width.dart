/// Terminal column widths: how many cells a character occupies, how to fit text
/// into a width, truncate with `…`, and wrap words. The single source of truth
/// for layout; the native crate never measures (it only paints the cells Dart
/// computed), so the two can never disagree.
///
/// Wide ranges follow Unicode East-Asian Wide/Fullwidth plus emoji
/// presentation blocks; everything else unassigned or control is 0, else 1.
/// Combining marks are 0 (they join the previous cell).
library;

/// Columns [char] occupies: 0 for combining/control, 2 for wide, else 1.
int charWidth(int char) {
  if (char < 32 || (char >= 0x7F && char < 0xA0)) return 0;
  if (char >= 0x300 && char <= 0x36F) return 0; // combining diacriticals
  if (char >= 0x200B && char <= 0x200F) return 0; // zero-width + marks
  if (char >= 0xFE00 && char <= 0xFE0F) return 0; // variation selectors
  if (char == 0xFEFF) return 0;
  if (_isWide(char)) return 2;
  return 1;
}

bool _isWide(int c) {
  // CJK + Hangul + fullwidth forms.
  if (c >= 0x1100 && c <= 0x115F) return true;
  if (c >= 0x2E80 && c <= 0x303E) return true;
  if (c >= 0x3041 && c <= 0x33FF) return true;
  if (c >= 0x3400 && c <= 0x4DBF) return true;
  if (c >= 0x4E00 && c <= 0x9FFF) return true;
  if (c >= 0xA000 && c <= 0xA4CF) return true;
  if (c >= 0xAC00 && c <= 0xD7A3) return true;
  if (c >= 0xF900 && c <= 0xFAFF) return true;
  if (c >= 0xFE30 && c <= 0xFE4F) return true;
  if (c >= 0xFF00 && c <= 0xFF60) return true;
  if (c >= 0xFFE0 && c <= 0xFFE6) return true;
  if (c >= 0x20000 && c <= 0x3FFFD) return true;
  // Emoji presentation blocks.
  if (c >= 0x1F300 && c <= 0x1FAFF) return true;
  if (c >= 0x1F000 && c <= 0x1F2FF) return true;
  if (c >= 0x2600 && c <= 0x26FF) return true;
  if (c >= 0x2700 && c <= 0x27BF) return true;
  if (c >= 0x2B00 && c <= 0x2BFF) return true;
  if (c == 0x231A || c == 0x231B || (c >= 0x23E9 && c <= 0x23F3)) return true;
  if (c >= 0x1F1E6 && c <= 0x1F1FF) return true; // regional indicators
  return false;
}

/// Columns [text] occupies (combining marks join their base for free).
int textWidth(String text) {
  var w = 0;
  for (final c in text.runes) {
    w += charWidth(c);
  }
  return w;
}

/// [text] cut to at most [width] columns, ending in `…` when cut (an ellipsis
/// needs one column; a width under 2 just cuts).
String truncate(String text, int width) {
  if (width <= 0) return '';
  if (textWidth(text) <= width) return text;
  if (width == 1) return _takeWidth(text, 1);
  return '${_takeWidth(text, width - 1)}…';
}

/// The longest prefix of [text] fitting in [width] columns.
String _takeWidth(String text, int width) {
  final sb = StringBuffer();
  var w = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    // Keep surrogate pairs whole; combining marks ride along.
    var rune = c;
    var next = i + 1;
    if (c >= 0xD800 && c <= 0xDBFF && next < text.length) {
      final lo = text.codeUnitAt(next);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        rune = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
        next++;
      }
    }
    final cw = charWidth(rune);
    if (w + cw > width) break;
    w += cw;
    sb.write(String.fromCharCode(rune));
    // A wide char that ends exactly at the edge is fine; a following combining
    // mark still fits (zero width).
    i = next - 1;
  }
  return sb.toString();
}

/// [text] wrapped to lines of at most [width] columns, preferring word breaks;
/// a single overlong word is hard-cut. Empty lines stay empty.
List<String> wrap(String text, int width) {
  if (width <= 0) return [''];
  final out = <String>[];
  for (final paragraph in text.split('\n')) {
    if (paragraph.isEmpty) {
      out.add('');
      continue;
    }
    final words = paragraph.split(' ');
    var line = StringBuffer();
    var w = 0;
    void flush() {
      out.add(line.toString());
      line = StringBuffer();
      w = 0;
    }

    for (final word in words) {
      if (word.isEmpty) continue;
      final ww = textWidth(word);
      if (w == 0) {
        if (ww <= width) {
          line.write(word);
          w = ww;
        } else {
          // Hard-cut the overlong word across lines.
          var rest = word;
          while (textWidth(rest) > width) {
            final piece = _takeWidth(rest, width);
            out.add(piece);
            rest = rest.substring(piece.length);
          }
          line.write(rest);
          w = textWidth(rest);
        }
      } else if (w + 1 + ww <= width) {
        line.write(' $word');
        w += 1 + ww;
      } else {
        flush();
        if (ww <= width) {
          line.write(word);
          w = ww;
        } else {
          var rest = word;
          while (textWidth(rest) > width) {
            final piece = _takeWidth(rest, width);
            out.add(piece);
            rest = rest.substring(piece.length);
          }
          line.write(rest);
          w = textWidth(rest);
        }
      }
    }
    flush();
  }
  return out;
}
