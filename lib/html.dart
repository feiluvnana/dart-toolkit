/// Ultra-minimal zero-dependency HTML parser + CSS selector engine.
///
/// ```dart
/// final doc = Html.parse('<div class="a"><p>Hello <a href="/">link</a></p></div>');
/// final links = doc.$('div.a p a'); // Elements (empty if no match, never null)
/// links[0].text();                  // "link"
/// links[0].attr('href');            // "/" (null if absent)
/// links[0].parent()?.text();        // parent Element or null at top level
/// ```
///
/// Public surface is exactly: [Html], [Elements], [Element].
/// - `Html.parse()` parses HTML and returns [Elements].
/// - [Elements] supports `$()` and `[]` (plus standard [Iterable] helpers).
/// - [Element] supports only `text()`, `attr()`, `parent()`.
/// Everything else is private.
library;

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html]. Never throws on malformed markup.
  static Elements parse(String html) => _HtmlParser(html).parse();
}

/// A list of elements. Query with `$()`, read with `[]`.
final class Elements extends Iterable<Element> {
  Elements._(this._items);

  final List<Element> _items;

  /// Filter: all self-or-descendant matches of [selector] for every
  /// element in this collection, deduped, in document order.
  Elements $(String selector) {
    final groups = _parseGroup(selector);
    final out = <Element>[];
    final seen = Set<Element>.identity();
    void visit(Element el) {
      if (groups.any((g) => _matchesComplex(el, g))) {
        if (seen.add(el)) out.add(el);
      }
      for (final c in el._children) {
        if (c is Element) visit(c);
      }
    }

    for (final el in _items) {
      visit(el);
    }
    return Elements._(out);
  }

  /// Element at [index] (throws [RangeError] if out of bounds).
  Element operator [](int index) => _items[index];

  @override
  int get length => _items.length;

  @override
  Iterator<Element> get iterator => _items.iterator;
}

/// A single element. Only `text()`, `attr()`, `parent()`.
final class Element {
  Element._(String tag, [Map<String, String>? attributes])
      : _tag = tag,
        _attrs = Map.unmodifiable(attributes ?? const {});

  final String _tag;
  final Map<String, String> _attrs;
  final List<Object> _children = [];
  Element? _parentLink;

  /// Concatenated descendant text.
  String text() {
    final buf = StringBuffer();
    void visit(Object n) {
      if (n is _TextNode) {
        buf.write(n.content);
      } else if (n is Element) {
        for (final c in n._children) {
          visit(c);
        }
      }
    }

    for (final c in _children) {
      visit(c);
    }
    return buf.toString();
  }

  /// Attribute [name] (case-insensitive) or `null` if absent.
  /// Boolean attributes map to `''`.
  String? attr(String name) => _attrs[name.toLowerCase()];

  /// Parent element, or `null` at top level.
  Element? parent() => _parentLink;

  void _addChild(Object node) {
    _setParentLink(node, this);
    _children.add(node);
  }
}

// ---------------------------------------------------------------------------
// Private leaves + helpers (not public API)
// ---------------------------------------------------------------------------

final class _TextNode {
  _TextNode(this.content);
  String content;
  Element? parentLink;
}

void _setParentLink(Object node, Element? p) {
  if (node is Element) {
    node._parentLink = p;
  } else if (node is _TextNode) {
    node.parentLink = p;
  }
}

Element? _prevElement(Element el) {
  final p = el._parentLink;
  if (p == null) return null;
  final sibs = p._children;
  final i = sibs.indexOf(el);
  for (var j = i - 1; j >= 0; j--) {
    final s = sibs[j];
    if (s is Element) return s;
  }
  return null;
}

Element? _nextElement(Element el) {
  final p = el._parentLink;
  if (p == null) return null;
  final sibs = p._children;
  final i = sibs.indexOf(el);
  for (var j = i + 1; j < sibs.length; j++) {
    final s = sibs[j];
    if (s is Element) return s;
  }
  return null;
}

