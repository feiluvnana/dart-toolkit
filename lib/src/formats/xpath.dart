part of '../../formats.dart';

/// What kind of node a [Node] is, as XPath sees it.
///
/// {@category Formats}
enum _XPathKind { document, element, attribute, text }

/// How the engine reads the one markup tree. These are the whole contract an XPath has
/// with a [Node]; they were an interface while HTML and XML had a tree each.
_XPathKind _kind(Node n) => switch (n) {
  Element() => _XPathKind.element,
  Text() => _XPathKind.text,
  Attribute() => _XPathKind.attribute,
  _Document() => _XPathKind.document,
};

/// The parent, or the document node above the root element, or `null` above that.
Node? _up(Node n) => switch (n) {
  _Document() => null,
  Element(parent: null) => _Document(n),
  _ => n.parent,
};

/// Child nodes of an element, or the root element of a document node.
List<Node> _down(Node n) => switch (n) {
  Element() => n.nodes,
  _Document() => [n.root],
  _ => const [],
};

/// The qualified name of an element or attribute; `''` otherwise.
String _nameOf(Node n) => switch (n) {
  Element() => n.name,
  Attribute() => n.name,
  _ => '',
};

/// An element's attributes, or `null`.
Map<String, String>? _attrsOf(Node n) => n is Element ? n.attributes : null;

/// The string value: descendant text, text data, or an attribute's value.
String _textOf(Node n) => n.text;

/// A node standing for the attribute [name]=[value] on [owner].
Node _attributeOf(Node owner, String name, String value) => Attribute(name, value, owner as Element);

/// A node standing for the document that holds [root].
Node _documentOf(Node root) => root is _Document ? root : _Document(root as Element);

/// A compiled XPath 1.0 expression, the subset feeds, sitemaps, API responses and scraped
/// pages need: location paths with the child, descendant, parent, self, attribute, ancestor
/// and sibling axes and their abbreviations; `*`, `prefix:*`, `text()`, `node()`; predicates
/// with positions, comparisons, `and`, `or`, `not()`, `contains()`, `starts-with()`,
/// `normalize-space()`, `string()`, `count()`, `last()`, `position()`, `name()`,
/// `local-name()`; and union with `|`.
///
/// Parsed once per expression and cached. `html` exposes it as `$x`, `xml` as `$`.
///
/// {@category Formats}
final class _XPath {
  final _XNode _root;

  const _XPath._(this._root);

  static final _cache = <String, _XPath>{};

  /// Compiles [source], or returns the cached result. Throws [FormatException] on bad syntax.
  static _XPath parse(String source) {
    final cached = _cache[source];
    if (cached != null) return cached;
    if (_cache.length >= 256) _cache.remove(_cache.keys.first);
    return _cache[source] = _XPath._(_XPathParser(source).parse());
  }

  /// The nodes this expression selects with [context] as the context node, in document
  /// order. An absolute path starts at the document above [context]'s root element.
  ///
  /// Throws [FormatException] when the expression evaluates to a string, number or boolean.
  List<Node> select(Node context) {
    var root = context;
    for (var p = _up(root); p != null && _kind(p) != _XPathKind.document; p = _up(p)) {
      root = p;
    }
    final value = _root.eval(_Ctx(context, 1, 1, _documentOf(root)));
    if (value is! List<Node>) throw FormatException('XPath does not select nodes: it evaluates to $value');
    return [
      for (final n in value)
        if (_kind(n) != _XPathKind.document) n,
    ];
  }
}

final class _Ctx {
  final Node node;
  final int position;
  final int size;
  final Node document;

  /// Shared with every context this one spawns, so [order] is built once per query.
  final _Order _shared;

  /// Shared for the same reason; see [_Slots].
  final _Slots _slots;

  _Ctx(this.node, this.position, this.size, this.document) : _shared = _Order(), _slots = _Slots();

  _Ctx._(this.node, this.position, this.size, this.document, this._shared, this._slots);

