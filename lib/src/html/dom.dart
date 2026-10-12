import 'dart:convert';

import '../core/pipe.dart';
import '../core/traits.dart';
import 'entities.dart';

part 'parser.dart';

/// A node in the document tree. Nodes are immutable: the parser freezes every
/// collection, and [Element.drop] copies instead of mutating.
sealed class Node {
  /// The parent element, if any. Set once, when the tree is assembled or
  /// copied — `null` until then, never throwing.
  Element? parent;

  /// All text below this node, concatenated.
  String get text;
}

/// A run of text.
final class Text extends Node {
  /// The text.
  final String data;

  Text(this.data);

  @override
  String get text => data;

  /// The text escaped (`&`, `<`, `>`), so reparsing gives the same tree.
  /// Inside `script`/`style`/`textarea`/`title` the parent writes [data] raw.
  @override
  String toString() => _escapeText(data);
}

/// Escapes `&`, `<` and `>` for HTML output.
String _escapeText(String v) => v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// An element with a [tag], [attrs] and child nodes. [children] holds the
/// element children only; text runs are [Text] nodes beside them.
///
/// The constructor is private: a script cannot build an unwired tree.
/// Documents come from [Html.parse]; subtrees from [drop].
final class Element extends Node {
  final String tag;
  final Map<String, String> attrs;
  final List<Node> _nodes;

  /// Position among the parent's element children, set at wiring: `prev`,
  /// `next` and `:nth-child` read it instead of rebuilding the list.
  int _siblingIndex = 0;

  /// The element children, cached at wiring (same content as [children]).
  List<Element>? _elementKids;

  /// The URL links resolve against; set on the `#document` root only.
  Uri? _base;

  Element._(this.tag, [Map<String, String>? attrs, List<Node>? nodes])
    : attrs = Map.unmodifiable(attrs ?? <String, String>{}),
      _nodes = List.unmodifiable(nodes ?? <Node>[]);

  /// The element children.
  List<Element> get children => _elementKids ??= List<Element>.unmodifiable(_nodes.whereType<Element>());

  /// The concatenated text of every descendant.
  @override
  String get text => _nodes.map((c) => c.text).join();

  /// The inner serialisation of the child nodes.
  String get html => _nodes.map((c) => c.toString()).join();

  /// One attribute, or [or] (default `null`).
  String? attr(String name, {String? or}) => attrs[name] ?? or;

  /// The `id` attribute.
  String? get id => attrs['id'];

  /// The [attr] attribute (`href` by default; `src` for an image) as an absolute URL,
  /// resolved against the document's [Doc.url]; as written when the document has none.
  String? link([String attr = 'href']) {
    final raw = attrs[attr]?.trim();
    if (raw == null) return null;
    var top = this;
    for (var p = parent; p != null; p = p.parent) {
      top = p;
    }
    final ref = Uri.tryParse(raw);
    return ref == null ? raw : (top._base?.resolveUri(ref).toString() ?? raw);
  }

  /// The text as lines: broken at `<br>`, block elements and line breaks, each
  /// trimmed, blanks dropped.
  List<String> get lines {
    final sb = StringBuffer();
    void walk(Element at) {
      for (final n in at._nodes) {
        if (n is Element) {
          final tag = n.tag.toLowerCase();
          if (tag == 'br') {
            sb.write('\n');
          } else if (_blocks.contains(tag)) {
            sb.write('\n');
            walk(n);
            sb.write('\n');
          } else {
            walk(n);
          }
        } else {
          sb.write(n.text);
        }
      }
    }

    walk(this);
    return [
      for (final line in sb.toString().split('\n'))
        if (line.trim() case final t when t.isNotEmpty) t,
    ];
  }

  /// The nearest element above this one matching [css] (the element itself
  /// is never a match, as with [find]).
  Element? closest(String css) {
    for (var at = parent; at != null; at = at.parent) {
      if (at.tag != '#document' && at.matches(css)) return at;
    }
    return null;
  }

  /// The class list.
  List<String> get classes => (attrs['class'] ?? '').split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();

