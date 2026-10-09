part of '../markup.dart';

/// The document node above the root, where an absolute XPath starts; minted per walk, so equal
/// by root.
final class _Document extends Element {
  final Element root;
  _Document(this.root) : super('#document', const {}, root.syntax) {
    _nodes.add(root);
  }
  @override
  String get text => root.text;
  @override
  String get rawText => root.rawText;
  @override
  String get markup => root.markup;
  @override
  bool operator ==(Object other) => other is _Document && identical(other.root, root);
  @override
  int get hashCode => identityHashCode(root);
}

/// The nodes XPath [expression] selects from each of [scopes], each once, in document order.
Selection<Node> _xpath(List<Element> scopes, String expression) {
  final x = _XPath.parse(expression);
  if (scopes.length == 1) return Selection._(x.select(scopes.first), expression);
  final seen = <Node>{};
  final out = [
    for (final e in scopes)
      for (final n in x.select(e))
        if (seen.add(n)) n,
  ];
  return Selection._(scopes.length > 1 && !(x.downward && _isFlat(scopes)) ? _inOrder(out) : out, expression);
}

/// A compiled, cached XPath 1.0 expression: every axis but `namespace`, the abbreviations,
/// operators and core functions bar `id()` and `lang()`, plus `ends-with()`.
final class _XPath {
  final _XNode _root;

  const _XPath._(this._root);

  static final _cache = <String, _XPath>{};

  /// [source] compiled and cached; a [FormatException] on bad syntax.
  static _XPath parse(String source) => compiled(_cache, source, () => _XPath._(_XPathParser(source).parse()));

  /// Whether every node selected lies at or below the context: a relative path down the
  /// child, descendant, attribute and self axes.
  bool get downward {
    final r = _root;
    return r is _Path &&
        !r.absolute &&
        r.filter == null &&
        r.steps.every(
          (s) => switch (s.axis) {
            _Axis.child || _Axis.descendant || _Axis.descendantOrSelf || _Axis.attribute || _Axis.self => true,
            _ => false,
          },
        );
  }

  /// The nodes selected from [context], in document order; an absolute path starts at the
  /// document above its root. A [FormatException] when the result is not a node-set.
  List<Node> select(Node context) {
    final root = _rootOf(context);
    final value = _root.eval(_Ctx(context, 1, 1, root is _Document ? root : _Document(root as Element)));
    if (value is! List<Node>) throw FormatException('XPath does not select nodes: it evaluates to $value');
    return [
      for (final n in value)
        if (n is! _Document) n,
    ];
  }
}

final class _Ctx {
  final Node node;
  final int position;
  final int size;
  final _Document document;

  /// Shared with every context this one spawns, so each is built at most once per query.
  final _Shared _shared;

  _Ctx(this.node, this.position, this.size, this.document) : _shared = _Shared();

  _Ctx._(this.node, this.position, this.size, this.document, this._shared);

  _Ctx at(Node n, int position, int size) => _Ctx._(n, position, size, document, _shared);
}

/// What one query computes about the tree; the next query builds its own.
final class _Shared {
  /// Each node's index among its parent's children, filled per parent, so sibling axes are
  /// not quadratic.
  final Map<Node, int> _slot = {};
  final Set<Node> _indexed = {};

  int slotOf(Node parent, Node child) {
    if (_indexed.add(parent)) {
      final children = _down(parent);
      for (var i = 0; i < children.length; i++) {
        _slot[children[i]] = i;
      }
    }
    return _slot[child] ?? -1;
  }

  /// Every element's and text's document-order position, built only when a result must be
  /// sorted (see [_Path.eval]). Attributes sort by their element, then their place on it.
  Map<Node, int>? _order;

  Map<Node, int> order(_Document document) => _order ??= () {
    final order = <Node, int>{document: 0};
    _eachBelow(document, (Node n) {
      order[n] = order.length;
      return false;
    });
    return order;
  }();
}

extension on List<Node> {
  /// Puts a node-set in document order.
  void sortIn(_Ctx c) {
    final order = c._shared.order(c.document);
    sort((x, y) {
      final kx = order[x is Attribute ? x.parent : x] ?? -1;
      final ky = order[y is Attribute ? y.parent : y] ?? -1;
      if (kx != ky) return kx.compareTo(ky);
      // One element: itself first, then its attributes as written.
      if (x is! Attribute) return y is Attribute ? -1 : 0;
      if (y is! Attribute) return 1;
      return _slotOf(x).compareTo(_slotOf(y));
    });
  }
}