List<Element> _childElements(Element el) =>
    el._children.whereType<Element>().toList(growable: false);

// ---------------------------------------------------------------------------
// Parser (zero deps, private)
// ---------------------------------------------------------------------------

const _voidElements = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

bool _isVoidElement(String tag) => _voidElements.contains(tag);

const _rawTextElements = {'script', 'style', 'title', 'textarea'};

final class _HtmlParser {
  _HtmlParser(this.source);

  final String source;
  var _i = 0;

  Elements parse() {
    final top = <Element>[];
    final stack = <Element>[];

    void addElement(Element el) {
      if (stack.isEmpty) {
        top.add(el);
      } else {
        stack.last._addChild(el);
      }
    }

    void addText(String content) {
      // Top-level text is unreachable in the minimal API (only Element
      // has text()), so only keep text inside elements.
      if (stack.isNotEmpty) stack.last._addChild(_TextNode(content));
    }

    while (_i < source.length) {
      if (source[_i] != '<') {
        final start = _i;
        while (_i < source.length && source[_i] != '<') {
          _i++;
        }
        final raw = source.substring(start, _i);
        if (raw.isNotEmpty) addText(_decodeEntities(raw));
        continue;
      }

      if (_startsWith('<!--')) {
        // Comments carry no data in the minimal API: skip.
        final end = source.indexOf('-->', _i + 4);
        _i = end == -1 ? source.length : end + 3;
        continue;
      }
      if (_startsWithIgnoreCase('<!doctype') || _startsWith('<!')) {
        final end = source.indexOf('>', _i + 2);
        _i = end == -1 ? source.length : end + 1;
        continue;
      }
      if (_startsWith('<?')) {
        final end = source.indexOf('?>', _i + 2);
        _i = end == -1 ? source.length : end + 2;
        continue;
      }
      if (_startsWith('</')) {
        _i += 2;
        _skipWs();
        final name = _readTagName().toLowerCase();
        final end = source.indexOf('>', _i);
        _i = end == -1 ? source.length : end + 1;
        if (name.isNotEmpty) {
          for (var k = stack.length - 1; k >= 0; k--) {
            if (stack[k]._tag == name) {
              stack.length = k;
              break;
            }
          }
        }
        continue;
      }

      final next = _i + 1 < source.length ? source[_i + 1] : '';
      if (!_isAsciiLetter(next) && next != '!' && next != '/') {
        addText('<');
        _i++;
        continue;
      }

      _i++; // consume '<'
      _skipWs();
      final tag = _readTagName().toLowerCase();
      if (tag.isEmpty) {
        addText('<');
        continue;
      }
      final attrs = <String, String>{};
      var selfClosing = false;
      while (true) {
        _skipWs();
        if (_i >= source.length) break;
        if (_startsWith('/>')) {
          selfClosing = true;
          _i += 2;
          break;
        }
        if (source[_i] == '>') {
          _i++;
          break;
        }
        final name = _readAttrName().toLowerCase();
        if (name.isEmpty) {
          _i++;
          continue;
        }
        _skipWs();
        var value = '';
        if (_i < source.length && source[_i] == '=') {
          _i++;
          _skipWs();
          value = _readAttrValue();
        }
        attrs[name] = _decodeEntities(value);
      }

      final el = Element._(tag, attrs);
      addElement(el);

      if (selfClosing || _isVoidElement(tag)) continue;
      if (_rawTextElements.contains(tag)) {
        final close = '</$tag';
        final endOpen = _indexOfIgnoreCase(source, close, _i);
        if (endOpen == -1) {
          final raw = source.substring(_i);
          if (raw.isNotEmpty) el._addChild(_TextNode(_decodeEntities(raw)));
          _i = source.length;
        } else {
          final raw = source.substring(_i, endOpen);
          if (raw.isNotEmpty) el._addChild(_TextNode(_decodeEntities(raw)));
          final gt = source.indexOf('>', endOpen + close.length);
          _i = gt == -1 ? source.length : gt + 1;
        }
        continue;
      }
      stack.add(el);
    }

    return Elements._(top);
  }

