import 'dart:collection';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

// ============================================================================
// SELECTOR & QUERY RESULT ($() and QueryResult)
// ============================================================================

/// Top-level jQuery-like selector function.
QueryResult $(dynamic target, [dynamic context]) {
  if (target is QueryResult) {
    if (context == null) return target;
    return target.find(context.toString());
  }

  if (target is Element) {
    return QueryResult([target]);
  }

  if (target is Iterable<Element>) {
    return QueryResult(target.toList());
  }

  if (target is Document) {
    final root = target.documentElement ?? target.body;
    return QueryResult(root != null ? [root] : []);
  }

  if (target is String) {
    final trimmed = target.trim();
    if (trimmed.isEmpty) return QueryResult([]);

    if (context != null) {
      try {
        if (context is Document) {
          return QueryResult(context.querySelectorAll(trimmed));
        }
        if (context is Element) {
          return QueryResult(context.querySelectorAll(trimmed));
        }
        if (context is QueryResult) {
          return context.find(trimmed);
        }
        if (context is String) {
          final doc = html_parser.parse(context);
          return QueryResult(doc.querySelectorAll(trimmed));
        }
      } catch (_) {
        return QueryResult([]);
      }
    }

    if (trimmed.contains('<') ||
        trimmed.contains('>') ||
        !trimmed.startsWith(RegExp(r'[.#a-zA-Z*\[:]'))) {
      final doc = html_parser.parse(trimmed);
      final bodyChildren = doc.body?.children;
      if (bodyChildren != null && bodyChildren.isNotEmpty) {
        return QueryResult(bodyChildren.toList());
      }
      final root = doc.documentElement ?? doc.body;
      return QueryResult(root != null ? [root] : []);
    }

    try {
      final doc = html_parser.parse(trimmed);
      return QueryResult(doc.querySelectorAll(trimmed));
    } catch (_) {
      final doc = html_parser.parse(trimmed);
      final root = doc.documentElement ?? doc.body;
      return QueryResult(root != null ? [root] : []);
    }
  }

  return QueryResult([]);
}

/// A jQuery-like collection wrapper around HTML [Element]s.
class QueryResult with IterableMixin<Element> {
  final List<Element> _elements;

  QueryResult([List<Element>? elements]) : _elements = elements ?? [];

  factory QueryResult.html(String html) {
    final doc = html_parser.parse(html);
    return QueryResult(doc.body?.children.toList() ?? []);
  }

  @override
  Iterator<Element> get iterator => _elements.iterator;

  @override
  int get length => _elements.length;

  @override
  bool get isEmpty => _elements.isEmpty;

  @override
  bool get isNotEmpty => _elements.isNotEmpty;

  Element? get firstOrNull => _elements.isEmpty ? null : _elements.first;
  Element? get lastOrNull => _elements.isEmpty ? null : _elements.last;

  QueryResult get firstMatch =>
      _elements.isEmpty ? QueryResult([]) : QueryResult([_elements.first]);

  QueryResult get lastMatch =>
      _elements.isEmpty ? QueryResult([]) : QueryResult([_elements.last]);

  QueryResult eq(int index) {
    if (index < 0 || index >= _elements.length) return QueryResult([]);
    return QueryResult([_elements[index]]);
  }

  Element operator [](int index) => _elements[index];
  QueryResult $(String selector) => find(selector);
  QueryResult call(String selector) => find(selector);

