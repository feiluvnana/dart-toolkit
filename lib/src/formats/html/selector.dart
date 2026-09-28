// CSS selectors, the part scrapers use: type, `#id`, `.class`, the seven attribute forms,
// the four combinators, selector lists, escapes, the structural pseudo-classes, and the
// logical ones — `:not`, `:is`, `:where`, and `:has` with a relative selector.

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
      _compiled(_cache, (source, fold), () => _Selector._(_SelectorParser(source, fold).parseList()));

  /// Whether [e] matches.
  bool matches(Element e) => _withSiblings(() => _matches(e));

  bool _matches(Element e) => _alternatives.any((c) => c.matches(e));

  /// Every descendant of [root] that matches, in document order; [root] itself too when
  /// [includeSelf] is set.
  List<Element> matchAll(Element root, {bool includeSelf = false}) => _withSiblings(() {
    final out = <Element>[];
    void walk(Element e, int depth) {
      for (final n in e.nodes) {
        if (n is! Element) continue;
        if (_matches(n)) out.add(n);
        if (depth < _deep) {
          walk(n, depth + 1);
        } else {
          _eachBelow(n, (m) {
            if (m is Element && _matches(m)) out.add(m);
            return false;
          });
        }
      }
    }

    if (includeSelf && _matches(root)) out.add(root);
    walk(root, 0);
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

  /// For each complex selector and compound index, which elements are already known to
  /// have — or not to have — a match for that compound and everything left of it somewhere
  /// along a combinator's walk; see [_Complex._along].
  final Map<_Complex, List<Map<Element, bool>?>> _reach = {};

  Map<Element, bool> reach(_Complex c, int i) =>
      (_reach[c] ??= List.filled(c.compounds.length, null))[i] ??= <Element, bool>{};

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

  /// Whether [compounds] starts with `:scope` — the relative selector inside `:has()` —
  /// whose answer depends on which element is the scope, so nothing about it is remembered.
  final bool relative;

  const _Complex(this.compounds, this.combinators, {this.relative = false});

  bool matches(Element e) => _match(e, compounds.length - 1);

  bool _match(Element e, int i) {
    if (!compounds[i].matches(e)) return false;
    if (i == 0) return true;
    return switch (combinators[i - 1]) {
      '>' => e.parent != null && _match(e.parent!, i - 1),
      ' ' => _along(e.parent, i - 1, _up),
      '+' => _sibs.previous(e) != null && _match(_sibs.previous(e)!, i - 1),
      _ => _along(_sibs.previous(e), i - 1, _sibs.previous),
    };
  }

  static Element? _up(Element e) => e.parent;

  /// Whether [start] or anything [step] reaches from it matches compound [i] and the rest
  /// of the chain to its left — the walk the descendant and sibling combinators make.
  ///
  /// Remembered per element for the length of the query. Without it, `p div div div span`
  /// in a hundred nested divs tried every way of assigning the divs to the compounds, which
  /// is exponential in their number: 413 ms for a page a browser answers instantly. Every
  /// element passed on the way gets the answer found, so each is walked past once.
  bool _along(Element? start, int i, Element? Function(Element) step) {
    if (start == null) return false;
    // Below two compounds from the left the walk is linear anyway, and remembering costs
    // more than it saves: `article h2 a` measured a third slower with it.
    if (i < 2 || relative) {
      for (Element? e = start; e != null; e = step(e)) {
        if (_match(e, i)) return true;
      }
      return false;
    }
    final known = _sibs.reach(this, i);
    final passed = <Element>[];
    var found = false;
    for (Element? e = start; e != null; e = step(e)) {
      final k = known[e];
      if (k != null) {
        found = k;
        break;
      }
      passed.add(e);
      if (_match(e, i)) {
        found = true;
        break;
      }
    }
    for (final e in passed) {
      known[e] = found;
    }
    return found;
  }
}

/// The elements `:scope` means, innermost `:has()` last.
final _scopes = <Element>[];

/// A relative selector, as `:has()` takes: `> img`, `+ dt`, `a` (a descendant).
final class _Relative {
  final _Complex complex;

  const _Relative(this.complex);

  /// Whether anything related to [scope] as this selector says matches it.
  bool matchesFrom(Element scope) {
    final combinators = complex.combinators;
    final siblingsOnly = combinators.every((c) => c == '+' || c == '~');
    final childrenOnly = combinators.every((c) => c == '>');
    _scopes.add(scope);
    try {
      bool test(Node e) => e is Element && complex.matches(e);
      if (combinators.first == '>' || combinators.first == ' ') {
        return _eachBelow(scope, test, depth: childrenOnly ? combinators.length : 1 << 30);
      }
      for (var s = _sibs.next(scope); s != null; s = _sibs.next(s)) {
        if (test(s) || (!siblingsOnly && _eachBelow(s, test))) return true;
        if (combinators.length == 1 && combinators.first == '+') break;
      }
      return false;
    } finally {
      _scopes.removeLast();
    }
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

  List<_Complex> parseList({bool relative = false}) {
    final out = <_Complex>[];
    while (true) {
      skipWs();
      out.add(parseComplex(relative: relative));
      skipWs();
      if (i >= s.length) return out;
      if (s[i] != ',') throw FormatException('Unexpected "${s[i]}" in selector', s, i);
      i++;
    }
  }

  /// A complex selector; with [relative], one that may start with a combinator and is
  /// anchored at `:scope` — a descendant of it when no combinator is written.
  _Complex parseComplex({bool relative = false}) {
    if (relative) {
      var comb = ' ';
      if (i < s.length && (s[i] == '>' || s[i] == '+' || s[i] == '~')) {
        comb = s[i];
        i++;
        skipWs();
      }
      final rest = parseComplex();
      return _Complex([_scopeCompound, ...rest.compounds], [comb, ...rest.combinators], relative: true);
    }
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
    if (i < s.length && (s[i] == '*' || _isIdentStart(s.codeUnitAt(i)) || s[i] == r'\')) {
      type = s[i] == '*' ? '*' : _name(ident());
      // An SVG element keeps its mixed case, and a folded `foreignobject` still finds it.
      if (fold) type = _svgTags[type] ?? type;
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
        tests.add((e) => _hasWord(e.attributes['class'], cls));
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
    // A folded `viewbox` also finds SVG's `viewBox`, which keeps its case.
    final svg = fold ? _svgAttributes[name] : null;
    String? of(Element e) => svg == null ? e.attributes[name] : e.attributes[name] ?? e.attributes[svg];
    skipWs();
    if (i < s.length && s[i] == ']') {
      i++;
      return (e) => of(e) != null;
    }
    var op = '';
    if (i < s.length && s[i] != '=') {
      op = s[i];
      i++;
    }
    if (i >= s.length || s[i] != '=') throw FormatException('Expected "=" in attribute selector', s, i);
    i++;
    op += '=';
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
    // A substring or word test for nothing matches nothing, as the spec has it; matching
    // every element with the attribute made `[class^=""]` a synonym for `[class]`.
    if (want.isEmpty && op != '=' && op != '|=') return (e) => false;
    _Test present(bool Function(String v) test) => (e) {
      final v = of(e);
      return v != null && test(norm(v));
    };
    return switch (op) {
      '=' => present((v) => v == want),
      '~=' => want.contains(_ws) ? (e) => false : (e) => _hasWord(ci ? of(e)?.toLowerCase() : of(e), want),
      '|=' => present((v) => v == want || v.startsWith('$want-')),
      '^=' => present((v) => v.startsWith(want)),
      '\$=' => present((v) => v.endsWith(want)),
      '*=' => present((v) => v.contains(want)),
      _ => throw FormatException('Unknown attribute operator "$op"', s, i),
    };
  }

  _Test pseudo() {
    final name = ident().toLowerCase();
    String? arg;
    if (i < s.length && s[i] == '(') {
      i++;
      var depth = 0;
      final start = i;
      String? quote;
      while (i < s.length && (s[i] != ')' || depth > 0 || quote != null)) {
        final c = s[i];
        if (c == r'\') {
          i += 2;
          continue;
        }
        if (quote != null) {
          if (c == quote) quote = null;
        } else if (c == '"' || c == "'") {
          quote = c;
        } else if (c == '(') {
          depth++;
        } else if (c == ')') {
          depth--;
        }
        i++;
      }
      arg = s.substring(start, i > s.length ? s.length : i).trim();
      expect(')');
    }
    // The root is the only element child of its document, so `html:first-child` matches it,
    // as it does in a browser.
    switch (name) {
      case 'first-child':
        return (e) => _sibs.indexOf(e) == 0;
      case 'last-child':
        return (e) => _sibs.indexOf(e) == _sibs.countOf(e) - 1;
      case 'only-child':
        return (e) => _sibs.countOf(e) == 1;
      case 'first-of-type':
        return (e) => _sibs.typeIndexOf(e) == 0;
      case 'last-of-type':
        return (e) => _sibs.typeIndexOf(e) == _sibs.typeCountOf(e) - 1;
      case 'only-of-type':
        return (e) => _sibs.typeCountOf(e) == 1;
      case 'nth-child':
        final f = _nth(arg ?? '');
        return (e) => f(_sibs.indexOf(e) + 1);
      case 'nth-last-child':
        final f = _nth(arg ?? '');
        return (e) => f(_sibs.countOf(e) - _sibs.indexOf(e));
      case 'nth-of-type':
        final f = _nth(arg ?? '');
        return (e) => f(_sibs.typeIndexOf(e) + 1);
      case 'nth-last-of-type':
        final f = _nth(arg ?? '');
        return (e) => f(_sibs.typeCountOf(e) - _sibs.typeIndexOf(e));
      // jQuery's, which every scraping library since has kept: the text contains [arg].
      case 'contains':
        final want = switch (arg ?? '') {
          final a when a.length >= 2 && (a[0] == '"' || a[0] == "'") && a.endsWith(a[0]) => a.substring(
            1,
            a.length - 1,
          ),
          final a => a,
        };
        return (e) => e.text.contains(want);
      case 'empty':
        return (e) => e.nodes.every((n) => n is Text && n.data.isEmpty);
      // A nested selector is read in the same markup as the one around it: on XML, where
      // names are case-sensitive, `:not(Item)` means `Item` and not `item`.
      case 'not':
        final inner = _Selector.parse(arg ?? '', fold: fold);
        return (e) => !inner.matches(e);
      case 'is' || 'where':
        final inner = _Selector.parse(arg ?? '', fold: fold);
        return inner.matches;
      case 'has':
        final relatives = [
          for (final c in (_SelectorParser(arg ?? '', fold)..skipWs()).parseList(relative: true)) _Relative(c),
        ];
        return (e) => relatives.any((r) => r.matchesFrom(e));
      case 'scope':
        return (e) => _scopes.isNotEmpty ? identical(e, _scopes.last) : e.parent == null;
      case 'root':
        return (e) => e.parent == null;
      default:
        throw FormatException('Unsupported pseudo-class ":$name"', s, i);
    }
  }

  /// `odd`, `even`, `3`, `2n+1`, `-n+3` → a predicate on a 1-based index.
  static final _anPlusB = RegExp(r'^([+-]?\d*)n([+-]\d+)?$');

  static bool Function(int) _nth(String arg) {
    final t = arg.replaceAll(' ', '').toLowerCase();
    if (t == 'odd') return (n) => n.isOdd;
    if (t == 'even') return (n) => n.isEven;
    final m = _anPlusB.firstMatch(t);
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

  /// An identifier, its escapes decoded: `md\:flex` is `md:flex`, `\31 23` is `123`.
  String ident() {
    final start = i;
    while (i < s.length && _isIdentChar(s.codeUnitAt(i))) {
      i++;
    }
    if (i < s.length && s[i] == r'\') {
      // The slow path, only for a name that has an escape in it: Tailwind's `md\:flex`.
      final sb = StringBuffer(s.substring(start, i));
      while (i < s.length) {
        if (s[i] == r'\') {
          sb.write(escape());
        } else if (_isIdentChar(s.codeUnitAt(i))) {
          sb.write(s[i++]);
        } else {
          break;
        }
      }
      return sb.toString();
    }
    if (i == start) throw FormatException('Expected an identifier', s, i);
    return s.substring(start, i);
  }

  /// The escape at [i] (a backslash): up to six hex digits and one optional space, or the
  /// next character as itself.
  String escape() {
    i++;
    if (i >= s.length) return '\u{fffd}';
    final from = i;
    while (i < s.length && i - from < 6 && _digit(s.codeUnitAt(i), true) >= 0) {
      i++;
    }
    if (i == from) return s[i++];
    final code = int.parse(s.substring(from, i), radix: 16);
    if (i < s.length && _isSpace(s.codeUnitAt(i))) i++;
    return code == 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ? '\u{fffd}' : String.fromCharCode(code);
  }

  String string() {
    if (i < s.length && (s[i] == '"' || s[i] == "'")) {
      final q = s[i];
      final start = i;
      i++;
      final sb = StringBuffer();
      while (true) {
        if (i >= s.length) throw FormatException('Unterminated string in selector', s, start);
        final c = s[i];
        if (c == q) {
          i++;
          return sb.toString();
        }
        c == r'\' ? sb.write(escape()) : sb.write(s[i++]);
      }
    }
    if (i < s.length && s[i] != ']' && !_isSpace(s.codeUnitAt(i))) return ident();
    return '';
  }

  bool skipWs() {
    final start = i;
    while (i < s.length && _isSpace(s.codeUnitAt(i))) {
      i++;
    }
    return i > start;
  }

  void expect(String c) {
    if (i >= s.length || s[i] != c) throw FormatException('Expected "$c" in selector', s, i);
    i++;
  }
}

/// Whether [value] has [word] as one of its whitespace-separated words — what `.class` and
/// `~=` ask — scanned in place rather than split into a list per element.
bool _hasWord(String? value, String word) {
  if (value == null || value.isEmpty) return false;
  var start = 0;
  while (start < value.length) {
    while (start < value.length && _isSpace(value.codeUnitAt(start))) {
      start++;
    }
    var end = start;
    while (end < value.length && !_isSpace(value.codeUnitAt(end))) {
      end++;
    }
    if (end - start == word.length && value.startsWith(word, start)) return true;
    start = end;
  }
  return false;
}

/// The compound a relative selector starts from: whatever element `:scope` is now.
final _scopeCompound = _Compound(null, [(e) => _scopes.isNotEmpty && identical(e, _scopes.last)]);

bool _isIdentStart(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x2d || c > 0x7f;
bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);