  _Ctx at(Node n, int position, int size) => _Ctx._(n, position, size, document, _shared, _slots);

  /// Every node's position in document order, built once per query; see [_Order].
  Map<Node, int> get order => _shared.of(this);

  /// Where [child] sits among [parent]'s children; see [_Slots].
  int slotOf(Node parent, Node child) => _slots.of(parent, child);
}

/// Where each node sits in its parent's child list, filled one parent at a time and kept
/// for the length of one query.
///
/// The sibling axes each need a node's slot before they can walk away from it, and asking
/// the list with `indexOf` costs a scan per node — which makes `following-sibling` over n
/// siblings quadratic. The CSS engine keeps the same index for the same reason. It lives
/// for exactly one query: the tree cannot change underneath it.
final class _Slots {
  final Map<Node, int> _slot = {};
  final Set<Node> _indexed = {};

  int of(Node parent, Node child) {
    if (_indexed.add(parent)) {
      final children = _down(parent);
      for (var i = 0; i < children.length; i++) {
        _slot[children[i]] = i;
      }
    }
    return _slot[child] ?? -1;
  }
}

/// Document order, shared by every context in one query.
///
/// Every node in the tree gets a position, attributes included — which means allocating an
/// attribute node per attribute to key the map with, and is why the walk is worth doing at
/// most once per query however many unions and predicates need to sort.
///
/// Two cheaper-looking shapes were tried and are both slower, measured: computing a
/// (owner, slot) key inside the comparator (no attribute nodes allocated, but four map
/// lookups per comparison instead of one), and the same key precomputed per node (one small
/// map per owning element — thousands of tiny allocations for one large one). The one big
/// map wins; see `audit/bench5.dart`.
final class _Order {
  Map<Node, int>? _map;

  Map<Node, int> of(_Ctx c) => _map ??= () {
    final order = <Node, int>{};
    var i = 0;
    void walk(Node n) {
      order[n] = i++;
      final attrs = _attrsOf(n);
      if (attrs != null) {
        for (final MapEntry(:key, :value) in attrs.entries) {
          order[Attribute(key, value, n as Element)] = i++;
        }
      }
      for (final child in _down(n)) {
        walk(child);
      }
    }

    walk(c.document);
    return order;
  }();
}

// ---------------------------------------------------------------------------------------------
// Expression tree. Values are List<Node> (a node-set), String, double or bool.
// ---------------------------------------------------------------------------------------------

sealed class _XNode {
  const _XNode();
  Object eval(_Ctx c);
}

final class _Literal extends _XNode {
  final Object value;
  const _Literal(this.value);
  @override
  Object eval(_Ctx c) => value;
}

final class _XPathExpr extends _XNode {
  final bool absolute;
  final _XNode? filter; // a filter expression the path continues from, e.g. `(//a)[1]/b`
  final List<_XStep> steps;
  const _XPathExpr(this.absolute, this.steps, {this.filter});

  @override
  Object eval(_Ctx c) {
    List<Node> current;
    if (filter != null) {
      final v = filter!.eval(c);
      if (v is! List<Node>) throw const FormatException('A path must start from a node-set');
      current = v;
    } else {
      current = [absolute ? c.document : c.node];
    }
    for (final step in steps) {
      final next = <Node>[];
      final seen = <Node>{};
      for (final n in current) {
        for (final m in step.apply(c, n)) {
          if (seen.add(m)) next.add(m);
        }
      }
      current = next;
    }
    // These axes keep document order; after any other one the per-context results
    // interleave and the set is put back in order.
    //
    // The descendant axes belong here too, which is what spares `//x` the order map
    // entirely: context nodes arrive in document order, and a node's subtree is a
    // contiguous run of it, so the runs either nest — and the inner one's nodes were
    // already emitted by the outer, where `seen` keeps them — or follow one another.
    if (current.length > 1 && (steps.length > 1 || filter != null) && steps.any((s) => !_ordered.contains(s.axis))) {
      final order = c.order;
      current.sort((x, y) => (order[x] ?? -1).compareTo(order[y] ?? -1));
    }
    return current;
  }

