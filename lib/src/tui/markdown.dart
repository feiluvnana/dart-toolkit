// Markdown: lexer, layout, streaming memo.
part of '../tui.dart';

/// Markdown drawing for a [Region].
extension RegionMarkdown on Region {
  /// Markdown: headings, lists (nested, numbered), `>` quotes, tables
  /// (box-drawn), `---`, inline bold/italic/strike/`code`/links (OSC 8).
  /// Fenced code renders plain in the accent colour; an unclosed fence or
  /// emphasis renders as if closed (safe to stream). Layout is memoized
  /// per call site: an unchanged source is an O(1) hit,
  /// a streamed append re-lays only from the last block boundary.
  /// [color], [background] and [style] are the base under the
  /// highlighting and [on] binds events, as in `write`.
  Region markdown(
    String source, {
    Color? color,
    Color? background,
    Set<Style> style = const {},
    Map<String, Binding>? on,
  }) {
    final top = _cursor;
    for (final line in _mdLayout(source, _w, _s._caps.ascii, _s)) {
      if (_cursor >= _h) {
        _cursor++;
        continue;
      }
      var col = _gx;
      for (final seg in line) {
        col = _writeLine(_gy + _cursor, col, _gx + _w, seg.text, _s._mdStyle(seg, color, background, style), seg.link);
      }
      _cursor++;
    }
    _bindRows(on, top);
    return this;
  }
}

/// The marker colour of fenced code, drawn as the accent (see `_mdStyle`).
const _mdCode = Color.gray;

/// [url] when a click on it only browses (http, https, mailto), else null:
/// untrusted text must not hand the terminal a `file:` or app link.
String? _safeLink(String url) {
  final scheme = Uri.tryParse(url.trim())?.scheme.toLowerCase();
  return const {'http', 'https', 'mailto'}.contains(scheme) ? url.trim() : null;
}

/// Inline runs for prose [text] (bold/italic/strike/code/links).
List<_MdSeg> _mdInline(String text) {
  final out = <_MdSeg>[];
  // Code spans first (no formatting inside).
  final parts = <Object>[text];
  for (var k = 0; k < parts.length; k++) {
    final part = parts[k];
    if (part is! String) continue;
    final m = _mdCodeRe.firstMatch(part);
    if (m == null) continue;
    parts.replaceRange(k, k + 1, [
      part.substring(0, m.start),
      _MdSeg(m.group(1)!, null, null, const {Style.reverse}, null),
      part.substring(m.end),
    ]);
  }
  // Links. The text excludes '[' so each '[' scans only to the next one:
  // `[^\]]*` alone made a run of 40,000 '[' quadratic (14 s a render).
  for (var k = 0; k < parts.length; k++) {
    final part = parts[k];
    if (part is! String) continue;
    final m = _mdLinkRe.firstMatch(part);
    if (m == null) continue;
    parts.replaceRange(k, k + 1, [
      part.substring(0, m.start),
      _MdSeg(m.group(1)!, null, null, const {Style.underline}, _safeLink(m.group(2)!)),
      part.substring(m.end),
    ]);
  }
  for (final part in parts) {
    if (part is _MdSeg) {
      out.add(part);
    } else if ((part as String).isNotEmpty) {
      out.addAll(_mdEmph(part, {}));
    }
  }
  return out;
}