bool _isXSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// The parent, or the document node above the root element, or `null` above that.
Node? _up(Node n) {
  if (n is _Document) return null;
  if (n is Element && n.parent == null) return _Document(n);
  return n.parent;
}

/// Child nodes of an element, or the root element of a document node.
List<Node> _down(Node n) {
  if (n is _Document) return [n.root];
  if (n is Element) return n._nodes;
  return const [];
}

// Values are List<Node> (a node-set, always in document order), String, double or bool.

sealed class _XNode {
  const _XNode();

  Object eval(_Ctx c);

  /// The value as a boolean, without building a node-set: `//article[.//img]` stops at the
  /// first image.
  bool test(_Ctx c) => _bool(eval(c));

  /// Whether this reads the context position or size — `position()`, `last()` — outside
  /// any predicate of its own.
  bool get usesPosition;

  /// Whether this can evaluate to a number, which as a predicate means a position.
  bool get isNumeric => false;

  /// Whether a predicate depends on position; one that does not filters an axis as it walks.
  bool get positional => isNumeric || usesPosition;
}

/// [n]'s name for a name test or `name()`: the document's is empty, as XPath 1.0 has it.
String _nameOf(Node? n) {
  if (n == null || n is _Document) return '';
  if (n is Element) return n.name;
  if (n is Attribute) return n.name;
  return '';
}

/// The [nodes] predicate [p] keeps, each at its position in [nodes].
List<Node> _filtered(List<Node> nodes, _XNode p, _Ctx c) => [
  for (var i = 0; i < nodes.length; i++)
    if (_keep(p, c.at(nodes[i], i + 1, nodes.length))) nodes[i],
];

/// Whether predicate [p] keeps the node at [position] of the context [at] describes.
bool _keep(_XNode p, _Ctx at) {
  if (!p.positional) return p.test(at);
  final v = p.eval(at);
  return v is double ? v == at.position : _bool(v);
}

final class _Literal extends _XNode {
  final Object value;
  const _Literal(this.value);
  @override
  Object eval(_Ctx c) => value;
  @override
  bool get usesPosition => false;
  @override
  bool get isNumeric => value is double;
}

final class _Path extends _XNode {
  final bool absolute;
  final _XNode? filter; // a filter expression the path continues from, e.g. `(//a)[1]/b`
  final List<_XStep> steps;
  const _Path(this.absolute, this.steps, {this.filter});

  @override
  bool get usesPosition => filter?.usesPosition ?? false;

  List<Node> _start(_Ctx c) {
    if (filter == null) return [absolute ? c.document : c.node];
    final v = filter!.eval(c);
    if (v is! List<Node>) throw const FormatException('A path must start from a node-set');
    return v;
  }

  /// Joins each step's per-node results, tracking from the inputs and the axis whether the
  /// join is still sorted and duplicate-free, so the document-wide sort is almost never run.
  @override
  Object eval(_Ctx c) {
    var current = _start(c);
    var sorted = true; // in document order
    var reversed = false; // in reverse document order
    var flat = current.length <= 1; // no node is an ancestor of another
    for (final step in steps) {
      final single = current.length == 1;
      final axis = step.axis;
      final down = axis == _Axis.descendant || axis == _Axis.descendantOrSelf;
      // Positions count per input, so `descendant::b[1]` from nested inputs interleaves.
      final positional = step._leading < step.predicates.length;
      // A child step, or a positional descendant one, keeps order when the inputs do not nest;
      // checking is far cheaper than the sort: `//tr/td`.
      if ((axis == _Axis.child || (down && positional)) && sorted && !flat && !single) flat = _isFlat(current);
      final Set<Node>? seen = single || !axis.mayRepeat(flat) ? null : {};
      final next = <Node>[];
      for (final n in current) {
        for (final m in step.apply(c, n)) {
          if (seen == null || seen.add(m)) next.add(m);
        }
      }
      if (axis == _Axis.self) {
      } else if (reversed || !sorted) {
        (sorted, reversed, flat) = (false, false, false);
      } else if (axis.reverse) {
        (sorted, reversed, flat) = (false, single, single && axis == _Axis.precedingSibling);
      } else {
        (sorted, flat) = switch (axis) {
          _Axis.child => (sorted && flat, flat),
          _Axis.attribute => (sorted, true),
          _Axis.descendant || _Axis.descendantOrSelf => (sorted && (flat || !positional), false),
          _ => (single, single && axis != _Axis.following),
        };
      }
      current = next;
    }
    if (current.length < 2 || sorted) return current;
    return reversed ? current.reversed.toList() : (current..sortIn(c));
  }