  bool _startsWith(String s) => source.startsWith(s, _i);

  bool _startsWithIgnoreCase(String s) =>
      source.length >= _i + s.length &&
      source.substring(_i, _i + s.length).toLowerCase() == s.toLowerCase();

  void _skipWs() {
    while (_i < source.length) {
      final c = source[_i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') {
        _i++;
      } else {
        break;
      }
    }
  }

  String _readTagName() {
    final start = _i;
    while (_i < source.length) {
      final c = source[_i];
      final ok = _isAsciiLetter(c) ||
          _isDigit(c) ||
          c == '-' ||
          c == '_' ||
          c == ':' ||
          c == '.';
      if (!ok) break;
      _i++;
    }
    return source.substring(start, _i);
  }

  String _readAttrName() {
    final start = _i;
    while (_i < source.length) {
      final c = source[_i];
      if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == '\r' ||
          c == '\f' ||
          c == '=' ||
          c == '>' ||
          c == '/' ||
          c == '"' ||
          c == "'" ||
          c == '<') {
        break;
      }
      _i++;
    }
    return source.substring(start, _i);
  }

  String _readAttrValue() {
    if (_i >= source.length) return '';
    final q = source[_i];
    if (q == '"' || q == "'") {
      _i++;
      final start = _i;
      final end = source.indexOf(q, start);
      if (end == -1) {
        final v = source.substring(start);
        _i = source.length;
        return v;
      }
      _i = end + 1;
      return source.substring(start, end);
    }
    final start = _i;
    while (_i < source.length) {
      final c = source[_i];
      if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == '\r' ||
          c == '\f' ||
          c == '>' ||
          c == '<' ||
          c == '"' ||
          c == "'" ||
          c == '=' ||
          c == '`') {
        break;
      }
      if (c == '/' && _i + 1 < source.length && source[_i + 1] == '>') break;
      _i++;
    }
    return source.substring(start, _i);
  }
}

bool _isAsciiLetter(String c) =>
    c.length == 1 &&
    ((c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90) ||
        (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122));

bool _isDigit(String c) =>
    c.length == 1 && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

int _indexOfIgnoreCase(String haystack, String needle, int start) {
  final h = haystack.toLowerCase();
  return h.indexOf(needle.toLowerCase(), start);
}

// ---------------------------------------------------------------------------
// Entities (private)
// ---------------------------------------------------------------------------

String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  const named = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
    'copy': '©',
    'reg': '®',
  };
  return s.replaceAllMapped(
    RegExp('&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]+);?'),
    (m) {
      final body = m.group(1)!;
      if (body.startsWith('#')) {
        try {
          if (body.length > 1 && (body[1] == 'x' || body[1] == 'X')) {
            return String.fromCharCode(int.parse(body.substring(2), radix: 16));
          }
          return String.fromCharCode(int.parse(body.substring(1)));
        } catch (_) {
          return m.group(0)!;
        }
      }
      final v = named[body];
      if (v != null) return v;
      return m.group(0)!;
    },
  );
}

// ---------------------------------------------------------------------------
// CSS selector engine (private subset)
// ---------------------------------------------------------------------------

List<_ComplexSelector> _parseGroup(String selector) {
  final parts = _splitTopLevel(selector, ',');
  final out = <_ComplexSelector>[];
  for (final p in parts) {
    final t = p.trim();
    if (t.isEmpty) continue;
    out.add(_parseComplex(t));
  }
  if (out.isEmpty) {
    throw ArgumentError.value(selector, 'selector', 'Empty selector');
  }
  return out;
}

