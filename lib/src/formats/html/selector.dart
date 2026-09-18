// CSS selectors, the part scrapers use: type, `#id`, `.class`, the seven attribute forms,
// the four combinators, selector lists, and the structural pseudo-classes.

part of '../../../formats.dart';

/// A compiled selector list.
final class _Selector {
  final List<_Complex> _alternatives;

  const _Selector._(this._alternatives);

  static final _cache = <String, _Selector>{};

  /// Parses [source], or returns the cached result. Throws [FormatException] on bad syntax.
  static _Selector parse(String source) => _cache[source] ??= _Selector._(_SelectorParser(source).parseList());

  /// Whether [e] matches.
  bool matches(Element e) => _alternatives.any((c) => c.matches(e));

  /// Every descendant of [root] that matches, in document order; [root] itself too when
  /// [includeSelf] is set.
  List<Element> matchAll(Element root, {bool includeSelf = false}) {
    final out = <Element>[];
    void walk(Element e) {
      for (final n in e.nodes) {
        if (n is Element) {
          if (matches(n)) out.add(n);
          walk(n);
        }
      }
    }

    if (includeSelf && matches(root)) out.add(root);
    walk(root);
    return out;
  }
}

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
        final prev = e.previousElement;
        return prev != null && _match(prev, i - 1);
      case '~':
        for (var prev = e.previousElement; prev != null; prev = prev.previousElement) {
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
  int i = 0;

  _SelectorParser(this.s);

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
      type = s[i] == '*' ? '*' : ident().toLowerCase();
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
    final name = ident().toLowerCase();
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
    return switch (op) {
      '=' => (e) => e.attributes[name] != null && norm(e.attributes[name]!) == want,
      '~=' || '~' => (e) => e.attributes[name] != null && norm(e.attributes[name]!).split(_ws).contains(want),
      '|=' || '|' => (e) {
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
    switch (name) {
      case 'first-child':
        return (e) => e.previousElement == null && e.parent != null;
      case 'last-child':
        return (e) => e.nextElement == null && e.parent != null;
      case 'only-child':
        return (e) => e.parent != null && e.previousElement == null && e.nextElement == null;
      case 'first-of-type':
        return (e) => _ofType(e).first == e;
      case 'last-of-type':
        return (e) => _ofType(e).last == e;
      case 'nth-child':
        final f = _nth(arg ?? '');
        return (e) => e.parent != null && f(e.parent!.children.toList().indexOf(e) + 1);
      case 'nth-last-child':
        final f = _nth(arg ?? '');
        return (e) {
          final kids = e.parent?.children.toList();
          return kids != null && f(kids.length - kids.indexOf(e));
        };
      case 'nth-of-type':
        final f = _nth(arg ?? '');
        return (e) => f(_ofType(e).indexOf(e) + 1);
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

  static List<Element> _ofType(Element e) => [
    for (final c in e.parent?.children ?? const <Element>[])
      if (c.name == e.name) c,
  ];

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
