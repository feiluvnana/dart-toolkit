/// CSS selectors (Selectors Level 4, the parts that apply to a static
/// tree) over `dom.dart`: type, `*`, `#id`, `.class`, attributes with
/// `= ~= |= ^= $= *=` and the `i`/`s` flags, the four combinators, and
/// `:first-child` `:last-child` `:only-child` `:first-of-type`
/// `:last-of-type` `:only-of-type` `:nth-child(An+B [of S])`
/// `:nth-last-child` `:nth-of-type` `:nth-last-of-type` `:not()` `:is()`
/// `:where()` `:has()` `:empty` `:root` `:link` `:any-link` `:checked`
/// `:disabled` `:enabled` `:lang()`. Pseudo-elements never match.
/// A bad selector is a [FormatException].
library;

import 'dom.dart';

/// A parsed selector list.
final class Selector {
  Selector._(this._list);

  final List<_Complex> _list;

  static Selector parse(String source) {
    final p = _Parser(source);
    final list = p.list();
    p.skipSpace();
    if (!p.done) throw p.error('unexpected "${p.peekChar}"');
    return Selector._(list);
  }

  /// Whether [e] matches.
  bool matches(Element e) {
    for (final c in _list) {
      if (c.matches(e, null)) return true;
    }
    return false;
  }

  /// Every descendant of [root] (not [root] itself) that matches, in
  /// document order.
  void collect(Element root, List<Element> out) {
    // An explicit stack: a page nested 10,000 deep must not overflow.
    final stack = <Element>[];
    void push(Element e) {
      final nodes = e.nodes;
      for (var i = nodes.length - 1; i >= 0; i--) {
        final n = nodes[i];
        if (n is Element) stack.add(n);
      }
    }

    push(root);
    while (stack.isNotEmpty) {
      final e = stack.removeLast();
      if (matches(e)) out.add(e);
      push(e);
    }
  }
}

/// The parent element, or null at the top (the holder of top-level nodes
/// is not an element of the document).
Element? up(Element e) {
  final p = e.parent;
  return p == null || p.localName == '#root' ? null : p;
}

/// [e]'s element siblings (itself included) and its index among them,
/// cached per parent until the parent's children change: every `+`, `~`
/// and `:nth-*` test asks, and a fresh list per test was O(n²) over a long
/// list (`li + li` on 20,000 items took 5 s).
(List<Element>, int) _position(Element e) {
  final p = e.parent;
  if (p == null) return ([e], 0);
  var c = _positions[p];
  if (c == null || c.$1 != p.edits) {
    final list = p.children.toList();
    c = (p.edits, list, Map<Element, int>.identity()..addAll({for (var i = 0; i < list.length; i++) list[i]: i}));
    _positions[p] = c;
  }
  return (c.$2, c.$3[e]!);
}

final _positions = Expando<(int, List<Element>, Map<Element, int>)>();

enum _Comb { descendant, child, adjacent, sibling }

final class _Complex {
  _Complex(this.parts, this.combs, [this.lead]);

  /// Left to right; [combs] `[k]` joins `parts[k]` and `parts[k + 1]`.
  final List<_Compound> parts;
  final List<_Comb> combs;

  /// For a relative selector (`:has(> a)`): the combinator before the
  /// first part, from the scope element.
  final _Comb? lead;

  bool matches(Element e, Element? scope) => _at(parts.length - 1, e, scope) == _matched;

  // How a failed match may resume (Servo's matching results): from the
  // closest later sibling, from the closest descendant combinator, or not
  // at all. Without them a chain of descendant combinators retries every
  // ancestor at every level: `section div div div` on 1,000 nested divs
  // took 400 s.
  static const _matched = 0, _laterSibling = 1, _descendant = 2, _globally = 3;

  int _at(int k, Element e, Element? scope) {
    if (!parts[k].matches(e)) return _laterSibling;
    if (k == 0) {
      final l = lead;
      if (l == null || scope == null) return _matched;
      return _joined(l, e, (x) => identical(x, scope) ? _matched : _laterSibling);
    }
    return _joined(combs[k - 1], e, (x) => _at(k - 1, x, scope));
  }

  static int _joined(_Comb comb, Element e, int Function(Element x) left) {
    final sibling = comb == _Comb.adjacent || comb == _Comb.sibling;
    List<Element>? sib;
    var i = 0;
    if (sibling) (sib, i) = _position(e);
    for (Element? x = sibling ? (i > 0 ? sib![--i] : null) : up(e); x != null;) {
      final r = left(x);
      if (r == _matched || r == _globally || comb == _Comb.adjacent) return r;
      if (comb == _Comb.child) return _descendant;
      if (comb == _Comb.sibling && r == _descendant) return r;
      x = sibling ? (i > 0 ? sib![--i] : null) : up(x);
    }
    return sibling ? _descendant : _globally;
  }
}