  static const _ordered = {'child', 'self', 'attribute', 'descendant', 'descendant-or-self'};
}

/// A node-set with predicates applied to it as a whole: `(//item)[2]`.
final class _Filter extends _XNode {
  final _XNode primary;
  final List<_XNode> predicates;
  const _Filter(this.primary, this.predicates);

  @override
  Object eval(_Ctx c) {
    final v = primary.eval(c);
    if (v is! List<Node>) throw const FormatException('A predicate needs a node-set');
    var nodes = v;
    if (nodes.length > 1) {
      final order = c.order;
      nodes = nodes.toList()..sort((x, y) => (order[x] ?? -1).compareTo(order[y] ?? -1));
    }
    for (final p in predicates) {
      final kept = <Node>[];
      for (var i = 0; i < nodes.length; i++) {
        final r = p.eval(c.at(nodes[i], i + 1, nodes.length));
        if (r is double ? r == i + 1 : _bool(r)) kept.add(nodes[i]);
      }
      nodes = kept;
    }
    return nodes;
  }
}

final class _Union extends _XNode {
  final _XNode left, right;
  const _Union(this.left, this.right);
  @override
  Object eval(_Ctx c) {
    final a = left.eval(c), b = right.eval(c);
    if (a is! List<Node> || b is! List<Node>) throw const FormatException('| needs node-sets on both sides');
    final order = c.order;
    return <Node>{...a, ...b}.toList()..sort((x, y) => (order[x] ?? -1).compareTo(order[y] ?? -1));
  }
}

final class _Binary extends _XNode {
  final String op;
  final _XNode left, right;
  const _Binary(this.op, this.left, this.right);

  @override
  Object eval(_Ctx c) {
    switch (op) {
      case 'or':
        return _bool(left.eval(c)) || _bool(right.eval(c));
      case 'and':
        return _bool(left.eval(c)) && _bool(right.eval(c));
    }
    final a = left.eval(c), b = right.eval(c);
    return switch (op) {
      '=' => _compare(a, b, (x, y) => x == y, (x, y) => x == y),
      '!=' => _compare(a, b, (x, y) => x != y, (x, y) => x != y),
      '<' => _compare(a, b, (x, y) => _num(x) < _num(y), (x, y) => x < y),
      '>' => _compare(a, b, (x, y) => _num(x) > _num(y), (x, y) => x > y),
      '<=' => _compare(a, b, (x, y) => _num(x) <= _num(y), (x, y) => x <= y),
      '>=' => _compare(a, b, (x, y) => _num(x) >= _num(y), (x, y) => x >= y),
      '+' => _numOf(a) + _numOf(b),
      '-' => _numOf(a) - _numOf(b),
      _ => throw FormatException('Unknown operator $op'),
    };
  }

  /// XPath 1.0 comparison: a node-set compares by the string value of any of its nodes.
  static bool _compare(Object a, Object b, bool Function(String, String) str, bool Function(double, double) num) {
    if (a is List<Node> && b is List<Node>) return a.any((x) => b.any((y) => str(_textOf(x), _textOf(y))));
    if (a is List<Node>) return a.any((x) => _compare(_textOf(x), b, str, num));
    if (b is List<Node>) return b.any((y) => _compare(a, _textOf(y), str, num));
    if (a is bool || b is bool) return str(_bool(a).toString(), _bool(b).toString());
    if (a is double || b is double) return num(_num(a), _num(b));
    return str(_string(a), _string(b));
  }
}

final class _Negate extends _XNode {
  final _XNode inner;
  const _Negate(this.inner);
  @override
  Object eval(_Ctx c) => -_numOf(inner.eval(c));
}

final class _Call extends _XNode {
  final String name;
  final List<_XNode> args;
  const _Call(this.name, this.args);

