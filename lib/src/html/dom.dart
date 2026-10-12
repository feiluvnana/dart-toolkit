import 'dart:convert';

import '../core/pipe.dart';
import '../core/traits.dart';

/// A node in the document tree. Nodes are immutable: the parser freezes every
/// collection, and [Element.drop] copies instead of mutating.
sealed class Node {
  /// The parent element, if any. Set once, when the tree is assembled.
  late final Element? parent;

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

  @override
  String toString() => data;
}

/// An element with a [tag], [attrs] and child nodes. [children] holds the
/// element children only; text runs are [Text] nodes beside them.
final class Element extends Node {
  final String tag;
  final Map<String, String> attrs;
  final List<Node> _nodes;

  Element(this.tag, [Map<String, String>? attrs, List<Node>? nodes])
    : attrs = Map.unmodifiable(attrs ?? <String, String>{}),
      _nodes = List.unmodifiable(nodes ?? <Node>[]);

  /// The element children.
  List<Element> get children => List<Element>.unmodifiable(_nodes.whereType<Element>());

  /// The concatenated text of every descendant.
  @override
  String get text => _nodes.map((c) => c.text).join();

  /// The inner serialisation of the child nodes.
  String get html => _nodes.map((c) => c.toString()).join();

  /// One attribute, or [or] (default `null`).
  String? attr(String name, {String? or}) => attrs[name] ?? or;

  /// The `id` attribute.
  String? get id => attrs['id'];

  /// The class list.
  List<String> get classes => (attrs['class'] ?? '').split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();

  /// The previous sibling element, if any.
  Element? get prev {
    final siblings = parent?.children;
    if (siblings == null) return null;
    final i = siblings.indexOf(this) - 1;
    return i >= 0 ? siblings[i] : null;
  }

  /// The next sibling element, if any.
  Element? get next {
    final siblings = parent?.children;
    if (siblings == null) return null;
    final i = siblings.indexOf(this) + 1;
    return i < siblings.length ? siblings[i] : null;
  }

  /// The first element matching [css], searching this element then descendants.
  Element? find(String css) {
    if (matches(css)) return this;
    for (final el in children) {
      final hit = el.find(css);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Every element matching [css], in document order.
  List<Element> all(String css) => [if (matches(css)) this, for (final el in children) ...el.all(css)];

  /// A deep copy without the elements matching [css]; the receiver is
  /// unchanged, and itself always kept.
  Element drop(String css) => _copyExcept(this, css);

  /// Whether this element matches [css].
  bool matches(String css) => _matchesSelector(this, css);

  @override
  String toString() {
    final sb = StringBuffer('<$tag');
    attrs.forEach((name, value) => sb.write(' $name="${_escapeAttr(value)}"'));
    sb.write('>');
    for (final child in _nodes) {
      sb.write(child.toString());
    }
    sb.write('</$tag>');
    return sb.toString();
  }
}

String _escapeAttr(String v) => v.replaceAll('"', '&quot;');

/// A parsed document with a synthetic `#document` root.
final class Doc {
  final Element _root;

  Doc(this._root);

  /// The first element in the document matching [css].
  Element? find(String css) => _root.find(css);

  /// Every element in the document matching [css].
  List<Element> all(String css) => _root.all(css);

  /// The document's whole text.
  String get text => _root.text;

  /// The whole document's markup.
  String get html => _root.html;

  /// A deep copy without the elements matching [css]; the receiver is unchanged.
  Doc drop(String css) => Doc(_copyExcept(_root, css));

  /// Saves the document's markup to [to] (atomically for a file).
  Future<void> save(Target to) => utf8.encode(html).pipe(to);

  @override
  String toString() => html;
}

/// [src] deep-copied without the elements matching [css]; [src] itself is
/// always kept, so the copy never loses its root.
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
  final el = Element(src.tag, src.attrs, kids);
  for (final k in kids) {
    k.parent = el;
  }
  return el;
}

/// Assembles parsed top-level nodes into a [Doc]: implies `html > head + body`
/// around fragments, then wires every parent exactly once.
///
/// The parser builds mutable lists; this freezes them. Hidden from the topic
/// export: documents come from [Html.parse].
Doc assembleDocument(List<Node> topKids) {
  final structured = _implyStructure(topKids);
  final root = Element('#document', {}, structured);
  _wire(root, null);
  return Doc(root);
}

/// Wires every parent in [el]'s tree, exactly once.
void _wire(Element el, Element? parent) {
  el.parent = parent;
  for (final kid in el._nodes) {
    if (kid is Element) {
      _wire(kid, el);
    } else {
      kid.parent = el;
    }
  }
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
    final body = Element('body', {}, kids);
    final head = Element('head');
    return [
      Element('html', {}, [head, body]),
    ];
  }
  if (!htmlEl.children.any((el) => el.tag.toLowerCase() == 'body')) {
    final withBody = Element('html', htmlEl.attrs, [...htmlEl._nodes, Element('body')]);
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
      if (!_descendants(el).any((d) => _matchesSelector(d, inner))) return false;
    }
    return true;
  }
}

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
      return el.tag == 'html' || el.parent == null;
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
  final siblings = el.parent == null ? [el] : el.parent!.children;
  return _matchNthOrdinal(siblings.indexOf(el) + 1, expr);
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
