/// Minimal HTML scraping. Thin facade over `package:html`.
///
/// ```dart
/// final doc = await Http.get('https://example.com/article').html();
/// final body = doc.without('script, style, nav, .ads').$('article').text();
/// final next = await Http.get(url).html().$('a.next')[0].attr('href');
/// ```
///
/// Public surface is exactly: [Html], [Elements], [Element].
/// - `Html.parse()` parses HTML and returns [Elements].
/// - [Elements] supports `$` `[]` `without` `text` `attr` `attrs` (plus [Iterable] helpers).
/// - [Element] supports `$` `without` `text` `attr` `parent`.
/// A selector the engine rejects is a [FormatException] naming the selector.
/// Everything else is private.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import 'core.dart';
export 'core.dart';

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html] as a fragment. Never throws on malformed markup.
  /// [baseUrl] is the base for relative links: with one, `attr('href')` and
  /// `attr('src')` return absolute URLs.
  static Elements parse(String html, {String? baseUrl}) {
    final doc = parser.parseFragment(html);
    return Elements._(
      [for (final n in doc.nodes) if (n is dom.Element) Element._(n, baseUrl)],
      doc.querySelectorAll,
      baseUrl,
    );
  }
}

/// A list of elements. Query with `$()`, read with `[]`.
final class Elements extends Iterable<Element> {
  Elements._(this._items, this._query, this._baseUrl);

  final List<Element> _items;
  final String? _baseUrl;

  /// Document-level query from the engine (stored as a closure so this
  /// class never depends on the engine's document types).
  final List<dom.Element> Function(String) _query;

  /// Every match that is one of these elements or a descendant of one,
  /// in document order and without duplicates.
  Elements $(String selector) {
    if (_items.isEmpty) return Elements._(<Element>[], _query, _baseUrl);
    if (_items.length == 1) return _items.single.$(selector);
    final found = _select(selector);
    final scope = <dom.Element>{for (final e in _items) e._el};
    final out = <Element>[];
    for (final el in found) {
      dom.Element? cur = el;
      while (cur != null && !scope.contains(cur)) {
        cur = cur.parent;
      }
      if (cur != null) out.add(Element._(el, _baseUrl));
    }
    return Elements._(out, _query, _baseUrl);
  }

  /// Element at [index] (throws [RangeError] if out of bounds).
  Element operator [](int index) =>
      _items[index];

  /// A new tree without every match of [selector] and its subtree.
  /// The receiver is unchanged. Copies the tree once.
  Elements without(String selector) {
    final doomed = _select(selector).toSet();
    final kept = <String>[];
    for (final item in _items) {
      if (doomed.contains(item._el)) continue;
      final clone = item._el.clone(true);
      try {
        for (final m in clone.querySelectorAll(selector)) {
          m.remove();
        }
      } on FormatException catch (e) {
        throw FormatException(
          "invalid selector '$selector': ${e.message}",
          e.source,
          e.offset,
        );
      } catch (e) {
        throw FormatException("invalid selector '$selector': $e");
      }
      kept.add(clone.outerHtml);
    }
    return Html.parse(kept.join(), baseUrl: _baseUrl);
  }

  /// Every element's text joined, untrimmed. Reads the first match without
  /// `[0]`: `doc.$('title').text()`.
  String text() => _items.map((e) => e.text()).join();

  /// The first match's attribute, or `null` when nothing matched or the
  /// attribute is absent. Case-insensitive; `href`/`src` resolve with the base.
  String? attr(String name) {
    final first = _items.firstOrNull;
    return first?.attr(name);
  }

  /// Every match's value of [name] in document order, absent ones skipped.
  /// Links resolve against the base, so `$('a.item').attrs('href')` is the
  /// list of links to follow.
  List<String> attrs(String name) => [
        for (final e in _items) ?e.attr(name),
      ];

  List<dom.Element> _select(String selector) {
    try {
      return _query(selector);
    } on FormatException catch (e) {
      throw FormatException(
        "invalid selector '$selector': ${e.message}",
        e.source,
        e.offset,
      );
    } catch (e) {
      throw FormatException("invalid selector '$selector': $e");
    }
  }

  @override
  int get length => _items.length;

  @override
  Iterator<Element> get iterator => _items.iterator;
}

/// A single element.
final class Element {
  Element._(this._el, this._baseUrl);

  final dom.Element _el;
  final String? _baseUrl;