final class _ComplexSelector {
  _ComplexSelector(this.compounds, this.combinators);
  final List<_Compound> compounds;
  final List<String> combinators;
}

final class _Compound {
  _Compound({
    this.tag,
    this.id,
    this.classes = const [],
    this.attrs = const [],
    this.pseudos = const [],
  });

  final String? tag;
  final String? id;
  final List<String> classes;
  final List<_AttrSel> attrs;
  final List<_Pseudo> pseudos;
}

final class _AttrSel {
  _AttrSel(this.name, this.op, this.value);
  final String name;
  final String op;
  final String value;
}

final class _Pseudo {
  _Pseudo(this.name, this.arg);
  final String name;
  final String arg;
}

_ComplexSelector _parseComplex(String s) {
  final compounds = <_Compound>[];
  final combinators = <String>[];
  var i = 0;

  void skipWs() {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
  }

  var pendingDescendant = false;
  while (true) {
    skipWs();
    if (i >= s.length) break;
    final c = s[i];
    if (c == '>' || c == '+' || c == '~') {
      combinators.add(c);
      i++;
      pendingDescendant = false;
      continue;
    }
    if (compounds.isNotEmpty && pendingDescendant) {
      combinators.add(' ');
    }
    compounds.add(_parseCompound(s, () => i, (v) => i = v));
    pendingDescendant = true;
    while (compounds.length > combinators.length + 1) {
      combinators.insert(combinators.length, ' ');
    }
    skipWs();
    if (i < s.length && (s[i] == '>' || s[i] == '+' || s[i] == '~')) {
      continue;
    }
    if (i >= s.length) break;
  }
  if (compounds.isEmpty) {
    throw ArgumentError.value(s, 'selector', 'Empty selector');
  }
  return _ComplexSelector(compounds, combinators);
}

