// A one-pass tag-soup HTML parser: no insertion modes, just the implicit closes and synthesised
// elements scrapers meet. No foster parenting (stray content in a `<table>` stays there) and no
// adoption agency (a misnested `</b>` closes what it crosses; nothing is re-opened).

part of '../../markup.dart';

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
  'address', 'article', 'aside', 'blockquote', 'center', 'details', 'dialog', 'dir', 'div', 'dl', 'fieldset', //
  'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr',
  'listing', 'main', 'menu', 'nav', 'ol', 'p', 'plaintext', 'pre', 'search', 'section', 'summary', 'table',
  'ul', 'xmp', 'li', 'dt', 'dd',
};

/// Start tag → (the open elements it closes, the boundary it stops at): `<li>` after `<li>`.
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
  'optgroup': ({'optgroup'}, {'select'}),
  'rt': ({'rt', 'rp'}, {'ruby'}),
  'rp': ({'rt', 'rp'}, {'ruby'}),
  'button': ({'button'}, {'applet', 'caption', 'marquee', 'object', 'table', 'td', 'template', 'th'}),
};

const _tableParts = {'table', 'tbody', 'tfoot', 'thead', 'tr', 'td', 'th', 'caption', 'colgroup', 'col'};

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// SVG's mixed-case names by their lowercase, restored inside `<svg>` as a browser does.
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
/// [source] parsed: the `<html>` element, and the `<!DOCTYPE …>` as written.
(Element, String?) _parseHtml(String source) {
  final parser = _Parser(source);
  return (parser.run(), parser.doctype);
}

final class _Parser {
  final String src;
  final Element html = Element('html');
  late final Element head = Element('head');
  Element? body;
  final List<Element> open = [];
  int pos = 0;

  final _TextRun _run = _TextRun();

  /// The first `<!DOCTYPE …>`, as written.
  String? doctype;

  /// Set by `<pre>` and `<listing>`: a newline straight after the start tag is not content.
  bool _dropNewline = false;

  /// Open `<svg>` and `<math>` elements, counted so `/>` need not scan the stack.
  int _svg = 0, _math = 0;

  /// CR LF and a lone CR read as LF, as the HTML input stream does.
  _Parser(String source)
    : src = source.contains('\r') ? source.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : source {
    open.add(html);
  }

  Element run() {
    html._nodes.add(head.._parent = html);
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
      .._parent = html
      .._slot = html._nodes.length;
    html._nodes.add(body!);
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
    var data = _decodeEntities(raw, _References.text);
    // `&#10;` is a newline too.
    if (_dropNewline) {
      _dropNewline = false;
      if (data.startsWith('\n')) data = data.substring(1);
      if (data.isEmpty) return;
    }
    _run.add(current, data);
  }

