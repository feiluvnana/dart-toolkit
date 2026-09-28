// A tag-soup HTML parser: one pass, no HTML5 insertion modes, the implicit closes and
// synthesised elements a scraper meets in practice.
//
// What it leaves out on purpose is foster parenting: a `<div>` or stray text straight inside
// a `<table>` stays there, where a browser would move it before the table. `.table` reads
// the same either way; `$('table').text` includes the stray text.

part of '../../../formats.dart';

/// Elements with no content and no end tag.
const _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr', //
  'basefont', 'bgsound', 'frame', 'keygen', 'command',
};

/// Elements whose content is raw text up to their end tag, entities left alone.
const _rawTextElements = {'script', 'style', 'xmp', 'iframe', 'noembed', 'noframes'};

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
  'tr': ({'tr', 'caption'}, {'table', 'thead', 'tbody', 'tfoot'}),
  'td': ({'td', 'th', 'caption'}, {'tr', 'table'}),
  'th': ({'td', 'th', 'caption'}, {'tr', 'table'}),
  'thead': ({'thead', 'tbody', 'tfoot', 'caption'}, {'table'}),
  'tbody': ({'thead', 'tbody', 'tfoot', 'caption'}, {'table'}),
  'tfoot': ({'thead', 'tbody', 'tfoot', 'caption'}, {'table'}),
  'option': ({'option'}, {'select', 'datalist', 'optgroup'}),
  'optgroup': ({'optgroup', 'option'}, {'select'}),
  'rt': ({'rt', 'rp'}, {'ruby'}),
  'rp': ({'rt', 'rp'}, {'ruby'}),
};

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// SVG's mixed-case names, by the lowercase a tag-soup tokenizer reads them as: inside
/// `<svg>` they are put back, as a browser does, so `viewBox` serialises as `viewBox` and a
/// renderer still reads it.
final _svgTags = {
  for (final n in const [
    'altGlyph', 'altGlyphDef', 'altGlyphItem', 'animateColor', 'animateMotion', 'animateTransform', 'clipPath', //
    'feBlend', 'feColorMatrix', 'feComponentTransfer', 'feComposite', 'feConvolveMatrix', 'feDiffuseLighting',
    'feDisplacementMap', 'feDistantLight', 'feDropShadow', 'feFlood', 'feFuncA', 'feFuncB', 'feFuncG', 'feFuncR',
    'feGaussianBlur', 'feImage', 'feMerge', 'feMergeNode', 'feMorphology', 'feOffset', 'fePointLight',
    'feSpecularLighting', 'feSpotLight', 'feTile', 'feTurbulence', 'foreignObject', 'glyphRef', 'linearGradient',
    'radialGradient', 'textPath',
  ])
    n.toLowerCase(): n,
};

final _svgAttributes = {
  for (final n in const [
    'attributeName', 'attributeType', 'baseFrequency', 'baseProfile', 'calcMode', 'clipPathUnits', //
    'diffuseConstant', 'edgeMode', 'filterUnits', 'glyphRef', 'gradientTransform', 'gradientUnits', 'kernelMatrix',
    'kernelUnitLength', 'keyPoints', 'keySplines', 'keyTimes', 'lengthAdjust', 'limitingConeAngle', 'markerHeight',
    'markerUnits', 'markerWidth', 'maskContentUnits', 'maskUnits', 'numOctaves', 'pathLength',
    'patternContentUnits', 'patternTransform', 'patternUnits', 'pointsAtX', 'pointsAtY', 'pointsAtZ',
    'preserveAlpha', 'preserveAspectRatio', 'primitiveUnits', 'refX', 'refY', 'repeatCount', 'repeatDur',
    'requiredExtensions', 'requiredFeatures', 'specularConstant', 'specularExponent', 'spreadMethod',
    'startOffset', 'stdDeviation', 'stitchTiles', 'surfaceScale', 'systemLanguage', 'tableValues', 'targetX',
    'targetY', 'textLength', 'viewBox', 'viewTarget', 'xChannelSelector', 'yChannelSelector', 'zoomAndPan',
  ])
    n.toLowerCase(): n,
};

/// Parses [source] into an `<html>` element with `<head>` and `<body>`.
Element _parseHtml(String source) => _Parser(source).run();