  QueryResult find(String selector) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      for (final match in elem.querySelectorAll(selector)) {
        if (seen.add(match)) {
          results.add(match);
        }
      }
    }
    return QueryResult(results);
  }

  QueryResult filter(dynamic test) {
    if (test is String) {
      return filterBy(test);
    } else if (test is Function) {
      return QueryResult(_elements.where((e) => test(e) == true).toList());
    }
    return this;
  }

  QueryResult filterBy(String selector) {
    return filter((elem) {
      final parent = elem.parent;
      if (parent == null) return false;
      return parent.querySelectorAll(selector).contains(elem);
    });
  }

  QueryResult not(String selector) {
    return filter((elem) {
      final parent = elem.parent;
      if (parent == null) return true;
      return !parent.querySelectorAll(selector).contains(elem);
    });
  }

  QueryResult children([String? selector]) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      for (final child in elem.children) {
        if (selector != null) {
          if (!elem.querySelectorAll(selector).contains(child)) continue;
        }
        if (seen.add(child)) {
          results.add(child);
        }
      }
    }
    return QueryResult(results);
  }

  QueryResult parent([String? selector]) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      final p = elem.parent;
      if (p != null) {
        if (selector != null) {
          final grand = p.parent;
          if (grand != null && !grand.querySelectorAll(selector).contains(p)) {
            continue;
          }
        }
        if (seen.add(p)) {
          results.add(p);
        }
      }
    }
    return QueryResult(results);
  }

  QueryResult closest(String selector) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      Element? current = elem;
      while (current != null) {
        final parent = current.parent;
        if (parent != null && parent.querySelectorAll(selector).contains(current)) {
          if (seen.add(current)) {
            results.add(current);
          }
          break;
        }
        current = current.parent;
      }
    }
    return QueryResult(results);
  }

  QueryResult siblings([String? selector]) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      final p = elem.parent;
      if (p == null) continue;
      for (final sibling in p.children) {
        if (sibling == elem) continue;
        if (selector != null && !p.querySelectorAll(selector).contains(sibling)) {
          continue;
        }
        if (seen.add(sibling)) {
          results.add(sibling);
        }
      }
    }
    return QueryResult(results);
  }

  String get text => _elements.map((e) => e.text.trim()).where((s) => s.isNotEmpty).join(' ');

  String textAt(int index) {
    if (index < 0 || index >= _elements.length) return '';
    return _elements[index].text.trim();
  }

  List<String> get texts => _elements.map((e) => e.text.trim()).toList();
  String get html => _elements.isEmpty ? '' : _elements.first.innerHtml;
  String get outerHtml => _elements.isEmpty ? '' : _elements.first.outerHtml;

  String? attr(String name) =>
      _elements.isEmpty ? null : _elements.first.attributes[name];

  List<String> attrs(String name) {
    return _elements
        .map((e) => e.attributes[name])
        .whereType<String>()
        .toList();
  }

  bool hasClass(String className) {
    for (final elem in _elements) {
      if (elem.classes.contains(className)) return true;
    }
    return false;
  }

  bool has(String className) => hasClass(className);

  void each(void Function(Element element, int index) fn) {
    for (var i = 0; i < _elements.length; i++) {
      fn(_elements[i], i);
    }
  }

  List<R> mapIndexed<R>(R Function(Element element, int index) fn) {
    final list = <R>[];
    for (var i = 0; i < _elements.length; i++) {
      list.add(fn(_elements[i], i));
    }
    return list;
  }

  List<Element> list() => List.unmodifiable(_elements);
  List<Element> toElements() => list();

  List<String> get lines {
    final res = <String>[];
    for (final elem in _elements) {
      final parts = elem.innerHtml
          .split(RegExp(r'<br\s*/?>|\r?\n'))
          .map((s) => s.replaceAll(RegExp(r'<[^>]*>'), '').trim())
          .where((s) => s.isNotEmpty);
      res.addAll(parts);
    }
    return res;
  }

  String? link([Pattern? filter]) => links(filter).firstOrNull;

  List<String> links([Pattern? filter]) {
    final list = <String>[];
    for (final elem in _elements) {
      final href = elem.attributes['href'];
      if (href != null && (filter == null || filter.allMatches(href).isNotEmpty)) {
        list.add(href);
      }
      for (final a in elem.querySelectorAll('a, link, area')) {
        final h = a.attributes['href'];
        if (h != null && (filter == null || filter.allMatches(h).isNotEmpty)) {
          list.add(h);
        }
      }
    }
    return list;
  }

  String? src([Pattern? filter]) => srcs(filter).firstOrNull;

  List<String> srcs([Pattern? filter]) {
    final list = <String>[];
    for (final elem in _elements) {
      final s = elem.attributes['src'];
      if (s != null && (filter == null || filter.allMatches(s).isNotEmpty)) {
        list.add(s);
      }
      for (final img in elem.querySelectorAll('img, audio, video, source, script')) {
        final isrc = img.attributes['src'];
        if (isrc != null && (filter == null || filter.allMatches(isrc).isNotEmpty)) {
          list.add(isrc);
        }
      }
    }
    return list;
  }

  @override
  String toString() =>
      'QueryResult(length: $length, texts: [${texts.take(3).join(', ')}${length > 3 ? '...' : ''}])';
}

extension QuerySelectorOnElement on Element {
  QueryResult $(String selector) => QueryResult(querySelectorAll(selector));
  QueryResult find(String selector) => QueryResult(querySelectorAll(selector));
  String? attr(String name) => attributes[name];
  QueryResult get asQuery => QueryResult([this]);
}

extension QuerySelectorOnDocument on Document {
  QueryResult $(String selector) => QueryResult(querySelectorAll(selector));
  QueryResult get asQuery {
    final root = documentElement ?? body;
    return QueryResult(root != null ? [root] : []);
  }
}

extension QuerySelectorOnHtmlString on String {
  QueryResult parseHtml() => QueryResult.html(this);
  QueryResult $(String selector) {
    final doc = html_parser.parse(this);
    return QueryResult(doc.querySelectorAll(selector));
  }
}
