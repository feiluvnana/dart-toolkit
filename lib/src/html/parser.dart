part of 'dom.dart';

const Set<String> _void = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', //
  'link', 'meta', 'param', 'source', 'track', 'wbr',
};

const Set<String> _rawText = {'script', 'style'};
const Set<String> _escapableRaw = {'title', 'textarea'};

/// One open element: its tag, attributes and child nodes so far. The parser
/// collects mutable lists here; [assembleDocument] freezes them into a [Doc].
final class _Frame {
  final String tag;
  final Map<String, String> attrs;
  final List<Node> kids = [];

  _Frame(this.tag, this.attrs);

  /// This frame frozen into an [Element]. Nobody's parent is wired yet:
  /// [assembleDocument] wires the whole tree once, after implying structure.
  Element freeze() => Element._(tag, attrs, kids);
}

/// Parses an HTML [source] into a [Doc] using a tolerant stack machine.
Doc parseHtml(String source) {
  final root = _Frame('#document', {});
  final stack = <_Frame>[root];
  final html = source;
  var i = 0;
  final n = html.length;
  String? doctype;

  Element closeFrame(_Frame frame) => frame.freeze();

  void closeTo(String name) {
    var s = stack.length - 1;
    while (s >= 1 && stack[s].tag.toLowerCase() != name) {
      s--;
    }
    if (s < 1) return; // no match: stray closer, ignored
    while (stack.length > s) {
      final shut = closeFrame(stack.removeLast());
      stack.last.kids.add(shut);
    }
  }

  while (i < n) {
    if (html[i] != '<') {
      final next = html.indexOf('<', i);
      final text = next == -1 ? html.substring(i) : html.substring(i, next);
      if (text.isNotEmpty) stack.last.kids.add(Text(decodeEntities(text)));
      i = next == -1 ? n : next;
      continue;
    }

    // A tag starts only at `<` followed by a letter, `/`, `!` or `?`.
    // Anything else (`< 2`, `a<b` without intent) is literal text.
    if (i + 1 >= n || !_tagStart(html[i + 1])) {
      stack.last.kids.add(Text('<'));
      i++;
      continue;
    }

    if (html.startsWith('<!--', i)) {
      final end = html.indexOf('-->', i + 4);
      i = end == -1 ? n : end + 3;
      continue;
    }

    if (_doctypeAt(html, i)) {
      final end = html.indexOf('>', i);
      doctype ??= html.substring(i, end == -1 ? n : end + 1);
      i = end == -1 ? n : end + 1;
      continue;
    }

    if (html.startsWith('<!', i) || html.startsWith('<?', i)) {
      final end = html.indexOf('>', i);
      i = end == -1 ? n : end + 1;
      continue;
    }

    if (html.startsWith('</', i)) {
      final end = html.indexOf('>', i);
      final name = html.substring(i + 2, end == -1 ? n : end).trim().toLowerCase();
      i = end == -1 ? n : end + 1;
      closeTo(name);
      continue;
    }

    // The tag scan skips quoted attribute values, so `<a title="x>y">` ends
    // at its real closer.
    final end = _tagEnd(html, i);
    final rawTag = html.substring(i + 1, end == -1 ? n : end);
    final selfClose = rawTag.endsWith('/');
    final (name, attrs) = _parseTag(selfClose ? rawTag.substring(0, rawTag.length - 1) : rawTag);
    i = end == -1 ? n : end + 1;
    _autoClose(stack, name);
    final frame = _Frame(name, attrs);
    final lower = name.toLowerCase();
    if (_void.contains(lower) || selfClose) {
      stack.last.kids.add(closeFrame(frame));
      continue;
    }
    stack.add(frame);

    if (_rawText.contains(lower)) {
      final closeIdx = _indexOfIgnoreCase(html, '</$lower', i);
      final text = closeIdx == -1 ? html.substring(i) : html.substring(i, closeIdx);
      if (text.isNotEmpty) frame.kids.add(Text(text));
      i = closeIdx == -1 ? n : closeIdx;
    } else if (_escapableRaw.contains(lower)) {
      final closeIdx = _indexOfIgnoreCase(html, '</$lower', i);
      final text = closeIdx == -1 ? html.substring(i) : html.substring(i, closeIdx);
      if (text.isNotEmpty) frame.kids.add(Text(decodeEntities(text)));
      i = closeIdx == -1 ? n : closeIdx;
    }
  }

  // Frames left open at the end close in order, innermost first.
  while (stack.length > 1) {
    final shut = closeFrame(stack.removeLast());
    stack.last.kids.add(shut);
  }
  return assembleDocument(root.kids, doctype);
}

/// Whether [c] can start a tag after `<`: a letter, `/`, `!` or `?`.
bool _tagStart(String c) =>
    (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90) ||
    (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122) ||
    c == '/' ||
    c == '!' ||
    c == '?';

/// Whether a `<!DOCTYPE …>` (any case) starts at [i].
bool _doctypeAt(String html, int i) => i + 9 <= html.length && html.substring(i, i + 9).toLowerCase() == '<!doctype';

/// The `>` closing the tag at [i], skipping quoted attribute values; -1 when
/// the tag never closes.
int _tagEnd(String html, int i) {
  var j = i + 1;
  String? quote;
  while (j < html.length) {
    final c = html[j];
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '>') {
      return j;
    }
    j++;
  }
  return -1;
}

