part of '../../../json.dart';

/// A parsed JSONPath expression.
class _JsonPath {
  final List<_Step> _steps;

  const _JsonPath._(this._steps);

  static final _cache = <String, _JsonPath>{};

  /// [expression] compiled, once per distinct text.
  static _JsonPath of(String expression) => compiled(_cache, expression, () => _JsonPath._(_parse(expression)));

  /// Every value this selects from [root], in document order.
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

  static List<_Step> _parse(String expression) {
    final text = expression.trim();
    final steps = <_Step>[];
    if (!text.startsWith(r'$')) throw FormatException(r'JSONPath starts at the root, $', expression, 0);
    var i = 1;

    while (i < text.length) {
      if (text.startsWith('..', i)) {
        i += 2;
        if (i >= text.length || text[i] == '*') {
          steps.add(const _Descend(null));
          if (i < text.length && text[i] == '*') i++;
          continue;
        }
        if (text[i] == '[') {
          // `..[0]`: the bracket applies to every descendant and the node itself.
          steps.add(const _Descend(null, includeSelf: true));
          continue;
        }
        final (name, end) = _readName(text, i);
        steps.add(_Descend(name == '*' ? null : name));
        i = end;
        continue;
      }

      if (text[i] == '.') {
        i++; // a separator; the name or bracket after it is the step
        continue;
      }

      if (text[i] == '[') {
        final (step, end) = _bracket(text, i + 1, expression);
        steps.add(step);
        i = end;
        continue;
      }

      final (name, end) = _readName(text, i);
      if (name.isNotEmpty) steps.add(name == '*' ? const _Wild() : _Child(name));
      i = end;
    }

    return steps;
  }

  /// The bracket whose content starts at [start] — `*`, a quoted name, an index, a slice, or a
  /// union of those — and the index after its `]`.
  static (_Step, int) _bracket(String text, int start, String expression) {
    Never fail(String why) => throw FormatException('$why in JSONPath', expression, start);
    final parts = <_Step>[];
    var i = start;
    void spaces() {
      while (i < text.length && text[i] == ' ') {
        i++;
      }
      if (i >= text.length) fail('Unclosed bracket');
    }

    while (true) {
      spaces();
      final c = text[i];
      if (c == '?' || c == '(') fail('Filters are not supported — use .where on the result');
      if (c == '"' || c == "'") {
        final sb = StringBuffer();
        for (i++; i < text.length && text[i] != c; i++) {
          if (text[i] == r'\' && i + 1 < text.length) i++;
          sb.write(text[i]);
        }
        if (i >= text.length) fail('Unterminated string');
        i++;
        parts.add(_Child(sb.toString()));
      } else {
        final from = i;
        while (i < text.length && text[i] != ',' && text[i] != ']') {
          i++;
        }
        final item = text.substring(from, i).trim();
        if (item == '*') {
          parts.add(const _Wild());
        } else if (int.tryParse(item) case final k?) {
          parts.add(_Index(k));
        } else if (item.contains(':')) {
          final bounds = item.split(':');
          if (bounds.length > 3) fail('Bad slice "[$item]"');
          int? bound(int k) => k < bounds.length && bounds[k].trim().isNotEmpty
              ? int.tryParse(bounds[k].trim()) ?? fail('Bad slice "[$item]"')
              : null;
          parts.add(_Slice(bound(0), bound(1), bound(2) ?? 1));
        } else {
          fail('Invalid bracket expression "[$item]"');
        }
      }
      spaces();
      if (text[i] == ']') return (parts.length == 1 ? parts.single : _Parts(parts), i + 1);
      if (text[i] != ',') fail('Expected "," or "]"');
      i++;
    }
  }

  static (String, int) _readName(String text, int start) {
    var end = start;
    while (end < text.length && text[end] != '.' && text[end] != '[') {
      end++;
    }
    return (text.substring(start, end).trim(), end);
  }
}

sealed class _Step {
  const _Step();
  void apply(Object? node, List<Object?> out);
}

final class _Child extends _Step {
  final String key;
  const _Child(this.key);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is Map && node.containsKey(key)) out.add(node[key]);
  }
}

final class _Index extends _Step {
  final int index;
  const _Index(this.index);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is List) {
      final i = index < 0 ? node.length + index : index;
      if (i >= 0 && i < node.length) out.add(node[i]);
    }
  }
}

/// `[start:end:step]` over a list, with Python's defaults and negative indices.
final class _Slice extends _Step {
  final int? start, end;
  final int step;
  const _Slice(this.start, this.end, this.step);

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is! List || step == 0) return;
    final n = node.length;
    int at(int? i, int or) => i == null ? or : (i < 0 ? i + n : i);
    if (step > 0) {
      for (var i = at(start, 0).clamp(0, n); i < at(end, n).clamp(0, n); i += step) {
        out.add(node[i]);
      }
    } else {
      final low = at(end, -n - 1).clamp(-1, n - 1);
      for (var i = at(start, n - 1).clamp(-1, n - 1); i > low; i += step) {
        out.add(node[i]);
      }
    }
  }
}

/// `[a, 'b', 0, 1:3]`: each part's matches, in the order written.
final class _Parts extends _Step {
  final List<_Step> parts;
  const _Parts(this.parts);

  @override
  void apply(Object? node, List<Object?> out) {
    for (final p in parts) {
      p.apply(node, out);
    }
  }
}

final class _Wild extends _Step {
  const _Wild();

  @override
  void apply(Object? node, List<Object?> out) {
    if (node is List) {
      out.addAll(node);
    } else if (node is Map) {
      out.addAll(node.values);
    }
  }
}

final class _Descend extends _Step {
  final String? key;
  final bool includeSelf;
  const _Descend(this.key, {this.includeSelf = false});

  @override
  void apply(Object? node, List<Object?> out) {
    if (includeSelf) out.add(node);
    // Depth first in document order, on a stack of iterators rather than the call stack:
    // `jsonDecode` reads a document 100 000 deep, so `..` must walk one too.
    final stack = <Iterator<Object?>>[];
    void enter(Object? n) {
      if (n is Map) {
        if (key != null && n.containsKey(key)) out.add(n[key]);
        stack.add(n.values.iterator);
      } else if (n is List) {
        stack.add(n.iterator);
      }
    }

    enter(node);
    while (stack.isNotEmpty) {
      final it = stack.last;
      if (!it.moveNext()) {
        stack.removeLast();
        continue;
      }
      if (key == null) out.add(it.current);
      enter(it.current);
    }
  }
}