  /// The same query run on this one element: matches that are this element
  /// or a descendant of it.
  Elements $(String selector) {
    List<dom.Element> found;
    try {
      found = _el.querySelectorAll(selector);
    } on FormatException catch (e) {
      throw FormatException(
        "invalid selector '$selector': ${e.message}",
        e.source,
        e.offset,
      );
    } catch (e) {
      throw FormatException("invalid selector '$selector': $e");
    }
    final out = <Element>[for (final el in found) Element._(el, _baseUrl)];
    if (_matchesSelf(selector)) out.insert(0, this);
    return Elements._(out, (s) => _el.querySelectorAll(s), _baseUrl);
  }

  /// A copy of this element without every match of [selector] and its
  /// subtree. The receiver is unchanged.
  Element without(String selector) {
    final clone = _el.clone(true);
    List<dom.Element> found;
    try {
      found = clone.querySelectorAll(selector);
    } on FormatException catch (e) {
      throw FormatException(
        "invalid selector '$selector': ${e.message}",
        e.source,
        e.offset,
      );
    } catch (e) {
      throw FormatException("invalid selector '$selector': $e");
    }
    for (final m in found) {
      m.remove();
    }
    return Element._(clone, _baseUrl);
  }

  /// Concatenated descendant text, untrimmed.
  String text() => _el.text;

  /// Attribute [name] (case-insensitive) or `null` if absent. With a base
  /// URL, `href` and `src` resolve to absolute URLs.
  String? attr(String name) {
    final raw = _el.attributes[name.toLowerCase()];
    if (raw == null) return null;
    final base = _baseUrl;
    final lower = name.toLowerCase();
    if (base != null && (lower == 'href' || lower == 'src')) {
      try {
        return Uri.parse(base).resolve(raw).toString();
      } catch (_) {
        return raw;
      }
    }
    return raw;
  }

  /// Parent element, or `null` at top level.
  Element? parent() {
    final p = _el.parent;
    return p == null ? null : Element._(p, _baseUrl);
  }

  bool _matchesSelf(String selector) {
    try {
      // Fast path: ask the parent's subtree, which already contains this
      // element by identity. No reparse on the hot path (row.$('td')).
      final parent = _el.parent;
      if (parent != null) {
        return parent.querySelectorAll(selector).contains(_el);
      }
      final scratch = parser.parseFragment(
        '<div>${_el.outerHtml}</div>',
      );
      final wrapper = scratch.querySelector('div');
      if (wrapper == null) return false;
      final kids = wrapper.querySelectorAll(selector);
      final root = wrapper.nodes
          .whereType<dom.Element>()
          .firstOrNull;
      return root != null && kids.contains(root);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException("invalid selector '$selector': $e");
    }
  }
}

/// Bytes → a value. Relative links resolve against the response's URL
/// (or the file's URI); other readers parse without a base.
extension ReaderHtml on Reader {
  Future<Elements> html() async =>
      Html.parse(await text(), baseUrl: _baseUrlOf(this));
}

/// Same, from an async reader.
extension ReaderFutureHtml on Future<Reader> {
  Future<Elements> html() async => (await this).html();
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension ElementsFuture on Future<Elements> {
  Future<Elements> $(String selector) async => (await this).$(selector);
  Future<Element> operator [](int index) async => (await this)[index];
  Future<Elements> without(String selector) async =>
      (await this).without(selector);
  Future<String> text() async => (await this).text();
  Future<String?> attr(String name) async => (await this).attr(name);
  Future<List<String>> attrs(String name) async => (await this).attrs(name);
}

/// Future mirrors for [Element].
extension ElementFuture on Future<Element> {
  Future<Elements> $(String selector) async => (await this).$(selector);
  Future<Element> without(String selector) async =>
      (await this).without(selector);
  Future<String> text() async => (await this).text();
  Future<String?> attr(String name) async => (await this).attr(name);
  Future<Element?> parent() async => (await this).parent();
}

String? _baseUrlOf(Reader reader) {
  // The reader's own URL when it has one (a response's final URL) or its
  // path as a file URI. Dynamic so this module never imports http or fs.
  try {
    // ignore: avoid_dynamic_calls
    final u = (reader as dynamic).url() as String?;
    if (u != null && u.isNotEmpty) return u;
  } catch (_) {}
  try {
    // ignore: avoid_dynamic_calls
    final path = (reader as dynamic).path() as String?;
    if (path != null) {
      try {
        return Uri.file(path).toString();
      } catch (_) {
        return null;
      }
    }
  } catch (_) {}
  return null;
}
