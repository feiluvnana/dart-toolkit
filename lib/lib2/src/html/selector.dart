import 'dom.dart';

/// Whether [element] matches the CSS [selector] (a comma-separated group list).
bool selectorMatches(Element element, String selector) {
  for (final group in _splitGroups(selector)) {
    if (_matchesGroup(element, group)) return true;
  }
  return false;
}

List<String> _splitGroups(String selector) {
  final groups = <String>[];
  var depth = 0;
  final buf = StringBuffer();
  for (final c in selector.split('')) {
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
      final s = el.previousElement;
      return s != null && _matchFrom(s, parts, i - 1);
    case '~':
      for (var s = el.previousElement; s != null; s = s.previousElement) {
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
      if (selectorMatches(el, not)) return false;
    }
    for (final inner in has) {
      if (!el.descendants.any((d) => selectorMatches(d, inner))) return false;
    }
    return true;
  }
}

bool _matchPseudo(Element el, String pseudo) {
  final open = pseudo.indexOf('(');
  final name = open == -1 ? pseudo : pseudo.substring(0, open);
  final arg = open == -1 ? null : pseudo.substring(open + 1, pseudo.length - 1);
  switch (name) {
    case 'first-child':
      return el.previousElement == null;
    case 'last-child':
      return el.nextElement == null;
    case 'only-child':
      return el.previousElement == null && el.nextElement == null;
    case 'first-of-type':
      return _siblingsOfType(el).first == el;
    case 'last-of-type':
      return _siblingsOfType(el).last == el;
    case 'empty':
      return el.children.isEmpty;
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
      return el.descendants.any((d) => selectorMatches(d, arg!));
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

Iterable<Element> _siblingsOfType(Element el) => (el.parent?.elements ?? [el]).where((e) => e.tag == el.tag);

bool _matchNth(Element el, String expr) {
  final siblings = el.parent?.elements.toList() ?? [el];
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

  static String _unquote(String s) {
    if (s.length >= 2 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
      return s.substring(1, s.length - 1);
    }
    return s;
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