List<_MdSeg> _mdEmph(String text, Set<Style> base) {
  const opens = ['**', '__', '~~', '*', '_'];
  final out = <_MdSeg>[];
  var i = 0;
  var plain = StringBuffer();
  void textOut(String s) {
    if (s.isNotEmpty) out.add(_MdSeg(s, null, null, base, null));
  }

  while (i < text.length) {
    String? mark;
    for (final o in opens) {
      if (text.startsWith(o, i)) {
        mark = o;
        break;
      }
    }
    if (mark != null) {
      final prev = i > 0 ? text.codeUnitAt(i - 1) : 0x20;
      final after = i + mark.length;
      final next = after < text.length ? text.codeUnitAt(after) : 0x20;
      if (next == 0x20 || (mark[0] == '_' && _isWordChar(prev))) {
        plain.write(mark);
        i = after;
        continue;
      }
    }
    if (mark == null) {
      plain.writeCharCode(text.codeUnitAt(i));
      i++;
      continue;
    }
    final bit = switch (mark) {
      '**' || '__' => Style.bold,
      '~~' => Style.strike,
      _ => Style.italic,
    };
    // A style already on adds nothing: the mark is text. This bounds the
    // recursion at three levels; a run of 20,000 '_' nested one call each.
    if (base.contains(bit)) {
      plain.write(mark);
      i += mark.length;
      continue;
    }
    var close = text.indexOf(mark, i + mark.length);
    while (close > 0 &&
        (text.codeUnitAt(close - 1) == 0x20 ||
            (mark[0] == '_' &&
                close + mark.length < text.length &&
                _isWordChar(text.codeUnitAt(close + mark.length))))) {
      close = text.indexOf(mark, close + mark.length);
    }
    // `***x***`: the outer `**` closes at the end of the run, so the inner
    // `*` gets its own close (it rendered `x*`).
    if (close > 0 && mark.length == 2) {
      while (close + 2 < text.length && text.codeUnitAt(close + 2) == mark.codeUnitAt(0)) {
        close++;
      }
    }
    textOut(plain.toString());
    plain.clear();
    if (close < 0) {
      // Unclosed emphasis renders as if closed (streaming-safe).
      out.addAll(_mdEmph(text.substring(i + mark.length), {...base, bit}));
      i = text.length;
    } else {
      out.addAll(_mdEmph(text.substring(i + mark.length, close), {...base, bit}));
      i = close + mark.length;
    }
  }
  textOut(plain.toString());
  return out;
}

/// Wrap segments to [width] with hanging [indent] on continuations.
List<List<_MdSeg>> _mdWrap(List<_MdSeg> segs, int width, int indent) {
  final lines = <List<_MdSeg>>[];
  var line = <_MdSeg>[];
  var used = 0;
  var start = 0; // where words begin on this line
  var space = false; // the source had a space before the next word
  _MdSeg? prev; // the run the last word came from
  for (final seg in segs) {
    final words = seg.text.split(' ');
    for (var k = 0; k < words.length; k++) {
      if (k > 0) space = true;
      final word = words[k];
      if (word.isEmpty) continue;
      final w = term.displayWidth(word);
      final gap = space && used > start ? 1 : 0;
      if (used + gap + w > width && used > start) {
        lines.add(line);
        line = [];
        used = start = indent;
      } else if (gap == 1) {
        // The gap belongs to the text it sits in, never to a styled neighbour.
        line.add(
          identical(prev, seg)
              ? _MdSeg(' ', seg.fg, seg.bg, seg.style, seg.link)
              : _MdSeg(' ', null, null, const {}, null),
        );
        used++;
      }
      if (used + w <= width) {
        line.add(_MdSeg(word, seg.fg, seg.bg, seg.style, seg.link));
        used += w;
      } else {
        // Wider than a whole line (a URL, a hash): broken by cells, never
        // clipped.
        var part = StringBuffer();
        for (final rune in word.runes) {
          final rw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
          if (used + rw > width && used > start) {
            if (part.isNotEmpty) line.add(_MdSeg('$part', seg.fg, seg.bg, seg.style, seg.link));
            lines.add(line);
            line = [];
            used = start = indent;
            part = StringBuffer();
          }
          part.writeCharCode(rune);
          used += rw;
        }
        if (part.isNotEmpty) line.add(_MdSeg('$part', seg.fg, seg.bg, seg.style, seg.link));
      }
      space = false;
      prev = seg;
    }
  }
  lines.add(line);
  return lines;
}

/// Code lines keep their spaces and break at [width] cells.
List<List<_MdSeg>> _mdHard(List<_MdSeg> segs, int width) {
  final lines = <List<_MdSeg>>[];
  var line = <_MdSeg>[];
  var used = 0;
  for (final seg in segs) {
    var part = StringBuffer();
    for (final rune in seg.text.runes) {
      final w = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
      if (used + w > width && used > 0) {
        if (part.isNotEmpty) {
          line.add(_MdSeg('$part', seg.fg, seg.bg, seg.style, seg.link));
        }
        lines.add(line);
        line = [];
        used = 0;
        part = StringBuffer();
      }
      part.writeCharCode(rune);
      used += w;
    }
    if (part.isNotEmpty) {
      line.add(_MdSeg('$part', seg.fg, seg.bg, seg.style, seg.link));
    }
  }
  lines.add(line);
  return lines;
}