  @override
  bool test(_Ctx c) {
    bool from(int s, Node n) => s == steps.length || steps[s].any(c, n, (m) => from(s + 1, m));
    return _start(c).any((n) => from(0, n));
  }
}

/// Whether no node of the document-ordered [sorted] is an ancestor of another; subtrees are
/// contiguous, so checking each node's successor suffices.
bool _isFlat(List<Node> sorted) {
  for (var i = 1; i < sorted.length; i++) {
    final above = sorted[i - 1];
    if (above is _Document) return false;
    for (var p = sorted[i].parent; p != null; p = p.parent) {
      if (identical(p, above)) return false;
    }
  }
  return true;
}

/// A node-set with predicates applied to it as a whole: `(//item)[2]`.
final class _Filter extends _XNode {
  final _XNode primary;
  final List<_XNode> predicates;
  const _Filter(this.primary, this.predicates);

  @override
  bool get usesPosition => primary.usesPosition;

  @override
  Object eval(_Ctx c) {
    final v = primary.eval(c);
    if (v is! List<Node>) throw const FormatException('A predicate needs a node-set');
    // Every node-set arrives in document order already, so there is nothing to sort.
    var nodes = v;
    for (final p in predicates) {
      nodes = _filtered(nodes, p, c);
    }
    return nodes;
  }
}

final class _Union extends _XNode {
  final _XNode left, right;
  const _Union(this.left, this.right);

  @override
  bool get usesPosition => left.usesPosition || right.usesPosition;

  @override
  Object eval(_Ctx c) {
    final a = left.eval(c), b = right.eval(c);
    if (a is! List<Node> || b is! List<Node>) throw const FormatException('| needs node-sets on both sides');
    if (a.isEmpty || b.isEmpty) return a.isEmpty ? b : a;
    return <Node>{...a, ...b}.toList()..sortIn(c);
  }

  @override
  bool test(_Ctx c) => left.test(c) || right.test(c);
}

final class _Binary extends _XNode {
  final String op;
  final _XNode left, right;
  const _Binary(this.op, this.left, this.right);

  static const _arithmetic = {'+', '-', '*', 'div', 'mod'};

  @override
  bool get usesPosition => left.usesPosition || right.usesPosition;

  @override
  bool get isNumeric => _arithmetic.contains(op);

  @override
  bool test(_Ctx c) => switch (op) {
    'or' => left.test(c) || right.test(c),
    'and' => left.test(c) && right.test(c),
    _ => _bool(eval(c)),
  };

  @override
  Object eval(_Ctx c) {
    if (op == 'or' || op == 'and') return test(c);
    final a = left.eval(c), b = right.eval(c);
    return switch (op) {
      '=' => _compare(a, b, (x, y) => x == y, (x, y) => x == y),
      '!=' => _compare(a, b, (x, y) => x != y, (x, y) => x != y),
      '<' => _compare(a, b, (x, y) => _num(x) < _num(y), (x, y) => x < y, relational: true),
      '>' => _compare(a, b, (x, y) => _num(x) > _num(y), (x, y) => x > y, relational: true),
      '<=' => _compare(a, b, (x, y) => _num(x) <= _num(y), (x, y) => x <= y, relational: true),
      '>=' => _compare(a, b, (x, y) => _num(x) >= _num(y), (x, y) => x >= y, relational: true),
      '+' => _numOf(a) + _numOf(b),
      '-' => _numOf(a) - _numOf(b),
      '*' => _numOf(a) * _numOf(b),
      'div' => _numOf(a) / _numOf(b),
      // XPath's mod keeps the dividend's sign, as Dart's `remainder` does and `%` does not.
      'mod' => _numOf(a).remainder(_numOf(b)),
      _ => throw FormatException('Unknown operator $op'),
    };
  }

