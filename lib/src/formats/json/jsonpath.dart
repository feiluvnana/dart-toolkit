// # JSONPath (internal)
//
// A lightweight and fast JSONPath evaluator.

part of '../../../formats.dart';

/// A parsed JSONPath expression.
class _JsonPath {
  final List<_Step> _steps;

  const _JsonPath._(this._steps);

  static final _cache = <String, _JsonPath>{};
  static const _maxCacheSize = 256;

  /// Compiles or retrieves a cached JSONPath expression.
  static _JsonPath of(String expression) {
    final cached = _cache[expression];
    if (cached != null) return cached;

    final compiled = _JsonPath._(_parse(expression));
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[expression] = compiled;
    return compiled;
  }

  /// Evaluates this expression against [root] and returns all matching values in document order.
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
    var i = 0;
    if (text.startsWith(r'$')) i = 1;

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
        final name = _readName(text, i);
        steps.add(_Descend(name.$1 == '*' ? null : name.$1));
        i = name.$2;
        continue;
      }

      if (text[i] == '.') {
        i++;
        if (i < text.length && text[i] == '[') continue;
        if (i < text.length && text[i] == '*') {
          steps.add(const _Wild());
          i++;
          continue;
        }
        final name = _readName(text, i);
        if (name.$1.isNotEmpty) {
          steps.add(name.$1 == '*' ? const _Wild() : _Child(name.$1));
        }
        i = name.$2;
        continue;
      }

      if (text[i] == '[') {
        final close = text.indexOf(']', i);
        if (close == -1) {
          throw FormatException('Unclosed bracket in JSONPath expression: $expression');
        }
        final inside = text.substring(i + 1, close).trim();
        i = close + 1;

        if (inside == '*' || inside.isEmpty) {
          steps.add(const _Wild());
        } else if (int.tryParse(inside) case final idx?) {
          steps.add(_Index(idx));
        } else if (inside.contains(':')) {
          throw UnsupportedError('JSONPath array slice syntax "[$inside]" is not supported');
        } else if (inside.startsWith('?') || inside.startsWith('(')) {
          throw UnsupportedError('JSONPath filter expressions "[$inside]" are not supported');
        } else if ((inside.startsWith("'") && inside.endsWith("'")) ||
            (inside.startsWith('"') && inside.endsWith('"'))) {
          final clean = inside.substring(1, inside.length - 1);
          steps.add(_Child(clean));
        } else {
          throw FormatException('Invalid JSONPath bracket expression: [$inside]');
        }
        continue;
      }

      final name = _readName(text, i);
      if (name.$1.isNotEmpty) {
        steps.add(name.$1 == '*' ? const _Wild() : _Child(name.$1));
      }
      i = name.$2;
    }

    return steps;
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
    if (node is Map && node.containsKey(key)) {
      out.add(node[key]);
    }
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
    void walk(Object? n) {
      if (n is Map) {
        if (key != null && n.containsKey(key)) {
          out.add(n[key]);
        }
        for (final v in n.values) {
          if (key == null) out.add(v);
          walk(v);
        }
      } else if (n is List) {
        for (final v in n) {
          if (key == null) out.add(v);
          walk(v);
        }
      }
    }

    walk(node);
  }
}