final class _Parser {
  final String src;
  final Element html = Element('html');
  late final Element head = Element('head');
  Element? body;
  final List<Element> open = [];
  int pos = 0;

  final _TextRun _run = _TextRun();

  /// Set by `<pre>`, `<listing>` and `<textarea>`: a newline straight after the start tag
  /// is not content.
  bool _dropNewline = false;

  /// How many `<svg>` and `<math>` elements are open. Counted rather than searched for:
  /// scanning the open stack on every `/>` was quadratic on a page of them.
  int _svg = 0, _math = 0;

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
    _run.flush();
    return html;
  }

  Element get current => open.last;

  bool get inBody => body != null && open.contains(body);

  void ensureBody() {
    if (body != null) return;
    _run.flush();
    body = Element('body')
      ..parent = html
      .._slot = html.nodes.length;
    html.nodes.add(body!);
    // Whatever was open before the body — nothing legitimate — is abandoned.
    open
      ..clear()
      ..add(html)
      ..add(body!);
    _svg = _math = 0;
  }

  /// Closes every open element from [i] up.
  void _truncate(int i) {
    open.removeRange(i, open.length);
    if (_svg + _math == 0) return;
    _svg = _math = 0;
    for (final e in open) {
      if (e.name == 'svg') _svg++;
      if (e.name == 'math') _math++;
    }
  }

  void text(String raw) {
    if (body == null) {
      if (raw.trim().isEmpty) return;
      // Text inside an element in head, such as a `<noscript>`, stays there.
      if (open.length == 1 || identical(current, head)) ensureBody();
    }
    if (_dropNewline) {
      _dropNewline = false;
      if (raw.startsWith('\n')) raw = raw.substring(1);
      if (raw.isEmpty) return;
    }
    _run.add(current, decodeEntities(raw));
  }

  /// Whether the element being inserted sits in SVG or MathML, where `/>` closes an
  /// element and CDATA is text, as in XML.
  bool get inForeign => _svg + _math > 0;

  /// Consumes the markup at [pos] (which is `<`); returns false when it is not markup.
  bool tag() {
    _dropNewline = false;
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
      // `<!-->` and `<!--->` are whole, empty comments.
      if (src.startsWith('>', pos + 4) || src.startsWith('->', pos + 4)) {
        pos = src.indexOf('>', pos + 4) + 1;
        return true;
      }
      final end = src.indexOf('-->', pos + 4);
      pos = end == -1 ? src.length : end + 3;
      return true;
    }
    if (src.startsWith('<![CDATA[', pos) && inForeign) {
      // Text only in SVG and MathML; in HTML it is a comment that ends at the first `>`.
      final end = src.indexOf(']]>', pos + 9);
      text(src.substring(pos + 9, end == -1 ? src.length : end).replaceAll('&', '&amp;'));
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
    final start = pos + 2;
    if (start >= src.length) return false; // `</` at the very end is text
    // `</>` is dropped, and `</` before anything but a letter opens a bogus comment that
    // runs to the next `>`: `</ p>` is nothing, as in a browser.
    if (!_isAlpha(src.codeUnitAt(start))) return skipTo('>');
    final i = _nameEnd(src, start);
    var name = src.substring(start, i).toLowerCase();
    if (_svg > 0) name = _svgTags[name] ?? name;
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

  void openHead() {
    open
      ..clear()
      ..add(html)
      ..add(head);
    _svg = _math = 0;
  }

  /// Pops open elements up to and including the nearest [name]; nothing if it is not open.
  void closeTo(String name) {
    for (var i = open.length - 1; i > 0; i--) {
      if (open[i].name == name) {
        _truncate(i);
        return;
      }
    }
  }

  bool startTag() {
    final nameEnd = _nameEnd(src, pos + 1);
    var name = src.substring(pos + 1, nameEnd).toLowerCase();
    var attributes = <String, String>{};
    final end = _scanAttributes(src, nameEnd, attributes, html: true);
    if (_svg > 0 || name == 'svg') {
      name = _svgTags[name] ?? name;
      if (attributes.keys.any(_svgAttributes.containsKey)) {
        attributes = {for (final MapEntry(:key, :value) in attributes.entries) _svgAttributes[key] ?? key: value};
      }
    }
    final selfClosing = end < 0;
    pos = end.abs();

    // A second `<html>` or `<body>` adds the attributes the first did not have.
    if (name == 'html' || name == 'body') {
      if (name == 'body') ensureBody();
      final target = name == 'html' ? html : body!;
      attributes.forEach((k, v) => target.attributes.putIfAbsent(k, () => v));
      return true;
    }
    if (name == 'head') {
      if (body == null) {
        head.attributes.addAll(attributes);
        openHead();
      }
      return true;
    }

    final element = Element(name, attributes);
    if (body == null) {
      if (_headElements.contains(name)) {
        if (!open.contains(head)) openHead();
      } else if (identical(current, head) || identical(current, html)) {
        // Only head itself ends at body content. Inside a `<noscript>` or `<template>` in
        // head — the tag-manager and pixel snippets nearly every page carries — the content
        // is that element's, and the title, meta and canonical link after it are head's.
        ensureBody();
      }
    }
    // `/>` closes an element only where XML rules apply; on `<div/>` it is noise, and the
    // text after it is the div's.
    insert(element, selfClosing: selfClosing && (name == 'svg' || name == 'math' || inForeign));
    return true;
  }

  void insert(Element element, {required bool selfClosing}) {
    _run.flush();
    final name = element.name;
    if (_closesP.contains(name)) closeInScope({'p'}, _blockBoundaries);
    // A link cannot hold a link, nor a heading a heading: the second closes the first.
    if (name == 'a' || name == 'nobr') closeInScope(name == 'a' ? const {'a'} : const {'nobr'}, _linkBoundaries);
    if (_headings.contains(name) && _headings.contains(current.name)) open.removeLast();
    if (_closesSibling[name] case (final closes, final boundary)?) closeInScope(closes, boundary);
    if (inBody) {
      // Table plumbing a browser would synthesise: <tr> straight in <table>, <td> without <tr>.
      if (name == 'tr' && current.name == 'table') insert(Element('tbody'), selfClosing: false);
      if ((name == 'td' || name == 'th') && (current.name == 'table' || current.name == 'tbody')) {
        insert(Element('tr'), selfClosing: false);
      }
    }
    final parent = current;
    parent.nodes.add(
      element
        ..parent = parent
        .._slot = parent.nodes.length,
    );
    if (_voidElements.contains(name) || selfClosing) return;

    if (_rawTextElements.contains(name) || _rcdataElements.contains(name)) {
      // Scanned in place: copying the rest of the document to run a regex over it costs a
      // full-document copy per <script> or <style>, and a page has many of both.
      final close = _endTag(src, pos, name);
      var raw = src.substring(pos, close?.start ?? src.length);
      if (name == 'textarea' && raw.startsWith('\n')) raw = raw.substring(1);
      if (raw.isNotEmpty) {
        element.nodes.add(Text(_rcdataElements.contains(name) ? decodeEntities(raw) : raw)..parent = element);
      }
      pos = close?.past ?? src.length;
      return;
    }
    open.add(element);
    if (name == 'svg') _svg++;
    if (name == 'math') _math++;
    if (name == 'pre' || name == 'listing') _dropNewline = true;
  }

  /// Pops open elements up to and including the nearest one in [closes], unless one in
  /// [boundary] is met first.
  void closeInScope(Set<String> closes, Set<String> boundary) {
    for (var i = open.length - 1; i > 0; i--) {
      final n = open[i].name;
      if (closes.contains(n)) {
        _truncate(i);
        return;
      }
      if (boundary.contains(n)) return;
    }
  }
}