  /// XPath 1.0 comparison: a node-set compares by the string value of any of its nodes; beside
  /// a boolean it is one, and `<`, `>` compare booleans as numbers.
  static bool _compare(
    Object a,
    Object b,
    bool Function(String, String) str,
    bool Function(double, double) num, {
    bool relational = false,
  }) {
    if (a is bool || b is bool) {
      if (!relational) return str(_bool(a).toString(), _bool(b).toString());
      return num(_num(a is List<Node> ? _bool(a) : a), _num(b is List<Node> ? _bool(b) : b));
    }
    if (a is List<Node> && b is List<Node>) return a.any((x) => b.any((y) => str(_xvalue(x), _xvalue(y))));
    if (a is List<Node>) return a.any((x) => _compare(_xvalue(x), b, str, num));
    if (b is List<Node>) return b.any((y) => _compare(a, _xvalue(y), str, num));
    if (a is double || b is double) return num(_num(a), _num(b));
    return str(_string(a), _string(b));
  }
}

final class _Negate extends _XNode {
  final _XNode inner;
  const _Negate(this.inner);
  @override
  Object eval(_Ctx c) => -_numOf(inner.eval(c));
  @override
  bool get usesPosition => inner.usesPosition;
  @override
  bool get isNumeric => true;
}

final class _Call extends _XNode {
  final String name;
  final List<_XNode> args;
  const _Call(this.name, this.args);

  static const _numeric = {
    'last', 'position', 'count', 'number', 'string-length', 'sum', 'floor', 'ceiling', 'round', //
  };

  @override
  bool get usesPosition => name == 'position' || name == 'last' || args.any((a) => a.usesPosition);

  @override
  bool get isNumeric => _numeric.contains(name);

  @override
  bool test(_Ctx c) => switch (name) {
    'not' => !args[0].test(c),
    'boolean' => args[0].test(c),
    _ => _bool(eval(c)),
  };

  @override
  Object eval(_Ctx c) {
    Object arg(int i) => args[i].eval(c);
    String s(int i) => args.length > i ? _stringOf(arg(i)) : _xvalue(c.node);
    double n(int i) => _numOf(arg(i));
    List<Node> nodes(int i) => switch (arg(i)) {
      final List<Node> v => v,
      _ => throw FormatException('$name() needs a node-set'),
    };
    Node? first() => args.isEmpty ? c.node : nodes(0).firstOrNull;

    return switch (name) {
      'last' => c.size.toDouble(),
      'position' => c.position.toDouble(),
      'count' => nodes(0).length.toDouble(),
      'sum' => nodes(0).fold<double>(0, (t, x) => t + _num(_xvalue(x))),
      'true' => true,
      'false' => false,
      'not' || 'boolean' => test(c),
      'string' => s(0),
      'number' => args.isEmpty ? _num(_xvalue(c.node)) : n(0),
      'floor' => n(0).floorToDouble(),
      'ceiling' => n(0).ceilToDouble(),
      'round' => _round(n(0)),
      'contains' => s(0).contains(s(1)),
      'starts-with' => s(0).startsWith(s(1)),
      'ends-with' => s(0).endsWith(s(1)),
      'string-length' => s(0).runes.length.toDouble(),
      'normalize-space' => s(0).trim().replaceAll(_ws, ' '),
      'concat' => [for (var i = 0; i < args.length; i++) s(i)].join(),
      'substring-before' => _around(s(0), s(1), before: true),
      'substring-after' => _around(s(0), s(1), before: false),
      'substring' => _substring(s(0), n(1), args.length > 2 ? n(2) : double.infinity),
      'translate' => _translate(s(0), s(1), s(2)),
      'name' => _nameOf(first()),
      'local-name' => _nameOf(first()).split(':').last,
      _ => throw FormatException('Unsupported XPath function $name()'),
    };
  }

  /// floor(x + 0.5), which is not Dart's half-away-from-zero: round(-1.5) is -1.
  static double _round(double x) => x.isFinite ? (x + 0.5).floorToDouble() : x;

