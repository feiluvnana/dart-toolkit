import 'dart:collection';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

// ============================================================================
// SELECTOR & QUERY RESULT ($() and QueryResult)
// ============================================================================

/// Top-level jQuery-style selector and DOM parsing function.
///
/// Accepts CSS selectors, HTML fragments, DOM [Element]s, or [Document]s:
/// ```dart
/// // Parse HTML snippet and query
/// final heading = $('<div><h1>Hello World</h1></div>')('h1').text;
///
/// // Query inside a specific context
/// final links = $('a.track', response.doc).links();
/// ```
QueryResult $(Object? target, [Object? context]) {
  if (target == null) return QueryResult([]);
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
///
/// Implements [Iterable] for straightforward iteration, mapping, and filtering,
/// while providing DOM traversal, attribute extraction, and link collection methods.
class QueryResult with IterableMixin<Element> {
  final List<Element> _elements;

  /// Wraps an optional list of [Element]s.
  QueryResult([List<Element>? elements]) : _elements = elements ?? [];

  /// Parses an HTML string and wraps its root body elements.
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

  /// Returns the first element in the collection, or `null` if empty.
  Element? get firstOrNull => _elements.isEmpty ? null : _elements.first;

  /// Returns the last element in the collection, or `null` if empty.
  Element? get lastOrNull => _elements.isEmpty ? null : _elements.last;

  /// Returns a new [QueryResult] containing only the first element.
  QueryResult get firstMatch =>
      _elements.isEmpty ? QueryResult([]) : QueryResult([_elements.first]);

  /// Returns a new [QueryResult] containing only the last element.
  QueryResult get lastMatch =>
      _elements.isEmpty ? QueryResult([]) : QueryResult([_elements.last]);

  /// Returns a new [QueryResult] containing the element at [index], or an empty query if out of bounds.
  QueryResult eq(int index) {
    if (index < 0 || index >= _elements.length) return QueryResult([]);
    return QueryResult([_elements[index]]);
  }

  /// Accesses the element at [index].
  Element operator [](int index) => _elements[index];

  /// Alias for [find] using jQuery `$()` notation.
  QueryResult $(String selector) => find(selector);

  /// Callable invocation alias for [find].
  QueryResult call(String selector) => find(selector);

  /// Searches descendant elements matching the CSS [selector].
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

  /// Filters the collection by a CSS selector string or predicate function `bool Function(Element)`.
  QueryResult filter(Object test) {
    if (test is String) {
      return filterBy(test);
    } else if (test is bool Function(Element)) {
      return QueryResult(_elements.where(test).toList());
    } else if (test is Function) {
      return QueryResult(
        _elements.where((e) {
          try {
            return Function.apply(test, [e]) == true;
          } catch (_) {
            return false;
          }
        }).toList(),
      );
    }
    return this;
  }

  /// Retains only elements that match the given CSS [selector].
  QueryResult filterBy(String selector) {
    return filter((Element elem) {
      final parent = elem.parent;
      if (parent == null) return false;
      return parent.querySelectorAll(selector).contains(elem);
    });
  }

  /// Removes elements that match the given CSS [selector].
  QueryResult not(String selector) {
    return filter((Element elem) {
      final parent = elem.parent;
      if (parent == null) return true;
      return !parent.querySelectorAll(selector).contains(elem);
    });
  }

  /// Returns the direct child elements of each element in the set, optionally filtered by [selector].
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

  /// Returns the immediate parent element of each element in the set, optionally filtered by [selector].
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

  /// Traverses up the DOM tree to find the first ancestor matching [selector] for each element.
  QueryResult closest(String selector) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      Element? current = elem;
      while (current != null) {
        final parent = current.parent;
        if (parent != null &&
            parent.querySelectorAll(selector).contains(current)) {
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

  /// Returns the sibling elements of each element in the set, optionally filtered by [selector].
  QueryResult siblings([String? selector]) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      final p = elem.parent;
      if (p == null) continue;
      for (final sibling in p.children) {
        if (sibling == elem) continue;
        if (selector != null &&
            !p.querySelectorAll(selector).contains(sibling)) {
          continue;
        }
        if (seen.add(sibling)) {
          results.add(sibling);
        }
      }
    }
    return QueryResult(results);
  }

  /// Returns the immediately preceding sibling element for each element in the set, optionally filtered by [selector].
  QueryResult prev([String? selector]) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      final p = elem.parent;
      if (p == null) continue;
      final idx = p.children.indexOf(elem);
      if (idx > 0) {
        final prevElem = p.children[idx - 1];
        if (selector != null &&
            !p.querySelectorAll(selector).contains(prevElem)) {
          continue;
        }
        if (seen.add(prevElem)) {
          results.add(prevElem);
        }
      }
    }
    return QueryResult(results);
  }

  /// Returns the immediately following sibling element for each element in the set, optionally filtered by [selector].
  QueryResult next([String? selector]) {
    final results = <Element>[];
    final seen = <Element>{};

    for (final elem in _elements) {
      final p = elem.parent;
      if (p == null) continue;
      final idx = p.children.indexOf(elem);
      if (idx != -1 && idx + 1 < p.children.length) {
        final nextElem = p.children[idx + 1];
        if (selector != null &&
            !p.querySelectorAll(selector).contains(nextElem)) {
          continue;
        }
        if (seen.add(nextElem)) {
          results.add(nextElem);
        }
      }
    }
    return QueryResult(results);
  }

  /// Combined trimmed text content of all matched elements joined by spaces.
  String get text =>
      _elements.map((e) => e.text.trim()).where((s) => s.isNotEmpty).join(' ');

  /// Returns the trimmed text content of the element at [index], or an empty string if out of bounds.
  String textAt(int index) {
    if (index < 0 || index >= _elements.length) return '';
    return _elements[index].text.trim();
  }

  /// List of trimmed text strings for each element in the collection.
  List<String> get texts => _elements.map((e) => e.text.trim()).toList();

  /// The inner HTML of the first matched element, or an empty string if empty.
  String get html => _elements.isEmpty ? '' : _elements.first.innerHtml;

  /// The outer HTML of the first matched element, or an empty string if empty.
  String get outerHtml => _elements.isEmpty ? '' : _elements.first.outerHtml;

  /// Gets the attribute value with [name] from the first matched element, or `null`.
  String? attr(String name) =>
      _elements.isEmpty ? null : _elements.first.attributes[name];

  /// Gets all non-null attribute values with [name] across all matched elements.
  List<String> attrs(String name) {
    return _elements
        .map((e) => e.attributes[name])
        .whereType<String>()
        .toList();
  }

  /// Gets the input, select, or textarea value of the first matched element.
  String? val() {
    if (_elements.isEmpty) return null;
    final elem = _elements.first;
    if (elem.localName == 'textarea') {
      return elem.text;
    }
    return elem.attributes['value'];
  }

  /// Gets data attribute(s). If [key] is supplied, returns `data-[key]`.
  /// Otherwise, returns a Map of all `data-*` attributes for the first matched element.
  Object? data([String? key]) {
    if (_elements.isEmpty) return key != null ? null : <String, String>{};
    final elem = _elements.first;
    if (key != null) {
      return elem.attributes['data-$key'] ?? elem.attributes[key];
    }
    final map = <String, String>{};
    for (final entry in elem.attributes.entries) {
      final k = entry.key.toString();
      if (k.startsWith('data-')) {
        map[k.substring(5)] = entry.value;
      }
    }
    return map;
  }

  /// Checks whether any element in the collection has the given CSS [className].
  bool hasClass(String className) {
    for (final elem in _elements) {
      if (elem.classes.contains(className)) return true;
    }
    return false;
  }

  /// Iterates over each element with its 0-based index.
  void each(void Function(Element element, int index) fn) {
    for (var i = 0; i < _elements.length; i++) {
      fn(_elements[i], i);
    }
  }

  /// Maps each element with its 0-based index to a new list.
  List<R> mapIndexed<R>(R Function(Element element, int index) fn) {
    final list = <R>[];
    for (var i = 0; i < _elements.length; i++) {
      list.add(fn(_elements[i], i));
    }
    return list;
  }

  /// Returns an unmodifiable list of the underlying [Element] instances.
  List<Element> list() => List.unmodifiable(_elements);

  /// Extracts text lines split by `<br>` tags and newlines, stripping all internal HTML tags.
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

  /// Returns the first `href` attribute found in `<a>`, `<link>`, or `<area>` tags, optionally matching [filter].
  String? link([Pattern? filter]) => links(filter).firstOrNull;

  /// Extracts all `href` attributes found in `<a>`, `<link>`, and `<area>` tags, optionally matching [filter].
  List<String> links([Pattern? filter]) {
    final list = <String>[];
    for (final elem in _elements) {
      final href = elem.attributes['href'];
      if (href != null &&
          (filter == null || filter.allMatches(href).isNotEmpty)) {
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

  /// Returns the first `src` attribute found in `<img>`, media, or `<script>` tags, optionally matching [filter].
  String? src([Pattern? filter]) => srcs(filter).firstOrNull;

  /// Extracts all `src` attributes found in `<img>`, media, and `<script>` tags, optionally matching [filter].
  List<String> srcs([Pattern? filter]) {
    final list = <String>[];
    for (final elem in _elements) {
      final s = elem.attributes['src'];
      if (s != null && (filter == null || filter.allMatches(s).isNotEmpty)) {
        list.add(s);
      }
      for (final img in elem.querySelectorAll(
        'img, audio, video, source, script',
      )) {
        final isrc = img.attributes['src'];
        if (isrc != null &&
            (filter == null || filter.allMatches(isrc).isNotEmpty)) {
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

/// Selector extensions on individual [Element] instances.
extension QuerySelectorOnElement on Element {
  /// Queries descendants of this element matching CSS [selector].
  QueryResult $(String selector) => QueryResult(querySelectorAll(selector));

  /// Alias for [$].
  QueryResult find(String selector) => QueryResult(querySelectorAll(selector));

  /// Gets the attribute value for [name].
  String? attr(String name) => attributes[name];

  /// Wraps this element into a single-element [QueryResult].
  QueryResult get asQuery => QueryResult([this]);
}

/// Selector extensions on parsed HTML [Document] instances.
extension QuerySelectorOnDocument on Document {
  /// Queries elements within this document matching CSS [selector].
  QueryResult $(String selector) => QueryResult(querySelectorAll(selector));

  /// Wraps the root element of this document into a [QueryResult].
  QueryResult get asQuery {
    final root = documentElement ?? body;
    return QueryResult(root != null ? [root] : []);
  }
}

/// Selector extensions on raw HTML strings.
extension QuerySelectorOnHtmlString on String {
  /// Parses this string as HTML and wraps its body elements into a [QueryResult].
  QueryResult parseHtml() => QueryResult.html(this);

  /// Parses this string as HTML and queries elements matching CSS [selector].
  QueryResult $(String selector) {
    final doc = html_parser.parse(this);
    return QueryResult(doc.querySelectorAll(selector));
  }
}