/// Closes elements the HTML standard auto-closes: an open `<li>` before the
/// next `<li>`, an open `<p>` before block starts, open cells before the next
/// cell or row, an open row before the next row.
void _autoClose(List<_Frame> stack, String name) {
  String top() => stack.length > 1 ? stack.last.tag.toLowerCase() : '';
  void popTop() {
    if (stack.length > 1) {
      final shut = stack.removeLast().freeze();
      stack.last.kids.add(shut);
    }
  }

  switch (name.toLowerCase()) {
    case 'li':
      if (top() == 'li') popTop();
    case 'p':
      if (top() == 'p') popTop();
    case 'td' || 'th':
      if (top() == 'td' || top() == 'th') popTop();
    case 'tr':
      while (top() == 'td' || top() == 'th' || top() == 'tr') {
        popTop();
      }
    case 'tbody' || 'thead' || 'tfoot':
      while (top() == 'td' ||
          top() == 'th' ||
          top() == 'tr' ||
          top() == 'tbody' ||
          top() == 'thead' ||
          top() == 'tfoot') {
        popTop();
      }
    case 'div' ||
        'h1' ||
        'h2' ||
        'h3' ||
        'h4' ||
        'h5' ||
        'h6' ||
        'ul' ||
        'ol' ||
        'dl' ||
        'table' ||
        'blockquote' ||
        'pre' ||
        'hr' ||
        'section' ||
        'article':
      if (top() == 'p') popTop();
  }
}

(String, Map<String, String>) _parseTag(String src) {
  final s = src.trim();
  final nameMatch = RegExp(r'^[A-Za-z0-9:_\-]+').firstMatch(s);
  final name = (nameMatch?.group(0) ?? '').toLowerCase();
  final attrs = <String, String>{};
  var i = nameMatch?.end ?? 0;
  while (i < s.length) {
    while (i < s.length && _isSpace(s[i])) {
      i++;
    }
    if (i >= s.length) break;
    final nm = RegExp(r'[^\s=/>]+').matchAsPrefix(s, i);
    if (nm == null) {
      i++;
      continue;
    }
    final attrName = nm.group(0)!.toLowerCase();
    i = nm.end;
    while (i < s.length && _isSpace(s[i])) {
      i++;
    }
    var value = '';
    if (i < s.length && s[i] == '=') {
      i++;
      while (i < s.length && _isSpace(s[i])) {
        i++;
      }
      if (i < s.length && (s[i] == '"' || s[i] == "'")) {
        final quote = s[i];
        i++;
        final start = i;
        while (i < s.length && s[i] != quote) {
          i++;
        }
        value = s.substring(start, i);
        if (i < s.length) i++;
      } else {
        final vm = RegExp(r'[^\s>]+').matchAsPrefix(s, i);
        if (vm != null) {
          value = vm.group(0)!;
          i = vm.end;
        }
      }
    }
    attrs[attrName] = decodeEntities(value);
  }
  return (name, attrs);
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';

/// Case-insensitive [needle] (already lowercase, starting with `</`) in
/// [haystack] from [start], compared in place at each `<`: lowercasing the
/// whole document per script/style element is quadratic.
int _indexOfIgnoreCase(String haystack, String needle, int start) {
  var i = haystack.indexOf('<', start);
  while (i != -1) {
    if (i + 1 < haystack.length && haystack[i + 1] == '/') {
      var j = 2;
      while (j < needle.length) {
        if (i + j >= haystack.length) return -1;
        if (_lowerAscii(haystack.codeUnitAt(i + j)) != needle.codeUnitAt(j)) break;
        j++;
      }
      if (j == needle.length) return i;
    }
    i = haystack.indexOf('<', i + 1);
  }
  return -1;
}

/// ASCII lowercase of [c].
int _lowerAscii(int c) => c >= 65 && c <= 90 ? c + 32 : c;

/// Decodes HTML character references in [text]: the full named table, plus
/// numeric references. An invalid or out-of-range code point, or a lone
/// surrogate, becomes U+FFFD instead of throwing.
String decodeEntities(String text) {
  if (!text.contains('&')) return text;
  final sb = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final amp = text.indexOf('&', i);
    if (amp == -1) {
      sb.write(text.substring(i));
      break;
    }
    sb.write(text.substring(i, amp));
    final semi = text.indexOf(';', amp);
    if (semi == -1 || semi - amp > 12) {
      sb.write('&');
      i = amp + 1;
      continue;
    }
    final entity = text.substring(amp + 1, semi);
    if (entity.startsWith('#x') || entity.startsWith('#X')) {
      sb.write(_fromCode(int.tryParse(entity.substring(2), radix: 16), entity));
    } else if (entity.startsWith('#')) {
      sb.write(_fromCode(int.tryParse(entity.substring(1)), entity));
    } else {
      sb.write(htmlEntities[entity] ?? '&$entity;');
    }
    i = semi + 1;
  }
  return sb.toString();
}

/// [code] as a character, or U+FFFD when it is missing ([literal] has no
/// number), NUL, out of range, or a lone surrogate.
String _fromCode(int? code, String entity) {
  if (code == null) return '&$entity;';
  if (code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return '�';
  return String.fromCharCode(code);
}

/// Escapes `&`, `<`, `>` and quotes for HTML output.
String escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