  static String _around(String a, String b, {required bool before}) {
    final i = a.indexOf(b);
    if (i == -1) return '';
    return before ? a.substring(0, i) : a.substring(i + b.length);
  }

  /// XPath's `substring`: characters from 1, the bounds rounded, NaN selecting nothing.
  static String _substring(String s, double start, double length) {
    final from = _round(start);
    final to = from + _round(length);
    final chars = s.runes.toList();
    return String.fromCharCodes([
      for (var p = 1; p <= chars.length; p++)
        if (p >= from && p < to) chars[p - 1],
    ]);
  }

  /// Each character of [s] found in [from] becomes the one at its place in [to], or is
  /// dropped when [to] is shorter.
  static String _translate(String s, String from, String to) {
    final src = from.runes.toList(), dst = to.runes.toList();
    final out = <int>[];
    for (final r in s.runes) {
      final i = src.indexOf(r);
      if (i == -1) {
        out.add(r);
      } else if (i < dst.length) {
        out.add(dst[i]);
      }
    }
    return String.fromCharCodes(out);
  }
}

enum _Axis {
  child,
  descendant,
  descendantOrSelf,
  parent,
  ancestor,
  ancestorOrSelf,
  followingSibling,
  precedingSibling,
  following,
  preceding,
  attribute,
  self;

  /// A reverse axis lists nodes nearest first, and its positions count that way.
  bool get reverse => this == ancestor || this == ancestorOrSelf || this == precedingSibling || this == preceding;

  /// Whether the step can reach one node from two inputs: never for child, attribute or self;
  /// for a descendant step only when the inputs are not [flat].
  bool mayRepeat(bool flat) => switch (this) {
    child || attribute || self => false,
    descendant || descendantOrSelf => !flat,
    _ => true,
  };

  static final _byName = {
    for (final a in values) a.name.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}'): a,
  };

  /// `following-sibling` → [followingSibling].
  static _Axis? named(String name) => _byName[name];
}

/// What a step's node test accepts.
enum _NodeTest { node, text, any, prefix, name, none }

final class _XStep {
  final _Axis axis;
  final _NodeTest test;

  /// The name for [_NodeTest.name], or the prefix with its colon for [_NodeTest.prefix].
  final String name;
  final List<_XNode> predicates;

  /// How many predicates at the front ignore position, and so filter the walk itself.
  final int _leading;

  /// The `[k]` right after those, if any: the walk stops at the k-th match, so
  /// `following-sibling::li[1]` reads one sibling.
  final int? _pin;

  _XStep(this.axis, this.test, this.predicates, {this.name = ''})
    : _leading = _countLeading(predicates),
      _pin = _pinOf(predicates, _countLeading(predicates));

  static int _countLeading(List<_XNode> predicates) {
    var k = 0;
    while (k < predicates.length && !predicates[k].positional) {
      k++;
    }
    return k;
  }

  static int? _pinOf(List<_XNode> predicates, int at) {
    if (at >= predicates.length) return null;
    final p = predicates[at];
    if (p is! _Literal || p.value is! double) return null;
    final k = p.value as double;
    return k >= 1 && k == k.roundToDouble() ? k.toInt() : -1;
  }

  /// The nodes this step selects from [context], in axis order.
  List<Node> apply(_Ctx c, Node context) {
    var out = <Node>[];
    final pin = _pin;
    if (pin == null) {
      _each(c, context, (m) {
        if (_accepts(c, m)) out.add(m);
        return false;
      });
    } else if (pin > 0) {
      var matched = 0;
      _each(c, context, (m) {
        if (!_accepts(c, m) || ++matched < pin) return false;
        out.add(m);
        return true;
      });
    }
    for (var p = _leading + (pin == null ? 0 : 1); p < predicates.length; p++) {
      out = _filtered(out, predicates[p], c);
    }
    return out;
  }

  /// Whether some node this step selects from [context] satisfies [then], walking no
  /// further than the first one that does.
  bool any(_Ctx c, Node context, bool Function(Node) then) {
    if (_leading < predicates.length) return apply(c, context).any(then);
    return _each(c, context, (m) => _accepts(c, m) && then(m));
  }

  bool _accepts(_Ctx c, Node n) {
    if (!_matches(n)) return false;
    for (var p = 0; p < _leading; p++) {
      if (!predicates[p].test(c.at(n, 1, 1))) return false;
    }
    return true;
  }

