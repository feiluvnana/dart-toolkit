/// # JSONPath (internal)
///
/// The engine behind `Json.jsonpath`. A subset of the JSONPath expression
/// language, evaluated directly over decoded maps, lists and scalars — no
/// compilation step, no dependency, and an expression it cannot read selects
/// nothing rather than throwing.
library;

// ============================================================================
// JSONPATH (internal)
// ============================================================================

/// A compiled JSONPath expression.
class JsonPath {
  final List<_Step> _steps;

  const JsonPath._(this._steps);

  /// The expressions already read, keyed by their text.
  ///
  /// A script runs the same expression once per row, and parsing it every time
  /// is the only part of this that would show up in a profile.
  static final Map<String, JsonPath> _cache = {};

  /// Reads [expression], reusing an earlier parse of the same text.
  ///
  /// An expression that cannot be read compiles to one that selects nothing,
  /// so a typo is an empty result rather than an exception in the middle of a
  /// crawl.
  static JsonPath of(String expression) {
    if (_cache[expression] case final cached?) return cached;
    // Unbounded growth would need unbounded distinct expressions, which means
    // expressions built by string interpolation; cap it rather than leak.
    if (_cache.length >= 256) _cache.clear();
    return _cache[expression] = JsonPath._(_parse(expression));
  }

  /// Every value in [root] this expression selects, in document order.
  List<Object?> read(Object? root) {
    var nodes = <Object?>[root];
    for (final step in _steps) {
      final next = <Object?>[];
      for (final node in nodes) {
        step.apply(node, next);
      }
      nodes = next;
      if (nodes.isEmpty) break;
    }
    return nodes;
  }

  // --------------------------------------------------------------------------
  // Parsing
  // --------------------------------------------------------------------------

  static List<_Step> _parse(String expression) {
    final text = expression.trim();
    final steps = <_Step>[];
    var i = 0;
    if (text.startsWith(r'$')) i = 1;

    while (i < text.length) {
      if (text.startsWith('..', i)) {
        steps.add(const _Descend());
        i += 2;
        // A bare `..` at the end means every descendant.
        if (i >= text.length) {
          steps.add(const _Wild());
          break;
        }
        if (text[i] == '[') continue;
        final read = _name(text, i);
        if (read == null) return const [_Nothing()];
        steps.add(read.$1 == '*' ? const _Wild() : _Child(read.$1));
        i = read.$2;
        continue;
      }
      if (text[i] == '.') {
        i++;
        if (i < text.length && text[i] == '[') continue;
        final read = _name(text, i);
        if (read == null) return const [_Nothing()];
        steps.add(read.$1 == '*' ? const _Wild() : _Child(read.$1));
        i = read.$2;
        continue;
      }
      if (text[i] == '[') {
        final close = _closer(text, i);
        if (close == -1) return const [_Nothing()];
        final step = _bracket(text.substring(i + 1, close).trim());
        if (step == null) return const [_Nothing()];
        steps.add(step);
        i = close + 1;
        continue;
      }
      // A leading segment written without its dot: `store.book`.
      final read = _name(text, i);
      if (read == null) return const [_Nothing()];
      steps.add(read.$1 == '*' ? const _Wild() : _Child(read.$1));
      i = read.$2;
    }
    return steps;
  }

  /// The bare name at [from], and where it ends.
  static (String, int)? _name(String text, int from) {
    if (from >= text.length) return null;
    if (text[from] == '*') return ('*', from + 1);
    var end = from;
    while (end < text.length && !'.[]'.contains(text[end])) {
      end++;
    }
    return end == from ? null : (text.substring(from, end), end);
  }

