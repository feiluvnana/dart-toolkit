// CSS selectors, the part scrapers use: type, `#id`, `.class`, the seven attribute forms,
// the four combinators, selector lists, and the structural pseudo-classes.

part of '../../../formats.dart';

/// A compiled selector list.
final class _Selector {
  final List<_Complex> _alternatives;

  const _Selector._(this._alternatives);

  static final _cache = <(String, bool), _Selector>{};

  /// Parses [source], or returns the cached result. Throws [FormatException] on bad syntax.
  ///
  /// [fold] lowercases type and attribute names, which is what HTML wants and what XML,
  /// whose names are case-sensitive, does not.
  static _Selector parse(String source, {bool fold = true}) =>
      _cache[(source, fold)] ??= _Selector._(_SelectorParser(source, fold).parseList());

  /// Whether [e] matches.
  bool matches(Element e) => _withSiblings(() => _matches(e));

  bool _matches(Element e) => _alternatives.any((c) => c.matches(e));

  /// Every descendant of [root] that matches, in document order; [root] itself too when
  /// [includeSelf] is set.
  List<Element> matchAll(Element root, {bool includeSelf = false}) => _withSiblings(() {
    final out = <Element>[];
    void walk(Element e) {
      for (final n in e.nodes) {
        if (n is Element) {
          if (_matches(n)) out.add(n);
          walk(n);
        }
      }
    }

    if (includeSelf && _matches(root)) out.add(root);
    walk(root);
    return out;
  });
}

/// Where each element sits among its element siblings, for the length of one query.
///
/// The positional pseudo-classes and the sibling combinators all ask that question, and
/// asking the tree directly costs a scan per candidate — which makes a selector quadratic
/// in the number of siblings. This fills one list per parent and answers from it. It lives
/// for exactly one query: the tree cannot change underneath it, and the next query builds a
/// fresh one, so nothing can go stale.
final class _Siblings {
  final Map<Element, List<Element>> _children = {};
  final Map<Element, int> _index = {};
  final Map<(Element, String), (List<Element>, Map<Element, int>)> _byType = {};

  /// [parent]'s child elements, indexed on first use.
  List<Element> of(Element parent) => _children[parent] ??= () {
    final list = <Element>[];
    for (final node in parent.nodes) {
      if (node is Element) {
        _index[node] = list.length;
        list.add(node);
      }
    }
    return list;
  }();

  /// [e]'s 0-based position among its element siblings.
  int indexOf(Element e) {
    final parent = e.parent;
    if (parent == null) return 0;
    of(parent);
    return _index[e] ?? 0;
  }

  /// How many element siblings [e] has, itself included.
  int countOf(Element e) {
    final parent = e.parent;
    return parent == null ? 1 : of(parent).length;
  }

  (List<Element>, Map<Element, int>) _typed(Element e) {
    final parent = e.parent!;
    return _byType[(parent, e.name)] ??= () {
      final list = <Element>[];
      final index = <Element, int>{};
      for (final c in of(parent)) {
        if (c.name == e.name) {
          index[c] = list.length;
          list.add(c);
        }
      }
      return (list, index);
    }();
  }

  /// How many siblings share [e]'s tag name, itself included.
  int typeCountOf(Element e) => e.parent == null ? 1 : _typed(e).$1.length;

  /// [e]'s 0-based position among the siblings sharing its tag name.
  int typeIndexOf(Element e) => e.parent == null ? 0 : _typed(e).$2[e] ?? 0;

  /// The next element sibling, or `null`.
  Element? next(Element e) {
    final parent = e.parent;
    if (parent == null) return null;
    final kids = of(parent);
    final i = indexOf(e) + 1;
    return i < kids.length ? kids[i] : null;
  }

  /// The previous element sibling, or `null`.
  Element? previous(Element e) {
    final parent = e.parent;
    if (parent == null) return null;
    final i = indexOf(e) - 1;
    return i >= 0 ? of(parent)[i] : null;
  }
}

/// The index for the query in progress. A nested query — `:has()`, `:not()` — reuses the
/// enclosing one, since it walks the same tree.
_Siblings? _active;

T _withSiblings<T>(T Function() body) {
  final outer = _active;
  _active ??= _Siblings();
  try {
    return body();
  } finally {
    _active = outer;
  }
}

/// The active index. A predicate is only ever called from inside a query, so the fallback
/// is defensive: correct, just uncached.
_Siblings get _sibs => _active ?? _Siblings();

/// A chain of compound selectors and the combinators between them, matched right to left.
final class _Complex {
  final List<_Compound> compounds;
  final List<String> combinators; // between compounds[i] and compounds[i+1]

  const _Complex(this.compounds, this.combinators);

  bool matches(Element e) => _match(e, compounds.length - 1);