/// Split [source] into raw lines, dropping one trailing newline like
/// `Region.write` does, so full and incremental layouts share line space.
List<String> _mdLines(String source) {
  var src = _lf(source);
  if (src.endsWith('\n')) src = src.substring(0, src.length - 1);
  return src.split('\n');
}

/// One markdown call site's last layout (see [_mdLayout]).
final class _MdMemo {
  _MdMemo(this.src, this.width, this.ascii, this.layout, this.stableLines, this.stableOut, this.stableChar);

  String src;
  int width;
  bool ascii;
  List<List<_MdSeg>> layout;

  /// Leading raw lines of [src] forming complete blocks before the final
  /// block, and the layout lines they produced. A streamed append keeps this
  /// prefix verbatim (it is a character prefix of the new source), so only
  /// the tail from [stableLines] is re-laid.
  int stableLines;
  int stableOut;

  /// Offset in [src] where raw line [stableLines] starts: an append splits
  /// and parses only `src.substring(stableChar)`, never the whole source.
  int stableChar;
}

/// Offset just past the first [n] raw lines of [lines] (each plus its `\n`).
int _mdCharsOf(List<String> lines, int n) {
  var c = 0;
  for (var k = 0; k < n; k++) {
    c += lines[k].length + 1;
  }
  return c;
}

/// Cap on remembered call sites; more markdown widgets than this re-lay from
/// scratch each frame (still correct, just slower).
const _mdMemoCap = 8;

/// Lay out [source] at [width] into styled lines (memoized per call site).
///
/// The same string object at the same width is an O(1) [identical] hit with
/// no hashing of the text. A streamed append — the new
/// source starts with the remembered one, one prefix compare, no
/// allocation — re-lays only from the last block boundary and reuses the
/// stable prefix. Any other edit lays out from scratch, so a stale layout is
/// never reused.
List<List<_MdSeg>> _mdLayout(String source, int width, bool ascii, _Session<Object?> session) {
  final memos = session._mdMemos;
  for (var k = 0; k < memos.length; k++) {
    final m = memos[k];
    if (identical(source, m.src) && m.width == width && m.ascii == ascii) {
      if (k > 0) {
        memos.removeAt(k);
        memos.insert(0, m);
      }
      return m.layout;
    }
  }
  for (var k = 0; k < memos.length; k++) {
    final m = memos[k];
    if (m.width == width && m.ascii == ascii && source.length >= m.src.length && source.startsWith(m.src)) {
      if (source.length == m.src.length) return m.layout;
      // Only the tail from the last block boundary is split and parsed, and
      // the layout list grows in place: an append costs its tail, not the
      // whole source (streaming n chunks is linear, not quadratic).
      final raw = _mdLines(source.substring(m.stableChar));
      final tail = _mdRenderRange(raw, 0, width, ascii);
      final layout = m.layout
        ..length = m.stableOut.clamp(0, m.layout.length)
        ..addAll(tail.lines);
      final blocks = tail.blockSrc.last;
      memos[k] = _MdMemo(
        source,
        width,
        ascii,
        layout,
        m.stableLines + blocks,
        m.stableOut + tail.blockOut.last,
        m.stableChar + _mdCharsOf(raw, blocks),
      );
      return layout;
    }
  }
  final raw = _mdLines(source);
  final traced = _mdRenderRange(raw, 0, width, ascii);
  final blocks = traced.blockSrc.last;
  memos.insert(0, _MdMemo(source, width, ascii, traced.lines, blocks, traced.blockOut.last, _mdCharsOf(raw, blocks)));
  if (memos.length > _mdMemoCap) memos.removeLast();
  return traced.lines;
}

