part of '../../formats.dart';

/// A compiled XPath 1.0 expression: location paths on all thirteen axes but `namespace`,
/// with their abbreviations; `*`, `prefix:*`, `text()`, `node()`; predicates; `|`; the
/// arithmetic, comparison and boolean operators; and the core function library bar `id()`
/// and `lang()`, plus `ends-with()`.
///
/// Parsed once per expression and cached. It is `$x` on every document, element and
/// query result.
final class _XPath {
  final _XNode _root;

  const _XPath._(this._root);

  static final _cache = <String, _XPath>{};

  /// Compiles [source], or returns the cached result. Throws [FormatException] on bad syntax.
  static _XPath parse(String source) => _compiled(_cache, source, () => _XPath._(_XPathParser(source).parse()));

  /// The nodes this expression selects with [context] as the context node, in document
  /// order. An absolute path starts at the document above [context]'s root element.
  ///
  /// Throws [FormatException] when the expression evaluates to a string, number or boolean.
  List<Node> select(Node context) {
    var root = context;
    for (var p = root.parent; p != null; p = p.parent) {
      root = p;
    }
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

/// What one query computes about the tree, kept for its length only: the tree cannot change
/// underneath it, and the next query builds its own.
final class _Shared {
  /// Where each node sits in its parent's child list, filled one parent at a time.
  ///
  /// The sibling axes each need a node's slot before they can walk away from it, and asking
  /// the list with `indexOf` costs a scan per node — which made `following-sibling` over n
  /// siblings quadratic. The CSS engine keeps the same index for the same reason.
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

  /// Every node's position in document order, attributes included, for the queries whose
  /// result has to be sorted — a union, or a path through an axis that does not keep
  /// document order. Most never ask; see [_Path.eval].
  ///
  /// Two cheaper-looking shapes were tried and are both slower, measured: computing an
  /// (owner, slot) key inside the comparator (four map lookups per comparison instead of
  /// one), and the same key precomputed per node (thousands of tiny maps for one large one).
  Map<Node, int>? _order;

  Map<Node, int> order(_Document document) => _order ??= () {
    final order = <Node, int>{document: 0};
    _eachBelow(document, (n) {
      order[n] = order.length;
      if (n is Element) {
        for (final MapEntry(:key, :value) in n.attributes.entries) {
          order[Attribute(key, value, n)] = order.length;
        }
      }
      return false;
    });
    return order;
  }();
}

extension on List<Node> {
  /// Puts a node-set in document order.
  void sortIn(_Ctx c) {
    final order = c._shared.order(c.document);
    sort((x, y) => (order[x] ?? -1).compareTo(order[y] ?? -1));
  }
}

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

// ---------------------------------------------------------------------------------------------
// Expression tree. Values are List<Node> (a node-set, always in document order), String,
// double or bool.
// ---------------------------------------------------------------------------------------------

sealed class _XNode {
  const _XNode();

  Object eval(_Ctx c);

  /// The value as a boolean, which a node-set can answer without being built: a path stops
  /// at its first node, so `//article[.//img]` looks at one image per article, not all.
  bool test(_Ctx c) => _bool(eval(c));

  /// Whether this reads the context position or size — `position()`, `last()` — outside
  /// any predicate of its own.
  bool get usesPosition;

  /// Whether this can evaluate to a number, which as a predicate means a position.
  bool get isNumeric => false;

  /// Whether a predicate of this shape depends on where its node sits in the set. One that
  /// does not can filter an axis as it is walked, and lets `//x[…]` be a single step.
  bool get positional => isNumeric || usesPosition;
}

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

  /// Each step's results are gathered per context node and joined, and whether the join is
  /// still in document order — and still free of duplicates — follows from what the
  /// inputs were and which axis ran: a child step keeps order only when no input node
  /// contains another, a reverse axis from one node yields it backwards, and so on. The
  /// whole-document order map is built only when that reasoning runs out, which for the
  /// paths a scraper writes is almost never.
  @override
  Object eval(_Ctx c) {
    var current = _start(c);
    var sorted = true; // in document order
    var reversed = false; // in reverse document order
    var flat = current.length <= 1; // no node is an ancestor of another
    for (final step in steps) {
      final single = current.length == 1;
      final axis = step.axis;
      // Whether a child step keeps order turns on whether the inputs nest, which after a
      // descendant step is not known — but is cheap to find out, and far cheaper than the
      // document-wide sort that not knowing costs: `//tr/td`, `//article/header`.
      if (axis == _Axis.child && sorted && !flat && !single) flat = _isFlat(current);
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
          _Axis.descendant || _Axis.descendantOrSelf => (sorted, false),
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

/// Whether no node of [sorted], a node-set in document order, is an ancestor of another.
/// A subtree is a contiguous run of document order, so it is enough that none contains the
/// node right after it.
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
      nodes = [
        for (var i = 0; i < nodes.length; i++)
          if (_keep(p, c.at(nodes[i], i + 1, nodes.length))) nodes[i],
      ];
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
      '<' => _compare(a, b, (x, y) => _num(x) < _num(y), (x, y) => x < y),
      '>' => _compare(a, b, (x, y) => _num(x) > _num(y), (x, y) => x > y),
      '<=' => _compare(a, b, (x, y) => _num(x) <= _num(y), (x, y) => x <= y),
      '>=' => _compare(a, b, (x, y) => _num(x) >= _num(y), (x, y) => x >= y),
      '+' => _numOf(a) + _numOf(b),
      '-' => _numOf(a) - _numOf(b),
      '*' => _numOf(a) * _numOf(b),
      'div' => _numOf(a) / _numOf(b),
      // XPath's mod keeps the dividend's sign, as Dart's `remainder` does and `%` does not.
      'mod' => _numOf(a).remainder(_numOf(b)),
      _ => throw FormatException('Unknown operator $op'),
    };
  }

  /// XPath 1.0 comparison: a node-set compares by the string value of any of its nodes.
  static bool _compare(Object a, Object b, bool Function(String, String) str, bool Function(double, double) num) {
    if (a is List<Node> && b is List<Node>) return a.any((x) => b.any((y) => str(x.text, y.text)));
    if (a is List<Node>) return a.any((x) => _compare(x.text, b, str, num));
    if (b is List<Node>) return b.any((y) => _compare(a, y.text, str, num));
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
    String s(int i) => args.length > i ? _stringOf(arg(i)) : c.node.text;
    double n(int i) => _numOf(arg(i));
    List<Node> nodes(int i) => switch (arg(i)) {
      final List<Node> v => v,
      _ => throw FormatException('$name() needs a node-set'),
    };
    Node? first() => args.isEmpty ? c.node : nodes(0).firstOrNull;
    String nameOf(Node? n) => switch (n) {
      Element(:final name) || Attribute(:final name) => name,
      _ => '',
    };

    return switch (name) {
      'last' => c.size.toDouble(),
      'position' => c.position.toDouble(),
      'count' => nodes(0).length.toDouble(),
      'sum' => nodes(0).fold<double>(0, (t, x) => t + _num(x.text)),
      'true' => true,
      'false' => false,
      'not' || 'boolean' => test(c),
      'string' => s(0),
      'number' => args.isEmpty ? _num(c.node.text) : n(0),
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
      'name' => nameOf(first()),
      'local-name' => nameOf(first()).split(':').last,
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

// ---------------------------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------------------------

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

  /// Whether the step can reach one node from two inputs. A node has one parent, so a
  /// child, attribute or self step never does; a descendant step does only when one input
  /// contains another — when the inputs are not [flat].
  bool mayRepeat(bool flat) => switch (this) {
    child || attribute || self => false,
    descendant || descendantOrSelf => !flat,
    _ => true,
  };

  static final _byName = {
    'child': child,
    'descendant': descendant,
    'parent': parent,
    'ancestor': ancestor,
    'following-sibling': followingSibling,
    'preceding-sibling': precedingSibling,
    'following': following,
    'preceding': preceding,
    'attribute': attribute,
    'self': self,
    'descendant-or-self': descendantOrSelf,
    'ancestor-or-self': ancestorOrSelf,
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

  /// The position a `[k]` right after those pins the step to: the walk stops at the k-th
  /// match rather than collecting the axis and throwing all but one away, so
  /// `following-sibling::li[1]` reads one sibling. `null` when there is none.
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
      final nodes = out;
      out = [
        for (var i = 0; i < nodes.length; i++)
          if (_keep(predicates[p], c.at(nodes[i], i + 1, nodes.length))) nodes[i],
      ];
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
    _ when n is! Element && n is! Attribute => false,
    _NodeTest.any => true,
    _NodeTest.prefix => _nameOf(n).startsWith(name),
    _NodeTest.name => _nameOf(n) == name,
  };

  static String _nameOf(Node n) => n is Element ? n.name : (n as Attribute).name;

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
        if (n is Element) {
          for (final MapEntry(:key, :value) in n.attributes.entries) {
            if (visit(Attribute(key, value, n))) return true;
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
            _eachBelow(siblings[i], (m) {
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

/// `descendant-or-self::node()/child::x[k]` — what `//x[k]` means — as one step: every
/// `x` whose position among its parent's matching children passes, in document order.
///
/// Run as two steps it applied the child step to every node in the document, then sorted
/// the lot, because children of nested parents interleave. Here each parent's selection is
/// made as the walk enters it and its members are emitted as the walk reaches them, which
/// is document order by construction. The same holds for `//@x[k]`.
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
      if (m is Element) enter(m);
    }
    return out;
  }

  @override
  bool any(_Ctx c, Node context, bool Function(Node) then) => apply(c, context).any(then);
}

/// `descendant-or-self::node()` followed by a child or attribute step — what `//` writes —
/// is one step. With no positional predicate it is `descendant::x[…]`, which walks the
/// subtree once instead of taking the children of every node in it; with one, `//p[1]`
/// is the first `p` of each parent rather than the first in the document, and it is a
/// [_DescendantStep].
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
  final String s => _isXPathNumber(s) ? double.parse(s) : double.nan,
  _ => double.nan,
};

/// Whether [s] is XPath 1.0's number: digits with an optional fraction and minus sign,
/// whitespace around. No exponent, no `+`, no `Infinity` — all of which `double.parse`
/// takes. Scanned by hand, since every numeric comparison in a predicate comes through here.
bool _isXPathNumber(String s) {
  var i = 0, end = s.length;
  while (i < end && _isSpace(s.codeUnitAt(i))) {
    i++;
  }
  while (end > i && _isSpace(s.codeUnitAt(end - 1))) {
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

double _numOf(Object v) => v is List<Node> ? (v.isEmpty ? double.nan : _num(v.first.text)) : _num(v);

String _string(Object v) => switch (v) {
  final String s => s,
  0.0 => '0', // -0 too
  final double d => d == d.truncateToDouble() && d.abs() < 1e15 ? d.toInt().toString() : d.toString(),
  final bool b => b.toString(),
  _ => '',
};

String _stringOf(Object v) => v is List<Node> ? (v.isEmpty ? '' : v.first.text) : _string(v);

// ---------------------------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------------------------

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
    if (_take('//')) return _Path(false, _collapse([_descendantOrSelf(), ..._relativeSteps()]), filter: primary);
    if (_take('/')) return _Path(false, _relativeSteps(), filter: primary);
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
      // comment() and processing-instruction() parse but match nothing: the parsers keep
      // neither kind of node.
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