  /// The index of the `]` closing the `[` at [from], honouring quotes.
  static int _closer(String text, int from) {
    String? quote;
    var depth = 0;
    for (var i = from; i < text.length; i++) {
      final ch = text[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '[' || ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static _Step? _bracket(String inner) {
    if (inner.isEmpty) return null;
    if (inner == '*') return const _Wild();
    if (inner.startsWith('?')) return _filter(inner);
    if (inner.startsWith("'") || inner.startsWith('"')) {
      final names = <String>[];
      for (final part in _split(inner)) {
        final name = _unquote(part);
        if (name == null) return null;
        names.add(name);
      }
      return _Names(names);
    }
    if (inner.contains(':')) {
      final bounds = inner.split(':');
      if (bounds.length > 3) return null;
      var bad = false;
      int? at(int i) {
        if (i >= bounds.length) return null;
        final piece = bounds[i].trim();
        if (piece.isEmpty) return null;
        final value = int.tryParse(piece);
        // A bound that is not a number means this was never a slice, so the
        // whole expression is unreadable rather than an open-ended one.
        if (value == null) bad = true;
        return value;
      }

      final from = at(0);
      final to = at(1);
      final step = at(2) ?? 1;
      if (bad || step == 0) return null;
      return _Slice(from, to, step);
    }
    final indices = <int>[];
    for (final part in _split(inner)) {
      final index = int.tryParse(part.trim());
      if (index == null) return null;
      indices.add(index);
    }
    return _Index(indices);
  }

  /// [inner] split on commas that are not inside quotes.
  static List<String> _split(String inner) {
    final parts = <String>[];
    final buffer = StringBuffer();
    String? quote;
    for (var i = 0; i < inner.length; i++) {
      final ch = inner[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        buffer.write(ch);
      } else if (ch == "'" || ch == '"') {
        quote = ch;
        buffer.write(ch);
      } else if (ch == ',') {
        parts.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    parts.add(buffer.toString());
    return parts;
  }

  static String? _unquote(String part) {
    final text = part.trim();
    if (text.length < 2) return null;
    final first = text[0];
    if ((first == "'" || first == '"') && text.endsWith(first)) {
      return text.substring(1, text.length - 1);
    }
    return null;
  }

  static final _comparison = RegExp(r'(==|!=|<=|>=|=~|<|>|=)');

  static _Step? _filter(String inner) {
    var body = inner.substring(1).trim();
    if (body.startsWith('(') && body.endsWith(')')) {
      body = body.substring(1, body.length - 1).trim();
    }
    if (!body.startsWith('@')) return null;

    final match = _comparison.firstMatch(body);
    if (match == null) {
      final field = _atPath(body);
      return field == null ? null : _Filter(field, null, null);
    }
    final field = _atPath(body.substring(0, match.start).trim());
    if (field == null) return null;
    final literal = _literal(body.substring(match.end).trim());
    return _Filter(field, match.group(0), literal);
  }

  /// The field path an `@.a.b` or `@['a']['b']` reference names.
  static List<String>? _atPath(String text) {
    if (!text.startsWith('@')) return null;
    final rest = text.substring(1);
    if (rest.isEmpty) return const [];
    final names = <String>[];
    var i = 0;
    while (i < rest.length) {
      if (rest[i] == '.') {
        i++;
        continue;
      }
      if (rest[i] == '[') {
        final close = _closer(rest, i);
        if (close == -1) return null;
        final name =
            _unquote(rest.substring(i + 1, close)) ??
            rest.substring(i + 1, close).trim();
        names.add(name);
        i = close + 1;
        continue;
      }
      final read = _name(rest, i);
      if (read == null) return null;
      names.add(read.$1);
      i = read.$2;
    }
    return names;
  }

  static Object? _literal(String text) {
    if (text == 'true') return true;
    if (text == 'false') return false;
    if (text == 'null') return null;
    if (_unquote(text) case final quoted?) return quoted;
    return num.tryParse(text) ?? text;
  }
}

// ----------------------------------------------------------------------------
// Steps
// ----------------------------------------------------------------------------

sealed class _Step {
  const _Step();

  /// Adds everything this step selects from [node] to [out].
  void apply(Object? node, List<Object?> out);
}

/// An expression that could not be read: it selects nothing.
final class _Nothing extends _Step {
  const _Nothing();

  @override
  void apply(Object? node, List<Object?> out) {}
}

final class _Child extends _Step {
  final String name;

  const _Child(this.name);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is Map<Object?, Object?>) {
      if (node.containsKey(name)) out.add(node[name]);
    }
  }
}

final class _Names extends _Step {
  final List<String> names;

  const _Names(this.names);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is Map<Object?, Object?>) {
      for (final name in names) {
        if (node.containsKey(name)) out.add(node[name]);
      }
    }
  }
}

final class _Wild extends _Step {
  const _Wild();