  @override
  Object eval(_Ctx c) {
    Object arg(int i) => args[i].eval(c);
    String s(int i) => args.length > i ? _stringOf(arg(i)) : _textOf(c.node);
    Node? first() {
      if (args.isEmpty) return c.node;
      final v = arg(0);
      return v is List<Node> && v.isNotEmpty ? v.first : null;
    }

    switch (name) {
      case 'last':
        return c.size.toDouble();
      case 'position':
        return c.position.toDouble();
      case 'count':
        final v = arg(0);
        if (v is! List<Node>) throw const FormatException('count() needs a node-set');
        return v.length.toDouble();
      case 'not':
        return !_bool(arg(0));
      case 'true':
        return true;
      case 'false':
        return false;
      case 'string':
        return s(0);
      case 'number':
        return args.isEmpty ? _num(_textOf(c.node)) : _numOf(arg(0));
      case 'boolean':
        return _bool(arg(0));
      case 'contains':
        return s(0).contains(s(1));
      case 'starts-with':
        return s(0).startsWith(s(1));
      case 'ends-with':
        return s(0).endsWith(s(1));
      case 'string-length':
        return s(0).length.toDouble();
      case 'normalize-space':
        return s(0).trim().replaceAll(_spaces, ' ');
      case 'concat':
        return [for (var i = 0; i < args.length; i++) s(i)].join();
      case 'substring-before':
        final a = s(0), b = s(1);
        final i = a.indexOf(b);
        return i == -1 ? '' : a.substring(0, i);
      case 'substring-after':
        final a = s(0), b = s(1);
        final i = a.indexOf(b);
        return i == -1 ? '' : a.substring(i + b.length);
      case 'name':
        final n = first();
        return n == null ? '' : _nameOf(n);
      case 'local-name':
        final n = first();
        return n == null ? '' : _nameOf(n).split(':').last;
    }
    throw FormatException('Unsupported XPath function $name()');
  }
}

final _spaces = RegExp(r'\s+');

// ---------------------------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------------------------

/// `descendant-or-self::node()/child::x` is exactly `descendant::x`, and `//x` parses as
/// the first. Written out, the step pair walks every node in the document — text nodes
/// included — and then takes the children of each; the single step walks the subtree once.
///
/// Only when the child step carries no predicate. `//p[1]` is the first `p` of each parent,
/// where `descendant::p[1]` would be the first `p` in the document.
List<_XStep> _collapse(List<_XStep> steps) {
  final out = <_XStep>[];
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final next = i + 1 < steps.length ? steps[i + 1] : null;
    if (step.axis == 'descendant-or-self' &&
        step.test == null &&
        step.predicates.isEmpty &&
        next != null &&
        next.axis == 'child' &&
        next.predicates.isEmpty) {
      out.add(_XStep('descendant', next.test, const []));
      i++;
    } else {
      out.add(step);
    }
  }
  return out;
}

final class _XStep {
  final String axis;

  /// `null` is `node()`, `*` any element, `text()` text nodes, `p:*` a prefix, else a name.
  final String? test;
  final List<_XNode> predicates;

  const _XStep(this.axis, this.test, this.predicates);

  List<Node> apply(_Ctx c, Node context) {
    final reverse = axis == 'ancestor' || axis == 'ancestor-or-self' || axis == 'preceding-sibling';
    // `[k]` is the k-th match and nothing after it, so on a forward axis the walk stops
    // there rather than collecting the axis and throwing all but one away:
    // `following-sibling::li[1]` is the next sibling, not every following sibling.
    // A reverse axis counts from the context node, so it has to know how many there are.
    if (!reverse) {
      final k = _pinned;
      if (k != null) {
        var matched = 0;
        for (final n in _axis(c, context)) {
          if (_matches(n) && ++matched == k) return [n];
        }
        return const [];
      }
    }
    var candidates = [
      for (final n in _axis(c, context))
        if (_matches(n)) n,
    ];
    for (final p in predicates) {
      final kept = <Node>[];
      final size = candidates.length;
      for (var i = 0; i < size; i++) {
        final position = reverse ? size - i : i + 1;
        final v = p.eval(c.at(candidates[i], position, size));
        if (v is double ? v == position : _bool(v)) kept.add(candidates[i]);
      }
      candidates = kept;
    }
    return candidates;
  }

