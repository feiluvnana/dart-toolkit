/// A tag-soup HTML parser: one pass, no HTML5 insertion modes, the implicit closes and
/// synthesised elements a scraper meets in practice.
library;

import 'dom.dart';

/// Elements with no content and no end tag.
const voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr', //
  'basefont', 'bgsound', 'frame', 'keygen', 'command',
};

/// Elements whose content is raw text up to their end tag, entities left alone.
const rawTextElements = {'script', 'style', 'xmp', 'iframe', 'noembed', 'noframes'};

/// Elements whose content is text up to their end tag, entities decoded.
const _rcdataElements = {'textarea', 'title'};

/// Elements that belong in `<head>` when they appear before any body content.
const _headElements = {'title', 'meta', 'link', 'style', 'script', 'base', 'noscript', 'template'};

/// Start tags that close an open `<p>`.
const _closesP = {
  'address', 'article', 'aside', 'blockquote', 'details', 'dialog', 'div', 'dl', 'fieldset', 'figcaption', //
  'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr', 'main', 'menu',
  'nav', 'ol', 'p', 'pre', 'section', 'table', 'ul', 'li', 'dt', 'dd',
};

/// A start tag that closes an open element of the same group: `<li>` after `<li>`, `<td>`
/// after `<th>`. Keyed by the incoming tag, valued by what it closes and the boundary it
/// stops at.
const _closesSibling = <String, (Set<String>, Set<String>)>{
  'li': ({'li'}, {'ul', 'ol', 'menu'}),
  'dt': ({'dt', 'dd'}, {'dl'}),
  'dd': ({'dt', 'dd'}, {'dl'}),
  'tr': ({'tr'}, {'table', 'thead', 'tbody', 'tfoot'}),
  'td': ({'td', 'th'}, {'tr', 'table'}),
  'th': ({'td', 'th'}, {'tr', 'table'}),
  'thead': ({'thead', 'tbody', 'tfoot'}, {'table'}),
  'tbody': ({'thead', 'tbody', 'tfoot'}, {'table'}),
  'tfoot': ({'thead', 'tbody', 'tfoot'}, {'table'}),
  'option': ({'option'}, {'select', 'datalist', 'optgroup'}),
  'optgroup': ({'optgroup', 'option'}, {'select'}),
  'rt': ({'rt', 'rp'}, {'ruby'}),
  'rp': ({'rt', 'rp'}, {'ruby'}),
};

/// Parses [source] into an `<html>` element with `<head>` and `<body>`.
Element parseHtml(String source) => _Parser(source).run();

final class _Parser {
  final String src;
  final Element html = Element('html');
  late final Element head = Element('head');
  Element? body;
  final List<Element> open = [];
  int pos = 0;

  /// CR LF and a lone CR read as LF, as the HTML input stream does.
  _Parser(String source)
    : src = source.contains('\r') ? source.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : source {
    open.add(html);
  }

  Element run() {
    html.nodes.add(head..parent = html);
    while (pos < src.length) {
      final lt = src.indexOf('<', pos);
      if (lt == -1) {
        text(src.substring(pos));
        break;
      }
      if (lt > pos) text(src.substring(pos, lt));
      pos = lt;
      if (!tag()) {
        text('<');
        pos++;
      }
    }
    ensureBody();
    return html;
  }

  Element get current => open.last;

  bool get inBody => body != null && open.contains(body);

  void ensureBody() {
    if (body != null) return;
    body = Element('body')..parent = html;
    html.nodes.add(body!);
    // Whatever was open before the body — nothing legitimate — is abandoned.
    open
      ..clear()
      ..add(html)
      ..add(body!);
  }

  void text(String raw) {
    if (body == null) {
      if (raw.trim().isEmpty) return;
      if (open.length > 1 && open.last != head) {
        // Text inside a head element such as <title> stays there.
      } else {
        ensureBody();
      }
    }
    final target = current;
    final data = decodeEntities(raw);
    if (target.nodes.lastOrNull case final Text last) {
      target.nodes[target.nodes.length - 1] = Text(last.data + data)..parent = target;
    } else {
      target.nodes.add(Text(data)..parent = target);
    }
  }

  /// Consumes the markup at [pos] (which is `<`); returns false when it is not markup.
  bool tag() {
    final n = pos + 1;
    if (n >= src.length) return false;
    final c = src.codeUnitAt(n);
    if (c == 0x21) return declaration(); // !
    if (c == 0x3f) return skipTo('>'); // ?
    if (c == 0x2f) return endTag(); // /
    if (!_isAlpha(c)) return false;
    return startTag();
  }

  bool declaration() {
    if (src.startsWith('<!--', pos)) {
      final end = src.indexOf('-->', pos + 4);
      pos = end == -1 ? src.length : end + 3;
      return true;
    }
    if (src.startsWith('<![CDATA[', pos)) {
      final end = src.indexOf(']]>', pos + 9);
      text(src.substring(pos + 9, end == -1 ? src.length : end));
      pos = end == -1 ? src.length : end + 3;
      return true;
    }
    return skipTo('>'); // <!DOCTYPE …> and anything else declarative
  }

  bool skipTo(String close) {
    final end = src.indexOf(close, pos);
    pos = end == -1 ? src.length : end + close.length;
    return true;
  }

  bool endTag() {
    var i = pos + 2;
    final start = i;
    while (i < src.length && _isNameChar(src.codeUnitAt(i))) {
      i++;
    }
    if (i == start) return false;
    final name = src.substring(start, i).toLowerCase();
    final gt = src.indexOf('>', i);
    pos = gt == -1 ? src.length : gt + 1;
    if (name == 'br') {
      insert(Element('br'), selfClosing: true);
      return true;
    }
    if (name == 'body' || name == 'html' || name == 'head') return true; // closed at the end anyway
    if (name == 'p' && !open.any((e) => e.name == 'p')) {
      // A stray </p> is an empty paragraph, as in a browser.
      ensureBody();
      insert(Element('p'), selfClosing: true);
      return true;
    }
    closeTo(name);
    return true;
  }

