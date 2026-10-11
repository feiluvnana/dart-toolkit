import 'dom.dart';

const Set<String> _void = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', //
  'link', 'meta', 'param', 'source', 'track', 'wbr',
};

const Set<String> _rawText = {'script', 'style'};
const Set<String> _escapableRaw = {'title', 'textarea'};

/// Parses an HTML [source] into a [Doc] using a tolerant stack machine.
Doc parseHtml(String source) {
  final root = Element('#document');
  final stack = <Element>[root];
  final html = source;
  var i = 0;
  final n = html.length;

  while (i < n) {
    if (html[i] != '<') {
      final next = html.indexOf('<', i);
      final text = next == -1 ? html.substring(i) : html.substring(i, next);
      if (text.isNotEmpty) stack.last.append(TextNode(decodeEntities(text)));
      i = next == -1 ? n : next;
      continue;
    }

    if (html.startsWith('<!--', i)) {
      final end = html.indexOf('-->', i + 4);
      i = end == -1 ? n : end + 3;
      continue;
    }

    if (html.startsWith('<!', i)) {
      final end = html.indexOf('>', i);
      i = end == -1 ? n : end + 1;
      continue;
    }

    if (html.startsWith('</', i)) {
      final end = html.indexOf('>', i);
      final name = html.substring(i + 2, end == -1 ? n : end).trim().toLowerCase();
      i = end == -1 ? n : end + 1;
      for (var s = stack.length - 1; s >= 1; s--) {
        if (stack[s].tag.toLowerCase() == name) {
          stack.removeRange(s, stack.length);
          break;
        }
      }
      continue;
    }

    final end = html.indexOf('>', i);
    final rawTag = html.substring(i + 1, end == -1 ? n : end);
    final selfClose = rawTag.endsWith('/');
    final (name, attrs) = _parseTag(selfClose ? rawTag.substring(0, rawTag.length - 1) : rawTag);
    i = end == -1 ? n : end + 1;
    final el = Element(name, attrs);
    stack.last.append(el);
    final lower = name.toLowerCase();
    if (_void.contains(lower) || selfClose) continue;
    stack.add(el);

    if (_rawText.contains(lower)) {
      final closeIdx = _indexOfIgnoreCase(html, '</$lower', i);
      final text = closeIdx == -1 ? html.substring(i) : html.substring(i, closeIdx);
      if (text.isNotEmpty) el.append(TextNode(text));
      i = closeIdx == -1 ? n : closeIdx;
    } else if (_escapableRaw.contains(lower)) {
      final closeIdx = _indexOfIgnoreCase(html, '</$lower', i);
      final text = closeIdx == -1 ? html.substring(i) : html.substring(i, closeIdx);
      if (text.isNotEmpty) el.append(TextNode(decodeEntities(text)));
      i = closeIdx == -1 ? n : closeIdx;
    }
  }

  return Doc(root);
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

int _indexOfIgnoreCase(String haystack, String needle, int start) {
  final lower = haystack.toLowerCase();
  return lower.indexOf(needle.toLowerCase(), start);
}

const Map<String, String> _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'copy': '©',
  'reg': '®',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
};

/// Decodes HTML character references in [text].
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
      final code = int.tryParse(entity.substring(2), radix: 16);
      sb.write(code == null ? '&$entity;' : String.fromCharCode(code));
    } else if (entity.startsWith('#')) {
      final code = int.tryParse(entity.substring(1));
      sb.write(code == null ? '&$entity;' : String.fromCharCode(code));
    } else {
      sb.write(_entities[entity] ?? '&$entity;');
    }
    i = semi + 1;
  }
  return sb.toString();
}

/// Escapes `&`, `<`, `>` and quotes for HTML output.
String escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