  /// The previous sibling element, if any.
  Element? get prev {
    final p = parent;
    if (p == null || _siblingIndex <= 0) return null;
    return (p._elementKids ?? p.children)[_siblingIndex - 1];
  }

  /// The next sibling element, if any.
  Element? get next {
    final p = parent;
    if (p == null) return null;
    final kids = p._elementKids ?? p.children;
    final i = _siblingIndex + 1;
    return i < kids.length ? kids[i] : null;
  }

  /// The first element below this one matching [css], in document order
  /// (like `querySelector`: the element itself is never a match; test it
  /// with [matches]).
  Element? find(String css) {
    for (final el in children) {
      if (el.matches(css)) return el;
      final hit = el.find(css);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Every element below this one matching [css], in document order (like
  /// `querySelectorAll`: the element itself is never included).
  List<Element> all(String css) {
    final out = <Element>[];
    void walk(Element at) {
      for (final el in at.children) {
        if (el.matches(css)) out.add(el);
        walk(el);
      }
    }

    walk(this);
    return out;
  }

  /// A deep copy without the elements matching [css]; the receiver is
  /// unchanged, and itself always kept.
  Element drop(String css) => _copyExcept(this, css);

  /// Whether this element matches [css].
  bool matches(String css) => _matchesSelector(this, css);

  @override
  String toString() {
    final sb = StringBuffer('<$tag');
    attrs.forEach((name, value) => sb.write(' $name="${_escapeAttr(value)}"'));
    // Void elements have no closer.
    if (_void.contains(tag.toLowerCase())) {
      sb.write('>');
      return sb.toString();
    }
    sb.write('>');
    // Raw-text elements keep their content verbatim; everything else escapes.
    final raw = _rawText.contains(tag.toLowerCase()) || _escapableRaw.contains(tag.toLowerCase());
    for (final child in _nodes) {
      if (child is Text && raw) {
        sb.write(child.data);
      } else {
        sb.write(child.toString());
      }
    }
    sb.write('</$tag>');
    return sb.toString();
  }
}

const _blocks = {
  'address', 'article', 'aside', 'blockquote', 'dd', 'div', 'dl', 'dt', 'figcaption', 'figure', 'footer', //
  'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', //
  'section', 'table', 'td', 'th', 'tr', 'ul',
};

String _escapeAttr(String v) => v.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

/// A parsed document with a synthetic `#document` root.
final class Doc {
  final Element _root;

  /// The `<!DOCTYPE …>` line when the source had one, verbatim.
  final String? doctype;

  Doc(this._root, [this.doctype]);

  /// The URL [Element.link] resolves against: where the document came from (an
  /// HTTP response's final URL, a page's, a file's), moved by its `<base href>`.
  String? get url => _root._base?.toString();

  /// The first element in the document matching [css].
  Element? find(String css) => _root.find(css);

  /// Every element in the document matching [css].
  List<Element> all(String css) => _root.all(css);

  /// The document's whole text.
  String get text => _root.text;

  /// The whole document's markup, doctype first when there is one.
  String get html => '${doctype ?? ''}${_root.html}';

  /// A deep copy without the elements matching [css]; the receiver is unchanged.
  Doc drop(String css) => Doc(_copyExcept(_root, css).._base = _root._base, doctype);

  /// Saves the document's markup to [to] (atomically for a file).
  Future<void> save(Target to) => utf8.encode(html).pipe(to);

  @override
  String toString() => html;
}

/// [src] deep-copied without the elements matching [css]; [src] itself is
/// always kept, so the copy never loses its root. The copy is wired to
/// [src]'s parent, so selectors (and `:root`) work on it.
Element _copyExcept(Element src, String css) {
  final kids = <Node>[];
  for (final n in src._nodes) {
    if (n is Element) {
      if (n.matches(css)) continue;
      kids.add(_copyExcept(n, css));
    } else {
      kids.add(Text((n as Text).data));
    }
  }
  final el = Element._(src.tag, src.attrs, kids);
  _wire(el, src.parent);
  return el;
}

/// Assembles parsed top-level nodes into a [Doc]: implies `html > head + body`
/// around fragments, then wires every parent exactly once.
///
/// The parser builds mutable lists; this freezes them. Hidden from the topic
/// export: documents come from [Html.parse].
Doc assembleDocument(List<Node> topKids, {String? doctype, String? url}) {
  final structured = _implyStructure(topKids);
  final root = Element._('#document', {}, structured);
  _wire(root, null);
  final at = url == null ? null : Uri.tryParse(url);
  final base = root.find('base[href]')?.attr('href')?.trim();
  final href = base == null ? null : Uri.tryParse(base);
  root._base = href == null ? at : (at?.resolveUri(href) ?? href);
  return Doc(root, doctype);
}

/// Wires every parent in [el]'s tree, exactly once — and numbers each element
/// among its siblings, caching the element-children list, so `prev`/`next`
/// and `:nth-child` never rebuild it.
void _wire(Element el, Element? parent) {
  el.parent = parent;
  final kids = <Element>[];
  for (final kid in el._nodes) {
    if (kid is Element) {
      kid._siblingIndex = kids.length;
      kids.add(kid);
      _wire(kid, el);
    } else {
      kid.parent = el;
    }
  }
  el._elementKids = List<Element>.unmodifiable(kids);
}

/// Wraps a fragment without `<html>` in an implied `html > head + body` (as a
/// browser does), so `find('body')` works on text-only pages. A document with
/// `<html>` but no `<body>` gains an empty one.
List<Node> _implyStructure(List<Node> kids) {
  Element? htmlEl;
  for (final kid in kids) {
    if (kid is Element && kid.tag.toLowerCase() == 'html') {
      htmlEl = kid;
      break;
    }
  }
  if (htmlEl == null) {
    final body = Element._('body', {}, kids);
    final head = Element._('head');
    return [
      Element._('html', {}, [head, body]),
    ];
  }
  if (!htmlEl.children.any((el) => el.tag.toLowerCase() == 'body')) {
    final withBody = Element._('html', htmlEl.attrs, [...htmlEl._nodes, Element._('body')]);
    return [for (final k in kids) identical(k, htmlEl) ? withBody : k];
  }
  return kids;
}

/// Whether [element] matches the CSS [css] (a comma-separated group list).
bool _matchesSelector(Element element, String css) {
  for (final group in _splitGroups(css)) {
    if (_matchesGroup(element, group)) return true;
  }
  return false;
}

List<String> _splitGroups(String css) {
  final groups = <String>[];
  var depth = 0;
  final buf = StringBuffer();
  for (final c in css.split('')) {
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    if (c == ',' && depth == 0) {
      groups.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  groups.add(buf.toString());
  return [
    for (final g in groups)
      if (g.trim().isNotEmpty) g.trim(),
  ];
}

bool _matchesGroup(Element element, String group) {
  final parts = _parseParts(group);
  if (parts.isEmpty) return false;
  return _matchFrom(element, parts, parts.length - 1);
}

bool _matchFrom(Element el, List<_Part> parts, int i) {
  if (!parts[i].compound.matches(el)) return false;
  if (i == 0) return true;
  final comb = parts[i].combinator;
  switch (comb) {
    case ' ':
      for (var p = el.parent; p != null; p = p.parent) {
        if (_matchFrom(p, parts, i - 1)) return true;
      }
      return false;
    case '>':
      final p = el.parent;
      return p != null && _matchFrom(p, parts, i - 1);
    case '+':
      final s = el.prev;
      return s != null && _matchFrom(s, parts, i - 1);
    case '~':
      for (var s = el.prev; s != null; s = s.prev) {
        if (_matchFrom(s, parts, i - 1)) return true;
      }
      return false;
  }
  return false;
}

List<_Part> _parseParts(String group) {
  final parts = <_Part>[];
  final buf = StringBuffer();
  var depth = 0;
  String? comb;
  void flush() {
    if (buf.isEmpty) return;
    parts.add(_Part(parts.isEmpty ? null : (comb ?? ' '), _Compound.parse(buf.toString())));
    buf.clear();
    comb = null;
  }

  for (var i = 0; i < group.length; i++) {
    final c = group[i];
    if (depth == 0 && (c == ' ' || c == '\t' || c == '\n' || c == '\r')) {
      flush();
      continue;
    }
    if (depth == 0 && (c == '>' || c == '+' || c == '~')) {
      flush();
      comb = c;
      continue;
    }
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    buf.write(c);
  }
  flush();
  return parts;
}

final class _Part {
  final String? combinator;
  final _Compound compound;

  _Part(this.combinator, this.compound);
}

final class _Compound {
  final String? tag;
  final String? id;
  final List<String> classes;
  final List<_AttrSel> attrs;
  final List<String> pseudos;
  final List<String> nots;
  final List<String> has;

  _Compound(this.tag, this.id, this.classes, this.attrs, this.pseudos, this.nots, this.has);

  static _Compound parse(String src) {
    String? tag;
    String? id;
    final classes = <String>[];
    final attrs = <_AttrSel>[];
    final pseudos = <String>[];
    final nots = <String>[];
    final has = <String>[];

    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == '*') {
        tag = '*';
        i++;
      } else if (c == '#') {
        final m = RegExp(r'[A-Za-z0-9_\-]+').matchAsPrefix(src, i + 1);
        if (m != null) {
          id = m.group(0);
          i = m.end;
        } else {
          i++;
        }
      } else if (c == '.') {
        final m = RegExp(r'[A-Za-z0-9_\-]+').matchAsPrefix(src, i + 1);
        if (m != null) {
          classes.add(m.group(0)!);
          i = m.end;
        } else {
          i++;
        }
      } else if (c == '[') {
        final end = src.indexOf(']', i);
        if (end == -1) break;
        attrs.add(_AttrSel.parse(src.substring(i + 1, end)));
        i = end + 1;
      } else if (c == ':') {
        final nameMatch = RegExp(r'[A-Za-z\-]+').matchAsPrefix(src, i + 1);
        if (nameMatch == null) {
          i++;
          continue;
        }
        final name = nameMatch.group(0)!;
        if (!_pseudoNames.contains(name)) {
          throw FormatException('Unknown pseudo-class :$name in selector', src, i);
        }
        i = nameMatch.end;
        if (i < src.length && src[i] == '(') {
          var depth = 1;
          final start = i + 1;
          i++;
          while (i < src.length && depth > 0) {
            if (src[i] == '(') depth++;
            if (src[i] == ')') depth--;
            i++;
          }
          final inner = src.substring(start, i - 1);
          if (name == 'not') {
            nots.add(inner);
          } else if (name == 'has') {
            has.add(inner);
          } else {
            pseudos.add('$name($inner)');
          }
        } else {
          pseudos.add(name);
        }
      } else {
        final m = RegExp(r'[A-Za-z0-9_\-]+').matchAsPrefix(src, i);
        if (m != null) {
          if (tag == null || tag == '*') {
            tag = m.group(0);
          } else {
            tag = '$tag${m.group(0)}';
          }
          i = m.end;
        } else {
          i++;
        }
      }
    }
    return _Compound(tag, id, classes, attrs, pseudos, nots, has);
  }

  bool matches(Element el) {
    if (tag != null && tag != '*' && el.tag.toLowerCase() != tag!.toLowerCase()) return false;
    if (id != null && el.attrs['id'] != id) return false;
    if (classes.isNotEmpty) {
      final set = el.classes.toSet();
      for (final c in classes) {
        if (!set.contains(c)) return false;
      }
    }
    for (final attr in attrs) {
      if (!attr.matches(el)) return false;
    }
    for (final pseudo in pseudos) {
      if (!_matchPseudo(el, pseudo)) return false;
    }
    for (final not in nots) {
      if (_matchesSelector(el, not)) return false;
    }
    for (final inner in has) {
      final relative = inner.trimLeft();
      final ok = relative.startsWith('>')
          ? el.children.any((c) => _matchesSelector(c, relative.substring(1).trimLeft()))
          : _descendants(el).any((d) => _matchesSelector(d, inner));
      if (!ok) return false;
    }
    return true;
  }
}

/// The pseudo-classes the matcher knows; anything else is a [FormatException]
/// when the selector is parsed, never a silent match.
const _pseudoNames = {
  'first-child',
  'last-child',
  'only-child',
  'first-of-type',
  'last-of-type',
  'empty',
  'root',
  'nth-child',
  'nth-of-type',
  'contains',
  'has',
  'not',
};

/// Every descendant element of [el] in document order.
Iterable<Element> _descendants(Element el) sync* {
  for (final child in el.children) {
    yield child;
    yield* _descendants(child);
  }
}

bool _matchPseudo(Element el, String pseudo) {
  final open = pseudo.indexOf('(');
  final name = open == -1 ? pseudo : pseudo.substring(0, open);
  final arg = open == -1 ? null : pseudo.substring(open + 1, pseudo.length - 1);
  switch (name) {
    case 'first-child':
      return el.prev == null;
    case 'last-child':
      return el.next == null;
    case 'only-child':
      return el.prev == null && el.next == null;
    case 'first-of-type':
      return _siblingsOfType(el).first == el;
    case 'last-of-type':
      return _siblingsOfType(el).last == el;
    case 'empty':
      return el._nodes.isEmpty;
    case 'root':
      return el.tag == 'html' && (el.parent == null || el.parent!.tag == '#document');
    case 'nth-child':
      return _matchNth(el, arg!);
    case 'nth-of-type':
      return _matchNthOrdinal(_siblingsOfType(el).toList().indexOf(el) + 1, arg!);
    case 'contains':
      return el.text.contains(_unquote(arg!));
    case 'has':
      // Parsed structurally in [_Compound.has]; kept here for compound
      // strings that bypass the parser.
      return _descendants(el).any((d) => _matchesSelector(d, arg!));
  }
  return true;
}

/// A quoted (`'x'`/`"x"`) pseudo argument, unquoted.
String _unquote(String s) {
  final t = s.trim();
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

Iterable<Element> _siblingsOfType(Element el) =>
    (el.parent == null ? [el] : el.parent!.children).where((e) => e.tag == el.tag);

bool _matchNth(Element el, String expr) {
  // The wiring numbers each element among its siblings: no list is rebuilt.
  return _matchNthOrdinal(el._siblingIndex + 1, expr);
}

bool _matchNthOrdinal(int index, String expr) {
  final e = expr.replaceAll(' ', '').toLowerCase();
  if (e == 'odd') return index.isOdd;
  if (e == 'even') return index.isEven;
  final nIdx = e.indexOf('n');
  if (nIdx == -1) return index == int.tryParse(e);
  final a = e.substring(0, nIdx);
  final bPart = e.substring(nIdx + 1);
  final aVal = a.isEmpty || a == '+' ? 1 : (a == '-' ? -1 : int.parse(a));
  final bVal = bPart.isEmpty ? 0 : int.parse(bPart);
  if (aVal == 0) return index == bVal;
  final k = (index - bVal) / aVal;
  return k == k.roundToDouble() && k >= 0;
}

final class _AttrSel {
  final String name;
  final String? op;
  final String? value;

  _AttrSel(this.name, this.op, this.value);

  static _AttrSel parse(String src) {
    final m = RegExp(r'^\s*([A-Za-z0-9_\-]+)\s*(?:([~^$*|]?=)\s*(.*))?$').firstMatch(src);
    if (m == null) return _AttrSel(src.trim(), null, null);
    final raw = m.group(3);
    return _AttrSel(m.group(1)!, m.group(2), raw == null ? null : _unquote(raw.trim()));
  }

  bool matches(Element el) {
    final actual = el.attrs[name];
    if (actual == null) return false;
    if (op == null) return true;
    final v = value ?? '';
    return switch (op) {
      '=' => actual == v,
      '~=' => actual.split(RegExp(r'\s+')).contains(v),
      '^=' => actual.startsWith(v),
      r'$=' => actual.endsWith(v),
      '*=' => actual.contains(v),
      '|=' => actual == v || actual.startsWith('$v-'),
      _ => false,
    };
  }
}