_Compound _parseCompound(
  String s,
  int Function() getIndex,
  void Function(int) setIndex,
) {
  var i = getIndex();
  String? tag;
  String? id;
  final classes = <String>[];
  final attrs = <_AttrSel>[];
  final pseudos = <_Pseudo>[];

  bool isNameChar(String c) =>
      RegExp(r'[A-Za-z0-9\-_]').hasMatch(c) || c.codeUnitAt(0) > 127;

  String readName() {
    final start = i;
    while (i < s.length && isNameChar(s[i])) {
      i++;
    }
    return s.substring(start, i);
  }

  if (i < s.length && s[i] == '*') {
    i++;
  } else if (i < s.length && (isNameChar(s[i]))) {
    final name = readName().toLowerCase();
    if (name.isNotEmpty) tag = name;
  }

  var done = false;
  while (!done && i < s.length) {
    final c = s[i];
    if (c == '#') {
      i++;
      final name = readName();
      if (name.isEmpty) {
        throw ArgumentError.value(s, 'selector', 'Expected id after #');
      }
      id = name;
    } else if (c == '.') {
      i++;
      final name = readName();
      if (name.isEmpty) {
        throw ArgumentError.value(s, 'selector', 'Expected class after .');
      }
      classes.add(name);
    } else if (c == '[') {
      i++;
      while (i < s.length && s[i].trim().isEmpty) {
        i++;
      }
      final start = i;
      while (i < s.length &&
          s[i] != ']' &&
          s[i] != '=' &&
          s[i] != '~' &&
          s[i] != '|' &&
          s[i] != '^' &&
          s[i] != r'$' &&
          s[i] != '*') {
        i++;
      }
      final attrName = s.substring(start, i).trim().toLowerCase();
      if (attrName.isEmpty) {
        throw ArgumentError.value(s, 'selector', 'Expected attribute name');
      }
      while (i < s.length && s[i].trim().isEmpty) {
        i++;
      }
      var op = '';
      var value = '';
      if (i < s.length && s[i] != ']') {
        if (s[i] == '=') {
          op = '=';
          i++;
        } else if (i + 1 < s.length && s[i + 1] == '=') {
          op = '${s[i]}=';
          i += 2;
        } else {
          throw ArgumentError.value(s, 'selector', 'Bad attribute operator');
        }
        while (i < s.length && s[i].trim().isEmpty) {
          i++;
        }
        if (i < s.length && (s[i] == '"' || s[i] == "'")) {
          final q = s[i];
          i++;
          final vStart = i;
          final end = s.indexOf(q, vStart);
          if (end == -1) {
            throw ArgumentError.value(s, 'selector', 'Unclosed attribute value');
          }
          value = s.substring(vStart, end);
          i = end + 1;
        } else {
          final vStart = i;
          while (i < s.length && s[i] != ']' && s[i].trim().isNotEmpty) {
            i++;
          }
          value = s.substring(vStart, i).trim();
        }
        if (value.length >= 2 &&
            ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'")))) {
          value = value.substring(1, value.length - 1);
        }
      }
      while (i < s.length && s[i].trim().isEmpty) {
        i++;
      }
      var caseInsensitive = false;
      if (i < s.length && (s[i] == 'i' || s[i] == 'I')) {
        final la = i + 1 < s.length ? s[i + 1] : '';
        if (la == ']' || la.trim().isEmpty) {
          caseInsensitive = true;
          i++;
          while (i < s.length && s[i].trim().isEmpty) {
            i++;
          }
        }
      }
      if (i >= s.length || s[i] != ']') {
        throw ArgumentError.value(s, 'selector', 'Expected ]');
      }
      i++;
      if (caseInsensitive) value = value.toLowerCase();
      attrs.add(_AttrSel(attrName, op, value));
    } else if (c == ':') {
      i++;
      if (i < s.length && s[i] == ':') i++;
      final name = readName().toLowerCase();
      if (name.isEmpty) {
        throw ArgumentError.value(s, 'selector', 'Expected pseudo-class');
      }
      var arg = '';
      if (i < s.length && s[i] == '(') {
        i++;
        final depthStart = i;
        var depth = 1;
        var inQ = '';
        while (i < s.length && depth > 0) {
          final ch = s[i];
          if (inQ.isNotEmpty) {
            if (ch == inQ) inQ = '';
          } else if (ch == '"' || ch == "'") {
            inQ = ch;
          } else if (ch == '(') {
            depth++;
          } else if (ch == ')') {
            depth--;
            if (depth == 0) break;
          }
          i++;
        }
        if (depth != 0) {
          throw ArgumentError.value(s, 'selector', 'Unclosed :$name(');
        }
        arg = s.substring(depthStart, i).trim();
        i++;
      }
      pseudos.add(_Pseudo(name, arg));
    } else {
      done = true;
    }
  }

  setIndex(i);
  return _Compound(
    tag: tag,
    id: id,
    classes: classes,
    attrs: attrs,
    pseudos: pseudos,
  );
}

List<String> _splitTopLevel(String s, String sep) {
  final out = <String>[];
  var depthB = 0;
  var depthP = 0;
  var quote = '';
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote.isNotEmpty) {
      if (c == quote) quote = '';
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '[') {
      depthB++;
    } else if (c == ']') {
      if (depthB > 0) depthB--;
    } else if (c == '(') {
      depthP++;
    } else if (c == ')') {
      if (depthP > 0) depthP--;
    } else if (c == sep && depthB == 0 && depthP == 0) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  return out;
}