  bool _matches(Node n) => switch (test) {
    _NodeTest.node => true,
    _NodeTest.text => n is Text,
    _NodeTest.none => false,
    _ when n is _Document || (n is! Element && n is! Attribute) => false,
    _NodeTest.any => true,
    _NodeTest.prefix => _nameOf(n).startsWith(name),
    _NodeTest.name => _nameOf(n) == name,
  };

  /// Visits the axis from [n] in axis order until [visit] returns true; returns whether it did.
  bool _each(_Ctx c, Node n, bool Function(Node) visit) {
    switch (axis) {
      case _Axis.child:
        for (final m in _down(n)) {
          if (visit(m)) return true;
        }
      case _Axis.descendant:
        return _eachBelow(n, visit);
      case _Axis.descendantOrSelf:
        return visit(n) || _eachBelow(n, visit);
      case _Axis.self:
        return visit(n);
      case _Axis.parent:
        final p = _up(n);
        return p != null && visit(p);
      case _Axis.ancestor || _Axis.ancestorOrSelf:
        for (Node? p = axis == _Axis.ancestor ? _up(n) : n; p != null; p = _up(p)) {
          if (visit(p)) return true;
        }
      case _Axis.attribute:
        if (n is Element && n is! _Document) {
          // `@href` is one lookup, not a walk over every attribute the element has.
          if (test == _NodeTest.name) {
            final v = n.attributes[name];
            return v != null && visit(Attribute._(name, v, n));
          }
          for (final MapEntry(:key, :value) in n.attributes.entries) {
            if (visit(Attribute._(key, value, n))) return true;
          }
        }
      case _Axis.followingSibling || _Axis.precedingSibling:
        final p = n is Attribute ? null : _up(n);
        if (p == null) return false;
        final siblings = _down(p);
        final at = c._shared.slotOf(p, n);
        if (axis == _Axis.followingSibling) {
          for (var i = at + 1; i < siblings.length; i++) {
            if (visit(siblings[i])) return true;
          }
        } else {
          for (var i = at - 1; i >= 0; i--) {
            if (visit(siblings[i])) return true;
          }
        }
      case _Axis.following:
        // An attribute's following nodes start with its element's content.
        if (n is Attribute && _eachBelow(n.parent!, visit)) return true;
        var a = n is Attribute ? n.parent! : n;
        for (var p = _up(a); p != null; a = p, p = _up(a)) {
          final siblings = _down(p);
          for (var i = c._shared.slotOf(p, a) + 1; i < siblings.length; i++) {
            if (visit(siblings[i]) || _eachBelow(siblings[i], visit)) return true;
          }
        }
      case _Axis.preceding:
        // Nearest first: each earlier sibling's subtree backwards, then the sibling itself.
        var a = n is Attribute ? n.parent! : n;
        for (var p = _up(a); p != null; a = p, p = _up(a)) {
          final siblings = _down(p);
          for (var i = c._shared.slotOf(p, a) - 1; i >= 0; i--) {
            final below = <Node>[];
            _eachBelow(siblings[i], (Node m) {
              below.add(m);
              return false;
            });
            if (below.reversed.any(visit) || visit(siblings[i])) return true;
          }
        }
    }
    return false;
  }
}

/// `//x[k]` (or `//@x[k]`) as one step: each parent's selection is made as the walk enters it
/// and emitted as the walk reaches it, in document order without a sort.
final class _DescendantStep extends _XStep {
  final _XStep inner;

  _DescendantStep(this.inner) : super(_Axis.descendant, _NodeTest.node, const []);

  @override
  List<Node> apply(_Ctx c, Node context) {
    final out = <Node>[];
    final child = inner.axis == _Axis.child;
    final lists = <List<Node>>[], at = <int>[], picks = <List<Node>>[], next = <int>[];
    void enter(Node p) {
      final picked = inner.apply(c, p);
      if (!child) out.addAll(picked);
      final down = _down(p);
      if (down.isEmpty) return;
      lists.add(down);
      at.add(0);
      picks.add(child ? picked : const []);
      next.add(0);
    }

    enter(context);
    while (lists.isNotEmpty) {
      final top = lists.length - 1;
      final i = at[top];
      if (i == lists[top].length) {
        lists.removeLast();
        at.removeLast();
        picks.removeLast();
        next.removeLast();
        continue;
      }
      at[top] = i + 1;
      final m = lists[top][i];
      final j = next[top];
      if (j < picks[top].length && identical(picks[top][j], m)) {
        out.add(m);
        next[top] = j + 1;
      }
      if (m is Element && m is! _Document) enter(m);
    }
    return out;
  }