/// Render [raw] lines from [start] (a block boundary), recording where each
/// block starts in raw-line space ([blockSrc]) and in output-line space
/// ([blockOut]). Block parsing is sequential and context-free — earlier
/// blocks never depend on later lines — so rendering a suffix from a block
/// boundary matches a full render. The seeded `[start]`/`[0]` entries keep
/// `.last` total when the range is empty.
({List<List<_MdSeg>> lines, List<int> blockSrc, List<int> blockOut}) _mdRenderRange(
  List<String> raw,
  int start,
  int width,
  bool ascii,
) {
  final out = <List<_MdSeg>>[];
  final blockSrc = [start];
  final blockOut = [0];
  var i = start;
  bool blank(String s) => s.trim().isEmpty;

  while (i < raw.length) {
    blockSrc.add(i);
    blockOut.add(out.length);
    final line = raw[i];
    final trim = line.trimLeft();
    // Fenced code.
    if (trim.startsWith('```')) {
      i++;
      final code = <String>[];
      while (i < raw.length && !raw[i].trimLeft().startsWith('```')) {
        code.add(raw[i]);
        i++;
      }
      if (i < raw.length) i++; // closing fence
      // Plain, in one colour: the accent, or dim without one (_mdStyle).
      for (final cl in code) {
        out.addAll(_mdHard([_MdSeg(cl, _mdCode, null, {}, null)], width));
      }
      if (code.isEmpty) out.add([]);
      continue;
    }
    // Heading.
    final head = _mdHeadRe.firstMatch(line);
    if (head != null) {
      final styled = _mdInline(head.group(2) ?? '');
      out.addAll(
        _mdWrap(
          [
            for (final s in styled) _MdSeg(s.text, s.fg, s.bg, {...s.style, Style.bold}, s.link),
          ],
          width,
          0,
        ),
      );
      i++;
      continue;
    }
    // Rule.
    if (_mdRuleRe.hasMatch(line)) {
      out.add([_MdSeg((ascii ? '-' : '─') * math.max(1, width), null, null, {}, null)]);
      i++;
      continue;
    }
    // Quote.
    if (_mdQuoteRe.hasMatch(line)) {
      final inner = <String>[];
      while (i < raw.length && _mdQuoteRe.hasMatch(raw[i])) {
        inner.add(raw[i].replaceFirst(_mdQuoteStripRe, ''));
        i++;
      }
      for (final il in inner) {
        for (final wl in _mdWrap(_mdInline(il), width - 2, 0)) {
          out.add([
            const _MdSeg('> ', null, null, {Style.dim}, null),
            ...wl,
          ]);
        }
      }
      continue;
    }
    // Table.
    if (line.contains('|') && i + 1 < raw.length && _mdSep(raw[i + 1])) {
      final headCells = _mdCells(line);
      i += 2;
      final rows = <List<String>>[];
      while (i < raw.length && raw[i].contains('|') && !blank(raw[i])) {
        rows.add(_mdCells(raw[i]));
        i++;
      }
      out.addAll(_mdTable(headCells, rows, width, ascii));
      continue;
    }
    // List.
    final lm = _mdListRe.firstMatch(line);
    if (lm != null) {
      final items = <(int, bool, String, String)>[];
      while (i < raw.length) {
        final m = _mdListRe.firstMatch(raw[i]);
        if (m == null) break;
        final indent = m.group(1)!.replaceAll('\t', '  ').length;
        final marker = m.group(2)!;
        items.add((indent ~/ 2, _mdDigitRe.hasMatch(marker), marker, m.group(3) ?? ''));
        i++;
      }
      for (final (level, ordered, marker, text) in items) {
        final bullet = ordered ? '$marker ' : '${ascii ? '-' : '•'} ';
        final indent = level * 2;
        final pre = ' ' * indent + bullet;
        var firstLine = true;
        for (final wl in _mdWrap(_mdInline(text), width - term.displayWidth(pre), 0)) {
          out.add([_MdSeg(firstLine ? pre : ' ' * (indent + 2), null, null, {}, null), ...wl]);
          firstLine = false;
        }
      }
      continue;
    }
    // Paragraph.
    if (blank(line)) {
      i++;
      continue;
    }
    final para = <String>[];
    while (i < raw.length &&
        !blank(raw[i]) &&
        !raw[i].trimLeft().startsWith('```') &&
        _mdHeadStartRe.firstMatch(raw[i]) == null &&
        _mdRuleRe.firstMatch(raw[i]) == null &&
        _mdQuoteRe.firstMatch(raw[i]) == null &&
        _mdListStartRe.firstMatch(raw[i]) == null) {
      para.add(raw[i].trim());
      i++;
    }
    out.addAll(_mdWrap(_mdInline(para.join(' ')), width, 0));
  }
  return (lines: out, blockSrc: blockSrc, blockOut: blockOut);
}