  bool _match(Element e, int i) {
    if (!compounds[i].matches(e)) return false;
    if (i == 0) return true;
    switch (combinators[i - 1]) {
      case '>':
        final p = e.parent;
        return p != null && _match(p, i - 1);
      case ' ':
        for (var p = e.parent; p != null; p = p.parent) {
          if (_match(p, i - 1)) return true;
        }
        return false;
      case '+':
        final prev = _sibs.previous(e);
        return prev != null && _match(prev, i - 1);
      case '~':
        for (var prev = _sibs.previous(e); prev != null; prev = _sibs.previous(prev)) {
          if (_match(prev, i - 1)) return true;
        }
        return false;
    }
    return false;
  }
}

final class _Compound {
  final String? type; // null or '*' means any
  final List<_Test> tests;

  const _Compound(this.type, this.tests);

  bool matches(Element e) {
    if (type != null && type != '*' && e.name != type) return false;
    for (final t in tests) {
      if (!t(e)) return false;
    }
    return true;
  }
}

typedef _Test = bool Function(Element e);

final class _SelectorParser {
  final String s;

  /// Whether a type or attribute name is matched case-insensitively; see [_Selector.parse].
  final bool fold;

  int i = 0;

  _SelectorParser(this.s, [this.fold = true]);

  String _name(String raw) => fold ? raw.toLowerCase() : raw;

  List<_Complex> parseList() {
    final out = <_Complex>[];
    while (true) {
      skipWs();
      out.add(parseComplex());
      skipWs();
      if (i >= s.length) return out;
      if (s[i] != ',') throw FormatException('Unexpected "${s[i]}" in selector', s, i);
      i++;
    }
  }

  _Complex parseComplex() {
    final compounds = <_Compound>[parseCompound()];
    final combinators = <String>[];
    while (true) {
      final hadWs = skipWs();
      if (i >= s.length || s[i] == ',' || s[i] == ')') break;
      var comb = ' ';
      if (s[i] == '>' || s[i] == '+' || s[i] == '~') {
        comb = s[i];
        i++;
        skipWs();
      } else if (!hadWs) {
        throw FormatException('Unexpected "${s[i]}" in selector', s, i);
      }
      combinators.add(comb);
      compounds.add(parseCompound());
    }
    return _Complex(compounds, combinators);
  }

  _Compound parseCompound() {
    String? type;
    final tests = <_Test>[];
    if (i < s.length && (s[i] == '*' || _isIdentStart(s.codeUnitAt(i)))) {
      type = s[i] == '*' ? '*' : _name(ident());
      if (type == '*') i++;
    }
    while (i < s.length) {
      final c = s[i];
      if (c == '#') {
        i++;
        final id = ident();
        tests.add((e) => e.attributes['id'] == id);
      } else if (c == '.') {
        i++;
        final cls = ident();
        tests.add((e) => _hasClass(e, cls));
      } else if (c == '[') {
        i++;
        tests.add(attribute());
      } else if (c == ':') {
        i++;
        tests.add(pseudo());
      } else {
        break;
      }
    }
    if (type == null && tests.isEmpty) {
      throw FormatException('Expected a selector', s, i);
    }
    return _Compound(type, tests);
  }

  _Test attribute() {
    skipWs();
    final name = _name(ident());
    skipWs();
    if (i < s.length && s[i] == ']') {
      i++;
      return (e) => e.attributes.containsKey(name);
    }
    var op = '=';
    if (i < s.length && s[i] != '=') {
      op = s[i];
      i++;
    }
    if (i >= s.length || s[i] != '=') throw FormatException('Expected "=" in attribute selector', s, i);
    i++;
    skipWs();
    final value = string();
    skipWs();
    var ci = false;
    if (i < s.length && (s[i] == 'i' || s[i] == 'I')) {
      ci = true;
      i++;
      skipWs();
    }
    expect(']');
    String norm(String v) => ci ? v.toLowerCase() : v;
    final want = norm(value);
    // `op` is the single character before the `=`, so only the bare forms can arrive here.
    return switch (op) {
      '=' => (e) => e.attributes[name] != null && norm(e.attributes[name]!) == want,
      '~' => (e) => e.attributes[name] != null && norm(e.attributes[name]!).split(_ws).contains(want),
      '|' => (e) {
        final v = e.attributes[name];
        return v != null && (norm(v) == want || norm(v).startsWith('$want-'));
      },
      '^=' || '^' => (e) => e.attributes[name] != null && norm(e.attributes[name]!).startsWith(want),
      '\$=' || '\$' => (e) => e.attributes[name] != null && norm(e.attributes[name]!).endsWith(want),
      '*=' || '*' => (e) => e.attributes[name] != null && norm(e.attributes[name]!).contains(want),
      _ => throw FormatException('Unknown attribute operator "$op="', s, i),
    };
  }