  @override
  bool any(_Ctx c, Node context, bool Function(Node) then) => apply(c, context).any(then);
}

/// `//` before a child or attribute step as one step: `descendant::x[…]` without a positional
/// predicate, else a [_DescendantStep] (`//p[1]` is each parent's first `p`).
List<_XStep> _collapse(List<_XStep> steps) {
  final out = <_XStep>[];
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final next = i + 1 < steps.length ? steps[i + 1] : null;
    if (step.axis != _Axis.descendantOrSelf || step.test != _NodeTest.node || step.predicates.isNotEmpty) {
      out.add(step);
    } else if (next != null && next.axis == _Axis.child && !next.predicates.any((p) => p.positional)) {
      out.add(_XStep(_Axis.descendant, next.test, next.predicates, name: next.name));
      i++;
    } else if (next != null && (next.axis == _Axis.child || next.axis == _Axis.attribute)) {
      out.add(_DescendantStep(next));
      i++;
    } else {
      out.add(step);
    }
  }
  return out;
}

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
  final String s => _isXPathNumber(s) ? double.parse(s) : double.nan,
  _ => double.nan,
};

/// Whether [s] is an XPath 1.0 number: `-`, digits, a fraction, whitespace around; none of the
/// exponent, `+` or `Infinity` that `double.parse` takes.
bool _isXPathNumber(String s) {
  var i = 0, end = s.length;
  while (i < end && _isXSpace(s.codeUnitAt(i))) {
    i++;
  }
  while (end > i && _isXSpace(s.codeUnitAt(end - 1))) {
    end--;
  }
  if (i < end && s.codeUnitAt(i) == 0x2d) i++;
  var digits = 0, dots = 0;
  for (; i < end; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) {
      digits++;
    } else if (c == 0x2e && dots == 0) {
      dots++;
    } else {
      return false;
    }
  }
  return digits > 0;
}

double _numOf(Object v) => v is List<Node> ? (v.isEmpty ? double.nan : _num(_xvalue(v.first))) : _num(v);

String _string(Object v) => switch (v) {
  final String s => s,
  0.0 => '0', // -0 too
  final double d => _decimal(d),
  final bool b => b.toString(),
  _ => '',
};

/// [d] as XPath writes a number: no exponent, an integer without a fraction.
String _decimal(double d) {
  if (!d.isFinite) return '$d';
  if (d == d.truncateToDouble()) return d.abs() < 1e18 ? '${d.toInt()}' : '${BigInt.from(d)}';
  final s = '$d', e = s.indexOf('e');
  if (e == -1) return s;
  // Only a small fraction has an exponent here: 1.5e-7 is 0.00000015.
  final sign = d < 0 ? '-' : '';
  return '${sign}0.${'0' * (-int.parse(s.substring(e + 1)) - 1)}${s.substring(sign.length, e).replaceAll('.', '')}';
}

String _stringOf(Object v) => v is List<Node> ? (v.isEmpty ? '' : _xvalue(v.first)) : _string(v);

/// [n]'s string-value, as everything here reads text: what a reader sees, whitespace collapsed
/// (see [Node.text]).
String _xvalue(Node n) => n.text;