  /// The one position a lone numeric predicate pins this step to — 1 for `[1]` — or `null`
  /// when the step selects by anything else.
  int? get _pinned {
    if (predicates.length != 1) return null;
    final only = predicates.first;
    if (only is! _Literal) return null;
    final k = only.value;
    return k is double && k >= 1 && k == k.roundToDouble() ? k.toInt() : null;
  }

  bool _matches(Node n) {
    final test = this.test;
    final kind = _kind(n);
    if (test == null) return kind != _XPathKind.document;
    if (test == 'text()') return kind == _XPathKind.text;
    if (kind != _XPathKind.element && kind != _XPathKind.attribute) return false;
    if (test == '*') return true;
    final name = _nameOf(n);
    if (test.endsWith(':*')) return name.startsWith(test.substring(0, test.length - 1));
    return name == test;
  }

  Iterable<Node> _axis(_Ctx c, Node n) sync* {
    switch (axis) {
      case 'child':
        yield* _down(n);
      case 'descendant':
        yield* _descendants(n);
      case 'descendant-or-self':
        yield n;
        yield* _descendants(n);
      case 'parent':
        final p = _up(n);
        if (p != null) yield p;
      case 'ancestor':
        for (var p = _up(n); p != null; p = _up(p)) {
          yield p;
        }
      case 'ancestor-or-self':
        yield n;
        for (var p = _up(n); p != null; p = _up(p)) {
          yield p;
        }
      case 'self':
        yield n;
      case 'attribute':
        final attrs = _attrsOf(n);
        if (attrs != null) {
          for (final MapEntry(:key, :value) in attrs.entries) {
            yield _attributeOf(n, key, value);
          }
        }
      // `yield*` over a range hands the whole run to the caller's iterator; yielding the
      // nodes one at a time suspends this generator once per sibling and measured slower.
      case 'following-sibling':
        final p = _up(n);
        if (p != null) {
          final siblings = _down(p);
          final from = c.slotOf(p, n) + 1;
          if (from < siblings.length) yield* siblings.getRange(from, siblings.length);
        }
      case 'preceding-sibling':
        final p = _up(n);
        if (p != null) {
          final siblings = _down(p);
          final before = c.slotOf(p, n);
          if (before > 0) yield* [for (var i = before - 1; i >= 0; i--) siblings[i]];
        }
      default:
        throw FormatException('Unsupported axis $axis::');
    }
  }