bool _mdSep(String line) {
  final t = line.trim();
  if (!t.contains('|') || !t.contains('-')) return false;
  return _mdSepRe.hasMatch(t);
}

List<String> _mdCells(String line) {
  var cells = line.split('|').map((c) => c.trim()).toList();
  if (cells.isNotEmpty && cells.first.isEmpty) {
    cells = cells.sublist(1);
  }
  if (cells.isNotEmpty && cells.last.isEmpty) {
    cells = cells.sublist(0, cells.length - 1);
  }
  return cells;
}

List<List<_MdSeg>> _mdTable(List<String> head, List<List<String>> rows, int width, bool ascii) {
  final n = math.max(head.length, rows.fold<int>(0, (m, r) => math.max(m, r.length)));
  if (n == 0) return [];
  final widths = List<int>.filled(n, 3);
  String cell(List<String> r, int k) => k < r.length ? r[k] : '';
  for (var k = 0; k < n; k++) {
    var m = term.displayWidth(cell(head, k));
    for (final r in rows) {
      m = math.max(m, term.displayWidth(cell(r, k)));
    }
    widths[k] = math.max(3, m);
  }
  var total = widths.fold(0, (a, b) => a + b) + 3 * (n - 1) + 4;
  while (total > width) {
    var cut = -1;
    var best = 3;
    for (var k = 0; k < n; k++) {
      if (widths[k] > best) {
        best = widths[k];
        cut = k;
      }
    }
    if (cut < 0) break;
    widths[cut]--;
    total--;
  }
  final vb = ascii ? '|' : '│';
  List<_MdSeg> row(List<String> cells, Set<Style> st) {
    final segs = <_MdSeg>[_MdSeg('$vb ', null, null, {}, null)];
    for (var k = 0; k < n; k++) {
      if (k > 0) segs.add(_MdSeg(' $vb ', null, null, {}, null));
      final t = term.truncateWidth(cell(cells, k), widths[k]);
      segs.add(_MdSeg(t, null, null, st, null));
      segs.add(_MdSeg(' ' * math.max(0, widths[k] - term.displayWidth(t)), null, null, st, null));
    }
    segs.add(_MdSeg(' $vb', null, null, {}, null));
    return segs;
  }

  List<_MdSeg> rule(String l, String m, String r) {
    if (ascii) l = m = r = '+';
    final b = StringBuffer(l);
    for (var k = 0; k < n; k++) {
      if (k > 0) b.write(m);
      b.write((ascii ? '-' : '─') * (widths[k] + 2));
    }
    b.write(r);
    return [_MdSeg(b.toString(), null, null, {}, null)];
  }

  return [
    rule('┌', '┬', '┐'),
    row(head, const {Style.bold}),
    rule('├', '┼', '┤'),
    for (final r in rows) row(r, const {}),
    rule('└', '┴', '┘'),
  ];
}

final class _MdSeg {
  const _MdSeg(this.text, this.fg, this.bg, this.style, this.link);

  final String text;
  final Color? fg;
  final Color? bg;
  final Set<Style> style;
  final String? link;
}

/// Block and inline patterns, compiled once (not per line or per frame).
final _mdHeadRe = RegExp(r'^(#{1,6})\s+(.*)$');
final _mdRuleRe = RegExp(r'^\s*(---|\*\*\*|___)\s*$');
final _mdQuoteStripRe = RegExp(r'^\s*>\s?');
final _mdQuoteRe = RegExp(r'^\s*>');
final _mdListRe = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
final _mdDigitRe = RegExp(r'^\d');
final _mdHeadStartRe = RegExp(r'^(#{1,6})\s+');
final _mdListStartRe = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+');
final _mdSepRe = RegExp(r'^[\s|:\-]+$');
final _mdCodeRe = RegExp(r'`([^`\n]+)`');
final _mdLinkRe = RegExp(r'\[([^\]\[]*)\]\(((?:[^()\s]|\([^()\s]*\))+)\)'); // one level of (…) in the URL