  /// Inside SVG or MathML, where `/>` closes an element and CDATA is text.
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
    final start = pos;
    skipTo('>'); // <!DOCTYPE …> and anything else declarative
    if (doctype == null &&
        body == null &&
        src.length >= start + 9 &&
        src.substring(start + 2, start + 9).toLowerCase() == 'doctype') {
      doctype = src.substring(start, pos);
    }
    return true;
  }

  bool skipTo(String close) {
    final end = src.indexOf(close, pos);
    pos = end == -1 ? src.length : end + close.length;
    return true;
  }

  bool endTag() {
    final start = pos + 2;
    if (start >= src.length) return false; // `</` at the very end is text
    // `</` before a non-letter is a bogus comment to the next `>`: `</ p>` is nothing.
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
    if (name == 'p' && !_inScope('p', _blockBoundaries)) {
      // A stray </p> is an empty paragraph, as in a browser.
      ensureBody();
      insert(Element('p'), selfClosing: true);
      return true;
    }
    closeInScopeSingle(
      name,
      _tableParts.contains(name)
          ? const {'table', 'template'}
          : const {'table', 'td', 'th', 'caption', 'template', 'object', 'marquee', 'applet'},
    );
    return true;
  }

  void openHead() {
    open
      ..clear()
      ..add(html)
      ..add(head);
    _svg = _math = 0;
  }

  bool startTag() {
    final nameEndPos = _nameEnd(src, pos + 1);
    var name = src.substring(pos + 1, nameEndPos).toLowerCase();
    var attributes = <String, String>{};
    final end = _scanAttributes(src, nameEndPos, attributes, html: true);
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
        // Only head itself ends at body content: tag-manager `<noscript>` snippets in head
        // keep their content, and the head elements after them stay in head.
        ensureBody();
      }
    }
    // `/>` closes only in foreign content; on `<div/>` it is noise.
    insert(element, selfClosing: selfClosing && (name == 'svg' || name == 'math' || inForeign));
    return true;
  }

  void insert(Element element, {required bool selfClosing}) {
    _run.flush();
    final name = element.name;
    if (_closesP.contains(name)) closeInScopeSingle('p', _blockBoundaries);
    // A link cannot hold a link, nor a heading a heading: the second closes the first.
    if (name == 'a' || name == 'nobr') closeInScopeSingle(name, _linkBoundaries);
    if (_headings.contains(name) && _headings.contains(current.name)) open.removeLast();
    if (name == 'optgroup') closeInScopeSingle('option', const {'select', 'optgroup'});
    if (_closesSibling[name] case (final closes, final boundary)?) closeInScope(closes, boundary);
    if (inBody) {
      // Table plumbing a browser would synthesise: <tr> straight in <table>, <td> without <tr>.
      if (name == 'tr' && current.name == 'table') insert(Element('tbody'), selfClosing: false);
      if ((name == 'td' || name == 'th') &&
          (current.name == 'table' || current.name == 'tbody' || current.name == 'thead' || current.name == 'tfoot')) {
        insert(Element('tr'), selfClosing: false);
      }
    }
    final parent = current;
    parent._nodes.add(
      element
        .._parent = parent
        .._slot = parent._nodes.length,
    );
    if (_voidElements.contains(name) || selfClosing) return;

    // Only HTML's own `<style>`, `<title>`…: inside SVG or MathML they are elements like any other.
    final foreign = inForeign && parent.name != 'foreignObject';
    if (!foreign && (_rawTextElements.contains(name) || _rcdataElements.contains(name))) {
      // Scanned in place: a regex would copy the rest of the document per <script>.
      final close = _endTag(src, pos, name);
      var raw = src.substring(pos, close?.start ?? src.length);
      if (name == 'textarea' && raw.startsWith('\n')) raw = raw.substring(1);
      if (raw.isNotEmpty) {
        element._nodes.add(
          Text(_rcdataElements.contains(name) ? _decodeEntities(raw, _References.text) : raw).._parent = element,
        );
      }
      pos = close?.past ?? src.length;
      return;
    }
    open.add(element);
    if (name == 'svg') _svg++;
    if (name == 'math') _math++;
    if (name == 'pre' || name == 'listing') _dropNewline = true;
  }

  /// Whether an element named [name] is open with none in [boundary] above it.
  bool _inScope(String name, Set<String> boundary) {
    for (var i = open.length - 1; i > 0; i--) {
      final n = open[i].name;
      if (n == name) return true;
      if (boundary.contains(n)) return false;
    }
    return false;
  }

  /// Pops open elements up to and including the nearest one matching [close], unless one in
  /// [boundary] is met first.
  void closeInScopeSingle(String close, Set<String> boundary) {
    for (var i = open.length - 1; i > 0; i--) {
      final n = open[i].name;
      if (n == close) {
        _truncate(i);
        return;
      }
      if (boundary.contains(n)) return;
    }
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

/// Gathers adjacent text runs (`a < b` is three) into one [Text] when something else arrives,
/// Coalesces adjacent text runs so a paragraph of five runs is one [Text] child,
/// rather than appending run by run, which is quadratic.
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
    if (target._nodes.lastOrNull case final Text last) {
      target._nodes.last = Text(last.data + data).._parent = target;
    } else {
      target._nodes.add(Text(data).._parent = target);
    }
  }
}

/// Where a tag name starting at [i] ends: at whitespace, `>` or `/`.
int _nameEnd(String src, int i) {
  for (int c; i < src.length && !_isSpace(c = src.codeUnitAt(i)) && c != 0x3e && c != 0x2f; i++) {}
  return i;
}

/// Reads a start tag's attributes from [i] into [into] (first of a name wins, values decoded)
/// and returns where the tag ends, negated after `/>` — an int, as a record cost 8% of the
/// parse. HTML lowercases names and decodes HTML's references; XML only its five.
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
      if (_isSpace(d) || d == 0x3d || d == 0x3e || d == 0x2f) {
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
          i = src.indexOf(q == 0x22 ? '"' : "'", start);
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

/// Where a new `<a>` stops looking for an open one to close, as the spec's markers do.
const _linkBoundaries = {'td', 'th', 'caption', 'table', 'template', 'object', 'marquee', 'applet', 'button'};

/// Where a start tag stops looking for an open `<p>` to close: the spec's button scope.
const _blockBoundaries = {'applet', 'button', 'caption', 'marquee', 'object', 'table', 'td', 'template', 'th'};

/// The first `</$name` then whitespace, `/` or `>`, any case, at or after [from], through the
/// next `>`: `</script/>` and `</script foo>` end a script too.

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
    if (j >= src.length) return null;
    final c = src.codeUnitAt(j);
    if (c != 0x3e && c != 0x2f && !_isSpace(c)) continue;
    final gt = src.indexOf('>', j);
    return gt == -1 ? null : (start: i, past: gt + 1);
  }
  return null;
}

int _toLower(int c) => (c >= 0x41 && c <= 0x5a) ? c + 0x20 : c;

bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;