  _Test pseudo() {
    final name = ident().toLowerCase();
    String? arg;
    if (i < s.length && s[i] == '(') {
      i++;
      final depth = <int>[];
      final start = i;
      while (i < s.length && (s[i] != ')' || depth.isNotEmpty)) {
        if (s[i] == '(') depth.add(i);
        if (s[i] == ')') depth.removeLast();
        i++;
      }
      arg = s.substring(start, i).trim();
      expect(')');
    }
    // Every positional case requires a parent, as `:first-child` always has: these
    // pseudo-classes are about an element's place among siblings, and the root has none.
    switch (name) {
      case 'first-child':
        return (e) => e.parent != null && _sibs.indexOf(e) == 0;
      case 'last-child':
        return (e) => e.parent != null && _sibs.indexOf(e) == _sibs.countOf(e) - 1;
      case 'only-child':
        return (e) => e.parent != null && _sibs.countOf(e) == 1;
      case 'first-of-type':
        return (e) => e.parent != null && _sibs.typeIndexOf(e) == 0;
      case 'last-of-type':
        return (e) => e.parent != null && _sibs.typeIndexOf(e) == _sibs.typeCountOf(e) - 1;
      case 'nth-child':
        final f = _nth(arg ?? '');
        return (e) => e.parent != null && f(_sibs.indexOf(e) + 1);
      case 'nth-last-child':
        final f = _nth(arg ?? '');
        return (e) => e.parent != null && f(_sibs.countOf(e) - _sibs.indexOf(e));
      case 'nth-of-type':
        final f = _nth(arg ?? '');
        return (e) => e.parent != null && f(_sibs.typeIndexOf(e) + 1);
      case 'empty':
        return (e) => e.nodes.every((n) => n is Text && n.data.isEmpty);
      case 'not':
        final inner = _Selector.parse(arg ?? '');
        return (e) => !inner.matches(e);
      case 'has':
        final inner = _Selector.parse(arg ?? '');
        return (e) => inner.matchAll(e).isNotEmpty;
      case 'root':
        return (e) => e.parent == null;
      default:
        throw FormatException('Unsupported pseudo-class ":$name"', s, i);
    }
  }

  /// `odd`, `even`, `3`, `2n+1`, `-n+3` → a predicate on a 1-based index.
  static bool Function(int) _nth(String arg) {
    final t = arg.replaceAll(' ', '').toLowerCase();
    if (t == 'odd') return (n) => n.isOdd;
    if (t == 'even') return (n) => n.isEven;
    final m = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(t);
    if (m == null) {
      final k = int.tryParse(t);
      if (k == null) throw FormatException('Bad :nth-child argument "$arg"');
      return (n) => n == k;
    }
    final aStr = m[1]!;
    final a = aStr.isEmpty || aStr == '+'
        ? 1
        : aStr == '-'
        ? -1
        : int.parse(aStr);
    final b = int.tryParse(m[2] ?? '') ?? 0;
    return (n) {
      if (a == 0) return n == b;
      final k = n - b;
      return k % a == 0 && k ~/ a >= 0;
    };
  }

  String ident() {
    final start = i;
    while (i < s.length && _isIdentChar(s.codeUnitAt(i))) {
      i++;
    }
    if (i == start) throw FormatException('Expected an identifier', s, i);
    return s.substring(start, i);
  }

  String string() {
    if (i < s.length && (s[i] == '"' || s[i] == "'")) {
      final q = s[i];
      final end = s.indexOf(q, i + 1);
      if (end == -1) throw FormatException('Unterminated string in selector', s, i);
      final v = s.substring(i + 1, end);
      i = end + 1;
      return v;
    }
    final start = i;
    while (i < s.length && s[i] != ']' && !_isWs(s.codeUnitAt(i))) {
      i++;
    }
    return s.substring(start, i);
  }

  bool skipWs() {
    final start = i;
    while (i < s.length && _isWs(s.codeUnitAt(i))) {
      i++;
    }
    return i > start;
  }

  void expect(String c) {
    if (i >= s.length || s[i] != c) throw FormatException('Expected "$c" in selector', s, i);
    i++;
  }
}

bool _hasClass(Element e, String cls) {
  final attr = e.attributes['class'];
  if (attr == null || attr.isEmpty) return false;
  var start = 0;
  while (start < attr.length) {
    while (start < attr.length && _isWs(attr.codeUnitAt(start))) {
      start++;
    }
    var end = start;
    while (end < attr.length && !_isWs(attr.codeUnitAt(end))) {
      end++;
    }
    if (end - start == cls.length && attr.startsWith(cls, start)) return true;
    start = end;
  }
  return false;
}

bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;
bool _isIdentStart(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x2d || c > 0x7f;
bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);