  /// Pops open elements up to and including the nearest [name]; nothing if it is not open.
  void closeTo(String name) {
    for (var i = open.length - 1; i > 0; i--) {
      if (open[i].name == name) {
        open.removeRange(i, open.length);
        return;
      }
    }
  }

  bool startTag() {
    var i = pos + 1;
    final start = i;
    while (i < src.length && _isNameChar(src.codeUnitAt(i))) {
      i++;
    }
    final name = src.substring(start, i).toLowerCase();
    final attributes = <String, String>{};
    var selfClosing = false;

    // Attributes.
    while (true) {
      while (i < src.length && _isSpace(src.codeUnitAt(i))) {
        i++;
      }
      if (i >= src.length) break;
      final c = src.codeUnitAt(i);
      if (c == 0x3e) {
        i++;
        break;
      }
      if (c == 0x2f) {
        // `/` — self-closing marker or noise.
        i++;
        if (i < src.length && src.codeUnitAt(i) == 0x3e) {
          selfClosing = true;
          i++;
          break;
        }
        continue;
      }
      final nameStart = i;
      while (i < src.length) {
        final d = src.codeUnitAt(i);
        if (_isSpace(d) ||
            d == 0x3d ||
            d == 0x3e ||
            (d == 0x2f && i + 1 < src.length && src.codeUnitAt(i + 1) == 0x3e)) {
          break;
        }
        i++;
      }
      if (i == nameStart) {
        i++; // a stray character
        continue;
      }
      final attrName = src.substring(nameStart, i).toLowerCase();
      while (i < src.length && _isSpace(src.codeUnitAt(i))) {
        i++;
      }
      var value = '';
      if (i < src.length && src.codeUnitAt(i) == 0x3d) {
        i++;
        while (i < src.length && _isSpace(src.codeUnitAt(i))) {
          i++;
        }
        if (i < src.length) {
          final q = src.codeUnitAt(i);
          if (q == 0x22 || q == 0x27) {
            final end = src.indexOf(String.fromCharCode(q), i + 1);
            value = src.substring(i + 1, end == -1 ? src.length : end);
            i = end == -1 ? src.length : end + 1;
          } else {
            final valueStart = i;
            while (i < src.length) {
              final d = src.codeUnitAt(i);
              if (_isSpace(d) || d == 0x3e) break;
              i++;
            }
            value = src.substring(valueStart, i);
          }
        }
      }
      attributes.putIfAbsent(attrName, () => decodeEntities(value));
    }
    pos = i;

    if (name == 'html') {
      for (final e in attributes.entries) {
        html.attributes.putIfAbsent(e.key, () => e.value);
      }
      return true;
    }
    if (name == 'head') {
      if (body == null) {
        head.attributes.addAll(attributes);
        open
          ..clear()
          ..add(html)
          ..add(head);
      }
      return true;
    }
    if (name == 'body') {
      ensureBody();
      for (final e in attributes.entries) {
        body!.attributes.putIfAbsent(e.key, () => e.value);
      }
      return true;
    }

    final element = Element(name, attributes);
    if (body == null) {
      if (_headElements.contains(name)) {
        if (!open.contains(head)) {
          open
            ..clear()
            ..add(html)
            ..add(head);
        }
      } else {
        ensureBody();
      }
    }
    insert(element, selfClosing: selfClosing);
    return true;
  }

  void insert(Element element, {required bool selfClosing}) {
    final name = element.name;
    if (_closesP.contains(name)) closeInScope({'p'}, _blockBoundaries);
    if (_closesSibling[name] case (final closes, final boundary)?) closeInScope(closes, boundary);
    if (inBody) {
      // Table plumbing a browser would synthesise: <tr> straight in <table>, <td> without <tr>.
      if (name == 'tr' && current.name == 'table') insert(Element('tbody'), selfClosing: false);
      if ((name == 'td' || name == 'th') && (current.name == 'table' || current.name == 'tbody')) {
        insert(Element('tr'), selfClosing: false);
      }
    }
    final parent = current;
    parent.nodes.add(element..parent = parent);
    if (voidElements.contains(name) || selfClosing) return;

    if (rawTextElements.contains(name) || _rcdataElements.contains(name)) {
      final close = RegExp('</$name\\s*>', caseSensitive: false);
      final m = close.firstMatch(src.substring(pos));
      final end = m == null ? src.length : pos + m.start;
      final raw = src.substring(pos, end);
      if (raw.isNotEmpty) {
        element.nodes.add(Text(_rcdataElements.contains(name) ? decodeEntities(raw) : raw)..parent = element);
      }
      pos = m == null ? src.length : pos + m.end;
      return;
    }
    open.add(element);
  }

  /// Pops open elements up to and including the nearest one in [closes], unless one in
  /// [boundary] is met first.
  void closeInScope(Set<String> closes, Set<String> boundary) {
    for (var i = open.length - 1; i > 0; i--) {
      final n = open[i].name;
      if (closes.contains(n)) {
        open.removeRange(i, open.length);
        return;
      }
      if (boundary.contains(n)) return;
    }
  }
}

const _blockBoundaries = {'table', 'td', 'th', 'div', 'section', 'article', 'body', 'li', 'ul', 'ol', 'blockquote'};

bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
bool _isNameChar(int c) => _isAlpha(c) || (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x5f || c == 0x3a || c == 0x2e;
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;