/// Text on its way into a tree. Adjacent runs — `a < b` is three of them — are gathered
/// and land as one [Text] when something else arrives, rather than being concatenated onto
/// the last node run by run, which copied the text so far every time and was quadratic in
/// the number of runs.
final class _TextRun {
  Element? _target;

  /// The first run on its own: most text is one run, and needs no buffer.
  String? _first;
  final StringBuffer _buffer = StringBuffer();

  void add(Element target, String data) {
    if (!identical(target, _target)) {
      flush();
      _target = target;
    }
    if (_first == null) {
      _first = data;
    } else {
      if (_buffer.isEmpty) _buffer.write(_first);
      _buffer.write(data);
    }
  }

  void flush() {
    final target = _target;
    var data = _first;
    _target = _first = null;
    if (target == null || data == null) return;
    if (_buffer.isNotEmpty) {
      data = _buffer.toString();
      _buffer.clear();
    }
    if (data.isEmpty) return;
    if (target.nodes.lastOrNull case final Text last) {
      target.nodes.last = Text(last.data + data)..parent = target;
    } else {
      target.nodes.add(Text(data)..parent = target);
    }
  }
}

/// Where a tag name starting at [i] ends: at whitespace, `>` or `/`.
int _nameEnd(String src, int i) {
  for (int c; i < src.length && !_isSpace(c = src.codeUnitAt(i)) && c != 0x3e && c != 0x2f; i++) {}
  return i;
}