const _nodeTypeTests = {'text', 'node', 'comment', 'processing-instruction'};

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

  /// One precedence level: operands from [operand], joined left to right by any of [ops].
  /// A word operator (`and`, `div`) must stand alone; `*` right after an operand is always
  /// multiplication, since a name test can only start an operand.
  _XNode _level(_XNode Function() operand, List<String> ops) {
    var left = operand();
    while (true) {
      _ws();
      final op = ops.where((o) => _isNameStart(o.codeUnitAt(0)) ? _word(o) : _take(o)).firstOrNull;
      if (op == null) return left;
      left = _Binary(op, left, operand());
    }
  }

  _XNode _or() => _level(_and, const ['or']);
  _XNode _and() => _level(_equality, const ['and']);
  _XNode _equality() => _level(_relational, const ['!=', '=']);
  _XNode _relational() => _level(_additive, const ['<=', '>=', '<', '>']);
  // After an operand a `-` is subtraction: the name before it was read whole already.
  _XNode _additive() => _level(_multiplicative, const ['+', '-']);
  _XNode _multiplicative() => _level(_unary, const ['*', 'div', 'mod']);

  _XNode _unary() {
    _ws();
    return _take('-') ? _Negate(_unary()) : _union();
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
    if (_take('//')) return _Path(false, _collapse([_descendantOrSelf(), ..._relativeSteps()]), filter: primary);
    if (_take('/')) return _Path(false, _relativeSteps(), filter: primary);
    return primary;
  }

  _XNode _filterPredicates(_XNode primary) {
    _ws();
    return i < s.length && s[i] == '[' ? _Filter(primary, _predicates()) : primary;
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
    final (min, max) = _arity[name] ?? (throw FormatException('Unsupported XPath function $name()', s, i));
    if (args.length < min || args.length > max) throw FormatException('Wrong argument count for $name()', s, i);
    return _Call(name, args);
  }

  /// Each function's fewest and most arguments.
  static const _arity = {
    'last': (0, 0), 'position': (0, 0), 'true': (0, 0), 'false': (0, 0), //
    'count': (1, 1), 'sum': (1, 1), 'not': (1, 1), 'boolean': (1, 1), 'floor': (1, 1), 'ceiling': (1, 1),
    'round': (1, 1), 'string': (0, 1), 'number': (0, 1), 'string-length': (0, 1), 'normalize-space': (0, 1),
    'name': (0, 1), 'local-name': (0, 1), 'contains': (2, 2), 'starts-with': (2, 2), 'ends-with': (2, 2),
    'substring-before': (2, 2), 'substring-after': (2, 2), 'substring': (2, 3), 'translate': (3, 3),
    'concat': (2, 1 << 30),
  };

  static _XStep _descendantOrSelf() => _XStep(_Axis.descendantOrSelf, _NodeTest.node, const []);

  _XNode _locationPath() {
    if (_take('//')) return _Path(true, _collapse([_descendantOrSelf(), ..._relativeSteps()]));
    if (_take('/')) {
      _ws();
      if (i >= s.length || '|)],'.contains(s[i])) return const _Path(true, []);
      return _Path(true, _relativeSteps());
    }
    return _Path(false, _relativeSteps());
  }

  List<_XStep> _relativeSteps() {
    final steps = <_XStep>[_step()];
    while (true) {
      _ws();
      if (_take('//')) {
        steps
          ..add(_descendantOrSelf())
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
    if (_take('..')) return _XStep(_Axis.parent, _NodeTest.node, _predicates());
    if (i < s.length && s[i] == '.' && !(i + 1 < s.length && _isDigit(s.codeUnitAt(i + 1)))) {
      i++;
      return _XStep(_Axis.self, _NodeTest.node, _predicates());
    }
    var axis = _Axis.child;
    if (_take('@')) {
      axis = _Axis.attribute;
    } else if (i < s.length && _isNameStart(s.codeUnitAt(i))) {
      final save = i;
      final word = _name();
      if (_take('::')) {
        axis = _Axis.named(word) ?? (throw FormatException('Unsupported axis $word::', s, save));
      } else {
        i = save;
      }
    }
    _ws();
    if (_take('*')) return _XStep(axis, _NodeTest.any, _predicates());
    final name = _name();
    if (name.isEmpty) throw FormatException('Expected a name test in XPath', s, i);
    if (_nodeTypeTests.contains(name) && _take('()')) {
      // comment() and processing-instruction() match nothing: the parsers keep neither.

      final test = switch (name) {
        'node' => _NodeTest.node,
        'text' => _NodeTest.text,
        _ => _NodeTest.none,
      };
      return _XStep(axis, test, _predicates());
    }
    if (name.endsWith(':') && _take('*')) return _XStep(axis, _NodeTest.prefix, _predicates(), name: name);
    return _XStep(axis, _NodeTest.name, _predicates(), name: name);
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
