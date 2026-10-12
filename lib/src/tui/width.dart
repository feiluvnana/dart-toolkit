/// Terminal column widths: how many cells a character occupies, how to fit text
/// into a width, truncate with `…`, and wrap words. The single source of truth
/// for layout; the native crate never measures (it only paints the cells Dart
/// computed), so the two can never disagree.
///
/// Wide and zero-width come from the generated tables (`width_tables.dart`,
/// Unicode 16.0.0 East_Asian_Width plus combining/format ranges); a grapheme
/// cluster (base plus combining marks, VS15/16, skin tones, ZWJ-joined runes
/// and regional-indicator pairs) is one cell, two columns when wide or
/// emoji-joined.
library;

import 'width_tables.dart';

/// Whether [c] falls in the `start, end` pair table [ranges] (binary search).
bool _inRanges(List<int> ranges, int c) {
  var lo = 0;
  var hi = ranges.length ~/ 2 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    final start = ranges[mid * 2], end = ranges[mid * 2 + 1];
    if (c < start) {
      hi = mid - 1;
    } else if (c > end) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// Columns [char] occupies on its own: 0 for control and zero-width, 2 for
/// wide, else 1. Inside a cluster only the whole cluster's width counts (see
/// [clusterWidth]).
int charWidth(int char) {
  if (char < 32 || (char >= 0x7F && char < 0xA0)) return 0;
  if (_inRanges(zeroRanges, char)) return 0;
  if (_inRanges(wideRanges, char)) return 2;
  return 1;
}

/// Regional-indicator code points pair up into flag clusters.
bool _isRI(int c) => c >= 0x1F1E6 && c <= 0x1F1FF;

/// Skin-tone modifiers join the cluster before them.
bool _isTone(int c) => c >= 0x1F3FB && c <= 0x1F3FF;

/// Whether [rune] continues the current cluster (rather than starting one).
bool _joins(int rune, {required bool prevZWJ, required bool singleRI}) =>
    _inRanges(zeroRanges, rune) || _isTone(rune) || prevZWJ || rune == 0x200D || (singleRI && _isRI(rune));

/// Splits [text] into grapheme clusters: a base rune plus its combining marks,
/// variation selectors, skin tone, ZWJ-joined runes (each side), and
/// regional-indicator pairs. A lone joiner starts its own cluster.
List<String> clusters(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  var hasBase = false;
  var prevZWJ = false;
  var singleRI = false;
  void flush() {
    if (buf.isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
  }

  for (final rune in text.runes) {
    final join = hasBase && _joins(rune, prevZWJ: prevZWJ, singleRI: singleRI);
    if (!join) {
      flush();
      singleRI = _isRI(rune);
    } else {
      singleRI = false;
    }
    prevZWJ = rune == 0x200D;
    hasBase = true;
    buf.writeCharCode(rune);
  }
  flush();
  return out;
}

/// Columns [cluster] occupies: 2 when its base is wide or it is emoji-joined
/// (ZWJ, skin tone, regional pair), else its base's width. A lone joiner is 0.
int clusterWidth(String cluster) {
  final runes = cluster.runes.iterator;
  if (!runes.moveNext()) return 0;
  final base = runes.current;
  var joined = false;
  var prevRI = _isRI(base);
  var count = 1;
  while (runes.moveNext()) {
    final r = runes.current;
    count++;
    if (r == 0x200D || _isTone(r) || (_isRI(r) && prevRI)) joined = true;
    prevRI = _isRI(r);
  }
  if (count == 1) return charWidth(base);
  if (charWidth(base) == 2 || joined) return 2;
  return charWidth(base);
}

/// Columns [text] occupies, cluster by cluster.
int textWidth(String text) {
  var w = 0;
  for (final cluster in clusters(text)) {
    w += clusterWidth(cluster);
  }
  return w;
}

/// [text] cut to at most [width] columns, ending in `…` when cut (an ellipsis
/// needs one column; a width under 2 just cuts).
String truncate(String text, int width) {
  if (width <= 0) return '';
  if (textWidth(text) <= width) return text;
  if (width == 1) return takeWidth(text, 1);
  return '${takeWidth(text, width - 1)}…';
}

/// The longest cluster prefix of [text] fitting in [width] columns.
String takeWidth(String text, int width) {
  final sb = StringBuffer();
  var w = 0;
  for (final cluster in clusters(text)) {
    final cw = clusterWidth(cluster);
    if (w + cw > width) break;
    // A zero-width cluster still rides along (it joins the previous cell).
    w += cw;
    sb.write(cluster);
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
            var piece = takeWidth(rest, width);
            if (piece.isEmpty) piece = clusters(rest).first; // wider than the row: clipped, but consumed
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
            var piece = takeWidth(rest, width);
            if (piece.isEmpty) piece = clusters(rest).first; // wider than the row: clipped, but consumed
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