/// Reads a start tag's attributes from [i], just past its name, into [into] — the first of
/// a name wins, values decoded — and returns where the tag ends, negated when it ended in
/// `/>`. HTML folds names to lowercase and decodes HTML's references; XML keeps names as
/// written and decodes its own five. An int rather than a record: the record measured 8%
/// off the whole parse.
int _scanAttributes(String src, int i, Map<String, String> into, {required bool html}) {
  while (true) {
    while (i < src.length && _isSpace(src.codeUnitAt(i))) {
      i++;
    }
    if (i >= src.length) return i;
    final c = src.codeUnitAt(i);
    if (c == 0x3e) return i + 1;
    if (c == 0x2f) {
      // `/` — the self-closing marker, or noise.
      if (++i < src.length && src.codeUnitAt(i) == 0x3e) return -(i + 1);
      continue;
    }
    final nameStart = i++;
    while (i < src.length) {
      final d = src.codeUnitAt(i);
      if (_isSpace(d) || d == 0x3d || d == 0x3e || (d == 0x2f && i + 1 < src.length && src.codeUnitAt(i + 1) == 0x3e)) {
        break;
      }
      i++;
    }
    final attribute = src.substring(nameStart, i);
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
        final quoted = q == 0x22 || q == 0x27;
        final start = quoted ? i + 1 : i;
        if (quoted) {
          i = src.indexOf(String.fromCharCode(q), start);
          if (i == -1) i = src.length;
        } else {
          while (i < src.length && !_isSpace(src.codeUnitAt(i)) && src.codeUnitAt(i) != 0x3e) {
            i++;
          }
        }
        value = src.substring(start, i);
        if (quoted && i < src.length) i++;
      }
    }
    into.putIfAbsent(
      html ? attribute.toLowerCase() : attribute,
      () => _decodeEntities(value, html ? _References.attribute : _References.xml),
    );
  }
}

/// Where an open `<a>` stops being one a new `<a>` can close: a cell or a nested table
/// starts a fresh scope, as the spec's formatting-element markers do.
const _linkBoundaries = {'td', 'th', 'caption', 'table', 'template', 'object', 'marquee', 'applet', 'button'};

const _blockBoundaries = {'table', 'td', 'th', 'div', 'section', 'article', 'body', 'li', 'ul', 'ol', 'blockquote'};

/// The end tag `</[name]>` at or after [from], allowing whitespace before the `>` and any
/// case in the name — `</$name\s*>` without compiling a pattern or copying the source.
({int start, int past})? _endTag(String src, int from, String name) {
  for (var i = src.indexOf('<', from); i != -1 && i + 1 < src.length; i = src.indexOf('<', i + 1)) {
    if (src.codeUnitAt(i + 1) != 0x2f) continue; // not `</`
    var j = i + 2;
    var k = 0;
    while (k < name.length && j < src.length && _toLower(src.codeUnitAt(j)) == name.codeUnitAt(k)) {
      j++;
      k++;
    }
    if (k != name.length) continue;
    while (j < src.length && _isSpace(src.codeUnitAt(j))) {
      j++;
    }
    if (j < src.length && src.codeUnitAt(j) == 0x3e) return (start: i, past: j + 1);
  }
  return null;
}

int _toLower(int c) => (c >= 0x41 && c <= 0x5a) ? c + 0x20 : c;

bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;