final class _Compound {
  _Compound(this.tag, this.tests);

  /// Lower-case type, or null for any.
  final String? tag;
  final List<bool Function(Element e)> tests;

  bool matches(Element e) {
    if (e.localName == '#root') return false; // the holder of top-level nodes
    final t = tag;
    if (t != null && (e.space == Space.html ? e.localName != t : e.localName.toLowerCase() != t)) return false;
    for (final test in tests) {
      if (!test(e)) return false;
    }
    return true;
  }
}

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0C || c == 0x0D;

bool _isNameStart(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80 || c == 0x5C;

bool _isName(int c) => _isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D;

final class _Parser {
  _Parser(this.s);

  final String s;
  var i = 0;

  bool get done => i >= s.length;

  String get peekChar => s[i];

  int get _c => s.codeUnitAt(i);

  FormatException error(String what) => FormatException('invalid selector: $what', s, i);

  void skipSpace() {
    while (!done && _isSpace(_c)) {
      i++;
    }
  }

  List<_Complex> list({bool relative = false}) {
    final out = <_Complex>[complex(relative: relative)];
    while (true) {
      skipSpace();
      if (done || _c != 0x2C) break;
      i++;
      out.add(complex(relative: relative));
    }
    return out;
  }

  _Comb? _combinator() {
    if (done) return null;
    return switch (_c) {
      0x3E => _Comb.child,
      0x2B => _Comb.adjacent,
      0x7E => _Comb.sibling,
      _ => null,
    };
  }

  _Complex complex({bool relative = false}) {
    skipSpace();
    _Comb? lead;
    if (relative) {
      lead = _combinator();
      if (lead != null) {
        i++;
        skipSpace();
      } else {
        lead = _Comb.descendant;
      }
    }
    final parts = <_Compound>[compound()];
    final combs = <_Comb>[];
    while (true) {
      final start = i;
      skipSpace();
      if (done || _c == 0x2C || _c == 0x29) {
        i = start;
        break;
      }
      final explicit = _combinator();
      if (explicit != null) {
        i++;
        skipSpace();
        combs.add(explicit);
      } else if (i > start) {
        combs.add(_Comb.descendant);
      } else {
        throw error('unexpected "$peekChar"');
      }
      parts.add(compound());
    }
    return _Complex(parts, combs, lead);
  }

  _Compound compound() {
    String? tag;
    final tests = <bool Function(Element)>[];
    if (!done && _c == 0x2A) {
      i++;
    } else if (!done && _isNameStart(_c)) {
      tag = ident().toLowerCase();
    }
    var any = tag != null || (i > 0 && s.codeUnitAt(i - 1) == 0x2A);
    while (!done) {
      final c = _c;
      if (c == 0x23) {
        i++;
        final id = ident();
        tests.add((e) => e.attributes['id'] == id);
      } else if (c == 0x2E) {
        i++;
        final cls = ident();
        tests.add((e) => _hasWord(e.attributes['class'], cls));
      } else if (c == 0x5B) {
        tests.add(attribute());
      } else if (c == 0x3A) {
        tests.add(pseudo());
      } else {
        break;
      }
      any = true;
    }
    if (!any) throw done ? error('expected a selector') : error('unexpected "$peekChar"');
    return _Compound(tag, tests);
  }

  String ident() {
    final out = StringBuffer();
    if (done) throw error('expected a name');
    if (_c == 0x2D) {
      out.write('-');
      i++;
    }
    if (done || !(_isNameStart(_c) || _c == 0x2D)) throw error('expected a name');
    while (!done && _isName(_c)) {
      if (_c == 0x5C) {
        out.write(_escape());
      } else {
        out.writeCharCode(_c);
        i++;
      }
    }
    return out.toString();
  }

  /// `\` then a hex code point (and one optional space) or any character.
  String _escape() {
    i++;
    if (done) return '�';
    final start = i;
    while (!done && i - start < 6 && _isHex(_c)) {
      i++;
    }
    if (i > start) {
      final code = int.parse(s.substring(start, i), radix: 16);
      if (!done && _isSpace(_c)) i++;
      return code == 0 || code > 0x10FFFF ? '�' : String.fromCharCode(code);
    }
    return s[i++];
  }

  static bool _isHex(int c) => (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);

  String string() {
    final q = _c;
    i++;
    final out = StringBuffer();
    while (!done && _c != q) {
      if (_c == 0x5C) {
        if (i + 1 < s.length && s.codeUnitAt(i + 1) == 0x0A) {
          i += 2;
          continue;
        }
        out.write(_escape());
      } else {
        out.writeCharCode(_c);
        i++;
      }
    }
    if (done) throw error('unterminated string');
    i++;
    return out.toString();
  }

  bool Function(Element) attribute() {
    i++; // [
    skipSpace();
    final name = ident().toLowerCase();
    skipSpace();
    if (done) throw error('unterminated attribute selector');
    if (_c == 0x5D) {
      i++;
      return (e) => _attr(e, name) != null;
    }
    String op;
    if (_c == 0x3D) {
      op = '=';
      i++;
    } else if (i + 1 < s.length && s.codeUnitAt(i + 1) == 0x3D && '~|^\$*'.contains(peekChar)) {
      op = peekChar;
      i += 2;
    } else {
      throw error('unexpected "$peekChar" in an attribute selector');
    }
    skipSpace();
    if (done) throw error('unterminated attribute selector');
    final value = _c == 0x22 || _c == 0x27 ? string() : ident();
    skipSpace();
    var fold = false;
    if (!done && (_c | 0x20) == 0x69) {
      fold = true;
      i++;
      skipSpace();
    } else if (!done && (_c | 0x20) == 0x73) {
      i++;
      skipSpace();
    }
    if (done || _c != 0x5D) throw error('unterminated attribute selector');
    i++;
    final want = fold ? value.toLowerCase() : value;
    return (e) {
      var v = _attr(e, name);
      if (v == null) return false;
      if (fold) v = v.toLowerCase();
      return switch (op) {
        '=' => v == want,
        '~' => _hasWord(v, want),
        '|' => v == want || v.startsWith('$want-'),
        '^' => want.isNotEmpty && v.startsWith(want),
        r'$' => want.isNotEmpty && v.endsWith(want),
        _ => want.isNotEmpty && v.contains(want),
      };
    };
  }

  static String? _attr(Element e, String name) {
    final v = e.attributes[name];
    if (v != null || e.space == Space.html) return v;
    for (final k in e.attributes.keys) {
      if (k.toLowerCase() == name) return e.attributes[k];
    }
    return null;
  }

  bool Function(Element) pseudo() {
    i++; // :
    if (!done && _c == 0x3A) {
      i++;
      ident();
      if (!done && _c == 0x28) _skipArgs();
      return (_) => false; // pseudo-elements are not elements
    }
    final name = ident().toLowerCase();
    if (!done && _c == 0x28) {
      i++;
      final test = _function(name);
      skipSpace();
      if (done || _c != 0x29) throw error('missing ")" after :$name(');
      i++;
      return test;
    }
    return switch (name) {
      'first-child' => (e) => _index(e, false, false) == 1,
      'last-child' => (e) => _index(e, true, false) == 1,
      'only-child' => (e) => _index(e, false, false) == 1 && _index(e, true, false) == 1,
      'first-of-type' => (e) => _index(e, false, true) == 1,
      'last-of-type' => (e) => _index(e, true, true) == 1,
      'only-of-type' => (e) => _index(e, false, true) == 1 && _index(e, true, true) == 1,
      'empty' => (e) => e.nodes.every((n) => n is Text && n.data.isEmpty),
      'root' => (e) => up(e) == null,
      'link' || 'any-link' => (e) => const {'a', 'area'}.contains(e.localName) && e.attributes.containsKey('href'),
      'visited' || 'hover' || 'active' || 'focus' || 'focus-within' || 'focus-visible' || 'target' => (_) => false,
      'checked' =>
        (e) =>
            (e.localName == 'input' && e.attributes.containsKey('checked')) ||
            (e.localName == 'option' && e.attributes.containsKey('selected')),
      'disabled' => _disabled,
      'enabled' => (e) => _formControls.contains(e.localName) && !_disabled(e),
      'before' || 'after' || 'first-line' || 'first-letter' => (_) => false,
      _ => throw error('unknown pseudo-class ":$name"'),
    };
  }

  void _skipArgs() {
    var depth = 0;
    while (!done) {
      if (_c == 0x28) depth++;
      if (_c == 0x29 && --depth == 0) {
        i++;
        return;
      }
      i++;
    }
    throw error('missing ")"');
  }

  bool Function(Element) _function(String name) {
    skipSpace();
    switch (name) {
      case 'not':
        final list = this.list();
        return (e) => !list.any((c) => c.matches(e, null));
      case 'is' || 'where' || 'matches' || 'any':
        final list = this.list();
        return (e) => list.any((c) => c.matches(e, null));
      case 'has':
        final list = this.list(relative: true);
        return (e) => list.any((c) => _has(c, e));
      case 'lang':
        final want = (_c == 0x22 || _c == 0x27 ? string() : ident()).toLowerCase();
        return (e) {
          for (Element? n = e; n != null; n = up(n)) {
            final lang = n.attributes['lang'];
            if (lang != null) {
              final l = lang.toLowerCase();
              return l == want || l.startsWith('$want-');
            }
          }
          return false;
        };
      case 'nth-child' || 'nth-last-child' || 'nth-of-type' || 'nth-last-of-type':
        final (a, b) = _nth();
        List<_Complex>? of;
        skipSpace();
        if (name.endsWith('child') &&
            !done &&
            s.startsWith('of', i) &&
            i + 2 < s.length &&
            _isSpace(s.codeUnitAt(i + 2))) {
          i += 2;
          of = list();
        }
        final last = name.contains('last'), type = name.endsWith('type');
        return (e) {
          if (of != null && !of.any((c) => c.matches(e, null))) return false;
          final n = _index(e, last, type, of);
          return a == 0 ? n == b : (n - b) % a == 0 && (n - b) ~/ a >= 0;
        };
      default:
        throw error('unknown pseudo-class ":$name()"');
    }
  }

  /// `An+B`, `odd`, `even`.
  (int, int) _nth() {
    final start = i;
    while (!done && _c != 0x29 && !(s.startsWith(' of ', i))) {
      i++;
    }
    final text = s.substring(start, i).replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (text == 'odd') return (2, 1);
    if (text == 'even') return (2, 0);
    final m = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(text);
    if (m != null) {
      final a = switch (m[1]!) {
        '' || '+' => 1,
        '-' => -1,
        final v => int.parse(v),
      };
      return (a, m[2] == null ? 0 : int.parse(m[2]!));
    }
    final b = int.tryParse(text);
    if (b == null) throw FormatException('invalid selector: bad An+B "$text"', s, start);
    return (0, b);
  }
}

/// Whether some element related to [scope] by [c]'s leading combinator
/// matches [c] (`:has()`).
bool _has(_Complex c, Element scope) {
  switch (c.lead!) {
    case _Comb.descendant || _Comb.child:
      final stack = [...scope.children];
      while (stack.isNotEmpty) {
        final e = stack.removeLast();
        if (c.matches(e, scope)) return true;
        stack.addAll(e.children);
      }
      return false;
    case _Comb.adjacent || _Comb.sibling:
      final (sib, at) = _position(scope);
      for (var k = at + 1; k < sib.length; k++) {
        final stack = [sib[k]];
        while (stack.isNotEmpty) {
          final e = stack.removeLast();
          if (c.matches(e, scope)) return true;
          stack.addAll(e.children);
        }
      }
      return false;
  }
}

const _formControls = {'button', 'input', 'select', 'textarea', 'optgroup', 'option', 'fieldset'};

bool _disabled(Element e) {
  if (!_formControls.contains(e.localName)) return false;
  if (e.attributes.containsKey('disabled')) return true;
  for (var p = up(e); p != null; p = up(p)) {
    if (p.localName == 'fieldset' && p.attributes.containsKey('disabled')) return true;
  }
  return false;
}

bool _hasWord(String? value, String word) {
  if (value == null || word.isEmpty) return false;
  var start = -1;
  for (var k = 0; k <= value.length; k++) {
    final space = k == value.length || _isSpace(value.codeUnitAt(k));
    if (space) {
      if (start >= 0 && k - start == word.length && value.startsWith(word, start)) return true;
      start = -1;
    } else if (start < 0) {
      start = k;
    }
  }
  return false;
}

/// [e]'s 1-based position among its element siblings (from the end when
/// [last]), counting only its type when [type], or only those matching [of].
int _index(Element e, bool last, bool type, [List<_Complex>? of]) {
  final (sib, at) = _position(e);
  if (!type && of == null) return last ? sib.length - at : at + 1;
  var n = 0;
  final range = last ? sib.reversed : sib;
  for (final x in range) {
    if (type && x.localName != e.localName) continue;
    if (of != null && !of.any((c) => c.matches(x, null))) continue;
    n++;
    if (identical(x, e)) return n;
  }
  return n;
}