  @override
  void apply(Object? node, List<Object?> out) {
    switch (node) {
      case Map<Object?, Object?> map:
        out.addAll(map.values);
      case List<Object?> list:
        out.addAll(list);
      default:
        break;
    }
  }
}

final class _Index extends _Step {
  final List<int> indices;

  const _Index(this.indices);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is! List<Object?>) return;
    for (final raw in indices) {
      // Negative indices count from the end, as they do in every other
      // positional reader in this library.
      final index = raw < 0 ? node.length + raw : raw;
      if (index >= 0 && index < node.length) out.add(node[index]);
    }
  }
}

final class _Slice extends _Step {
  final int? from;
  final int? to;
  final int step;

  const _Slice(this.from, this.to, this.step);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is! List<Object?>) return;
    final length = node.length;
    int bound(int? value, int fallback) {
      if (value == null) return fallback;
      final resolved = value < 0 ? length + value : value;
      return resolved.clamp(0, length);
    }

    if (step > 0) {
      for (var i = bound(from, 0); i < bound(to, length); i += step) {
        out.add(node[i]);
      }
    } else {
      for (var i = bound(from, length - 1); i > bound(to, -1); i += step) {
        if (i >= 0 && i < length) out.add(node[i]);
      }
    }
  }
}

/// Every descendant of the node, and the node itself.
final class _Descend extends _Step {
  const _Descend();

  @override
  void apply(Object? node, List<Object?> out) {
    out.add(node);
    switch (node) {
      case Map<Object?, Object?> map:
        for (final value in map.values) {
          apply(value, out);
        }
      case List<Object?> list:
        for (final item in list) {
          apply(item, out);
        }
      default:
        break;
    }
  }
}

final class _Filter extends _Step {
  final List<String> field;
  final String? op;
  final Object? literal;

  const _Filter(this.field, this.op, this.literal);

  @override
  void apply(Object? node, List<Object?> out) {
    final candidates = switch (node) {
      List<Object?> list => list,
      Map<Object?, Object?> map => map.values,
      _ => const <Object?>[],
    };
    for (final candidate in candidates) {
      if (_keeps(candidate)) out.add(candidate);
    }
  }

  bool _keeps(Object? candidate) {
    Object? value = candidate;
    for (final name in field) {
      if (value is Map<Object?, Object?>) {
        if (!value.containsKey(name)) return false;
        value = value[name];
      } else {
        return false;
      }
    }
    if (op == null) return value != null;
    return _compare(value, op!, literal);
  }

  static bool _compare(Object? left, String op, Object? right) {
    switch (op) {
      case '==' || '=':
        return _same(left, right);
      case '!=':
        return !_same(left, right);
      case '=~':
        return right is String &&
            left is String &&
            RegExp(_pattern(right)).hasMatch(left);
    }
    final order = switch ((left, right)) {
      (final num a, final num b) => a.compareTo(b),
      (final String a, final String b) => a.compareTo(b),
      _ => null,
    };
    if (order == null) return false;
    return switch (op) {
      '<' => order < 0,
      '<=' => order <= 0,
      '>' => order > 0,
      '>=' => order >= 0,
      _ => false,
    };
  }

  static String _pattern(String literal) {
    // `/re/` is how JSONPath writes a regex literal; anything else is taken
    // as the pattern itself.
    if (literal.length > 1 && literal.startsWith('/')) {
      final end = literal.lastIndexOf('/');
      if (end > 0) return literal.substring(1, end);
    }
    return literal;
  }

  static bool _same(Object? left, Object? right) {
    if (left is num && right is num) return left == right;
    return left == right;
  }
}