bool _matchesComplex(Element el, _ComplexSelector sel) {
  var cur = el;
  var idx = sel.compounds.length - 1;
  if (!_matchesCompound(cur, sel.compounds[idx])) return false;
  while (idx > 0) {
    final comb = sel.combinators[idx - 1];
    final left = sel.compounds[idx - 1];
    switch (comb) {
      case '>':
        final p = cur._parentLink;
        if (p == null || !_matchesCompound(p, left)) return false;
        cur = p;
      case ' ':
        Element? p = cur._parentLink;
        var ok = false;
        while (p != null) {
          if (_matchesCompound(p, left)) {
            ok = true;
            cur = p;
            break;
          }
          p = p._parentLink;
        }
        if (!ok) return false;
      case '+':
        final prev = _prevElement(cur);
        if (prev == null || !_matchesCompound(prev, left)) return false;
        cur = prev;
      case '~':
        Element? sib = _prevElement(cur);
        var ok = false;
        while (sib != null) {
          if (_matchesCompound(sib, left)) {
            ok = true;
            cur = sib;
            break;
          }
          sib = _prevElement(sib);
        }
        if (!ok) return false;
      default:
        return false;
    }
    idx--;
  }
  return true;
}

bool _matchesCompound(Element el, _Compound c) {
  if (c.tag != null && el._tag != c.tag) return false;
  if (c.id != null && el._attrs['id'] != c.id) return false;
  if (c.classes.isNotEmpty) {
    final classAttr = el._attrs['class'] ?? '';
    final have =
        classAttr.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toSet();
    for (final cls in c.classes) {
      if (!have.contains(cls)) return false;
    }
  }
  for (final a in c.attrs) {
    if (!_matchesAttr(el, a)) return false;
  }
  for (final p in c.pseudos) {
    if (!_matchesPseudo(el, p)) return false;
  }
  return true;
}

bool _matchesAttr(Element el, _AttrSel a) {
  final actual = el._attrs[a.name];
  if (a.op.isEmpty) return actual != null;
  if (actual == null) return false;
  switch (a.op) {
    case '=':
      return actual == a.value;
    case '~=':
      return actual.split(RegExp(r'\s+')).contains(a.value);
    case '|=':
      return actual == a.value || actual.startsWith('${a.value}-');
    case '^=':
      return a.value.isNotEmpty && actual.startsWith(a.value);
    case r'$=':
      return a.value.isNotEmpty && actual.endsWith(a.value);
    case '*=':
      return a.value.isNotEmpty && actual.contains(a.value);
    default:
      return false;
  }
}

bool _matchesPseudo(Element el, _Pseudo p) {
  switch (p.name) {
    case 'first-child':
      return _prevElement(el) == null && el._parentLink != null;
    case 'last-child':
      return _nextElement(el) == null && el._parentLink != null;
    case 'only-child':
      return _prevElement(el) == null &&
          _nextElement(el) == null &&
          el._parentLink != null;
    case 'empty':
      return el._children.isEmpty;
    case 'root':
      return el._parentLink == null;
    case 'nth-child':
      final parent = el._parentLink;
      if (parent == null) return false;
      final sibs = _childElements(parent);
      final pos = sibs.indexOf(el) + 1;
      return _matchesNth(p.arg, pos);
    case 'not':
      if (p.arg.isEmpty) return true;
      return !_parseGroup(
        p.arg,
      ).any((g) => g.compounds.length == 1 && g.combinators.isEmpty && _matchesCompound(el, g.compounds.single));
    default:
      return false;
  }
}

bool _matchesNth(String arg, int pos) {
  final a = arg.trim().toLowerCase();
  if (a == 'odd') return pos.isOdd;
  if (a == 'even') return pos.isEven;
  final n = int.tryParse(a);
  if (n != null) return pos == n;
  final m = RegExp(r'^([+-]?\d*)n\s*([+-]\s*\d+)?$').firstMatch(a);
  if (m == null) return false;
  var aStr = m.group(1)!;
  if (aStr == '' || aStr == '+') aStr = '1';
  if (aStr == '-') aStr = '-1';
  final step = int.parse(aStr);
  final bStr = (m.group(2) ?? '').replaceAll(' ', '');
  final offset = bStr.isEmpty ? 0 : int.parse(bStr);
  if (step == 0) return pos == offset;
  final diff = pos - offset;
  return diff % step == 0 && diff ~/ step >= 0;
}