  static Iterable<Node> _descendants(Node n) sync* {
    for (final c in _down(n)) {
      yield c;
      yield* _descendants(c);
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------------------------

bool _bool(Object v) => switch (v) {
  final bool b => b,
  final double d => d != 0 && !d.isNaN,
  final String s => s.isNotEmpty,
  final List<Object> l => l.isNotEmpty,
  _ => false,
};

double _num(Object v) => switch (v) {
  final double d => d,
  final bool b => b ? 1 : 0,
  final String s => double.tryParse(s.trim()) ?? double.nan,
  _ => double.nan,
};

double _numOf(Object v) => v is List<Node> ? (v.isEmpty ? double.nan : _num(_textOf(v.first))) : _num(v);

String _string(Object v) => switch (v) {
  final String s => s,
  final double d => d == d.truncateToDouble() && d.abs() < 1e15 ? d.toInt().toString() : d.toString(),
  final bool b => b.toString(),
  _ => '',
};

String _stringOf(Object v) => v is List<Node> ? (v.isEmpty ? '' : _textOf(v.first)) : _string(v);

// ---------------------------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------------------------

const _nodeTypeTests = {'text', 'node', 'comment', 'processing-instruction'};

/// Prefix for a name test that must never match. Written as an escape on purpose: as a raw
/// byte it made this file binary to `grep`, `ripgrep` and code search.
const _unmatchable = '\x00';

final class _XPathParser {
  final String s;
  int i = 0;

  _XPathParser(this.s);

  _XNode parse() {
    final e = _or();
    _ws();
    if (i < s.length) throw FormatException('Unexpected "${s[i]}" in XPath', s, i);
    return e;
  }

  _XNode _or() {
    var left = _and();
    while (_word('or')) {
      left = _Binary('or', left, _and());
    }
    return left;
  }

  _XNode _and() {
    var left = _equality();
    while (_word('and')) {
      left = _Binary('and', left, _equality());
    }
    return left;
  }

  _XNode _equality() {
    var left = _relational();
    while (true) {
      _ws();
      if (_take('!=')) {
        left = _Binary('!=', left, _relational());
      } else if (_take('=')) {
        left = _Binary('=', left, _relational());
      } else {
        return left;
      }
    }
  }

  _XNode _relational() {
    var left = _additive();
    while (true) {
      _ws();
      if (_take('<=')) {
        left = _Binary('<=', left, _additive());
      } else if (_take('>=')) {
        left = _Binary('>=', left, _additive());
      } else if (_take('<')) {
        left = _Binary('<', left, _additive());
      } else if (_take('>')) {
        left = _Binary('>', left, _additive());
      } else {
        return left;
      }
    }
  }

  _XNode _additive() {
    var left = _unary();
    while (true) {
      _ws();
      if (_take('+')) {
        left = _Binary('+', left, _unary());
      } else if (i < s.length && s[i] == '-' && !_isNameChar(_peekBack())) {
        i++;
        left = _Binary('-', left, _unary());
      } else {
        return left;
      }
    }
  }

  int _peekBack() {
    var k = i - 1;
    while (k >= 0 && s.codeUnitAt(k) == 0x20) {
      k--;
    }
    return k >= 0 ? s.codeUnitAt(k) : 0x20;
  }

  _XNode _unary() {
    _ws();
    if (_take('-')) return _Negate(_unary());
    return _union();
  }

  _XNode _union() {
    var left = _path();
    while (true) {
      _ws();
      if (!_take('|')) return left;
      left = _Union(left, _path());
    }
  }

  _XNode _path() {
    _ws();
    if (i >= s.length) throw FormatException('Expected an expression', s, i);
    final c = s[i];
    final digitAfterDot = c == '.' && i + 1 < s.length && _isDigit(s.codeUnitAt(i + 1));
    if (c == '"' || c == "'" || c == '(' || _isDigit(c.codeUnitAt(0)) || digitAfterDot) {
      return _continuePath(_filterPredicates(_primary()));
    }
    if (_isNameStart(c.codeUnitAt(0))) {
      final save = i;
      final name = _name();
      _ws();
      final isCall = i < s.length && s[i] == '(' && !_nodeTypeTests.contains(name);
      i = save;
      if (isCall) return _continuePath(_filterPredicates(_primary()));
    }
    return _locationPath();
  }

  _XNode _continuePath(_XNode primary) {
    _ws();
    if (_take('//')) {
      return _XPathExpr(
        false,
        _collapse([const _XStep('descendant-or-self', null, []), ..._relativeSteps()]),
        filter: primary,
      );
    }
    if (_take('/')) return _XPathExpr(false, _relativeSteps(), filter: primary);
    return primary;
  }

  _XNode _filterPredicates(_XNode primary) {
    _ws();
    if (i < s.length && s[i] == '[') return _Filter(primary, _predicates());
    return primary;
  }

  _XNode _primary() {
    _ws();
    final c = s[i];
    if (c == '"' || c == "'") {
      final end = s.indexOf(c, i + 1);
      if (end == -1) throw FormatException('Unterminated string in XPath', s, i);
      final v = s.substring(i + 1, end);
      i = end + 1;
      return _Literal(v);
    }
    if (c == '(') {
      i++;
      final e = _or();
      _ws();
      _expect(')');
      return e;
    }
    if (_isDigit(c.codeUnitAt(0)) || c == '.') {
      final start = i;
      while (i < s.length && (_isDigit(s.codeUnitAt(i)) || s[i] == '.')) {
        i++;
      }
      return _Literal(double.parse(s.substring(start, i)));
    }
    final name = _name();
    _ws();
    _expect('(');
    final args = <_XNode>[];
    _ws();
    if (!_take(')')) {
      while (true) {
        args.add(_or());
        _ws();
        if (_take(')')) break;
        _expect(',');
      }
    }
    return _Call(name, args);
  }

  _XNode _locationPath() {
    if (_take('//')) {
      return _XPathExpr(true, _collapse([const _XStep('descendant-or-self', null, []), ..._relativeSteps()]));
    }
    if (_take('/')) {
      _ws();
      if (i >= s.length || s[i] == '|' || s[i] == ')' || s[i] == ']' || s[i] == ',') return const _XPathExpr(true, []);
      return _XPathExpr(true, _relativeSteps());
    }
    return _XPathExpr(false, _relativeSteps());
  }

  List<_XStep> _relativeSteps() {
    final steps = <_XStep>[_step()];
    while (true) {
      _ws();
      if (_take('//')) {
        steps
          ..add(const _XStep('descendant-or-self', null, []))
          ..add(_step());
      } else if (_take('/')) {
        steps.add(_step());
      } else {
        return _collapse(steps);
      }
    }
  }

  _XStep _step() {
    _ws();
    if (_take('..')) return _XStep('parent', null, _predicates());
    if (i < s.length && s[i] == '.' && !(i + 1 < s.length && _isDigit(s.codeUnitAt(i + 1)))) {
      i++;
      return _XStep('self', null, _predicates());
    }
    var axis = 'child';
    if (_take('@')) {
      axis = 'attribute';
    } else if (i < s.length && _isNameStart(s.codeUnitAt(i))) {
      final save = i;
      final word = _name();
      if (_take('::')) {
        axis = word;
      } else {
        i = save;
      }
    }
    _ws();
    String? test;
    if (_take('*')) {
      test = '*';
    } else {
      final name = _name();
      if (name.isEmpty) throw FormatException('Expected a name test in XPath', s, i);
      if (_nodeTypeTests.contains(name) && _take('()')) {
        test = name == 'node'
            ? null
            : name == 'text'
            ? 'text()'
            // comment() and processing-instruction() parse but match nothing: the parsers
            // keep neither kind of node. The sentinel is a name no element can have.
            : '$_unmatchable$name';
      } else if (name.endsWith(':') && _take('*')) {
        test = '$name*';
      } else {
        test = name;
      }
    }
    return _XStep(axis, test, _predicates());
  }

  List<_XNode> _predicates() {
    final out = <_XNode>[];
    while (true) {
      _ws();
      if (!_take('[')) return out;
      out.add(_or());
      _ws();
      _expect(']');
    }
  }

  String _name() {
    final start = i;
    while (i < s.length && (_isNameChar(s.codeUnitAt(i)) || s[i] == ':') && !s.startsWith('::', i)) {
      i++;
    }
    return s.substring(start, i);
  }

  bool _word(String w) {
    _ws();
    if (s.startsWith(w, i) && (i + w.length >= s.length || !_isNameChar(s.codeUnitAt(i + w.length)))) {
      i += w.length;
      return true;
    }
    return false;
  }

  bool _take(String t) {
    if (s.startsWith(t, i)) {
      i += t.length;
      return true;
    }
    return false;
  }

  void _expect(String t) {
    if (!_take(t)) throw FormatException('Expected "$t" in XPath', s, i);
  }

  void _ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
      i++;
    }
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
  static bool _isNameStart(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c > 0x7f;
  static bool _isNameChar(int c) => _isNameStart(c) || _isDigit(c) || c == 0x2d || c == 0x2e;
}
