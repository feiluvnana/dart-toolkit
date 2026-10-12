/// Ultra-minimal HTML scraping API. Thin facade over `package:html`:
/// same `$()` syntax, the engine underneath.
///
/// ```dart
/// final doc = Html.parse('<div class="a"><p>Hello <a href="/">link</a></p></div>');
/// final links = doc.$('div.a p a'); // Elements (empty if no match, never null)
/// links[0].text();                  // "link"
/// links[0].attr('href');            // "/" (null if absent)
/// links[0].parent()?.text();        // parent Element or null at top level
/// ```
///
/// Public surface is exactly: [Html], [Elements], [Element].
/// - `Html.parse()` parses HTML and returns [Elements].
/// - [Elements] supports `$()` (filter) and `[]` (plus [Iterable] helpers).
/// - [Element] supports only `text()`, `attr()`, `parent()`.
/// Selector support and parsing quirks are whatever the engine does.
/// Everything else is private.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html]. Never throws on malformed markup.
  /// Parsed as a fragment, so top-level elements have no parent
  /// (`parent()` is `null` at top level, like the DOM body would be hidden).
  static Elements parse(String html) {
    final doc = parser.parseFragment(html);
    return Elements._(
      [for (final n in doc.nodes) if (n is dom.Element) Element._(n)],
      doc.querySelectorAll,
    );
  }
}

/// A list of elements. Query with `$()`, read with `[]`.
final class Elements extends Iterable<Element> {
  Elements._(this._items, this._query);

  final List<Element> _items;

  /// Document-level query from the engine (stored as a closure so this
  /// class never depends on the engine's document types).
  final List<dom.Element> Function(String) _query;

  /// Filter: all document-order matches of [selector] that are
  /// the elements themselves or their descendants, deduped.
  Elements $(String selector) {
    final scope = <dom.Element>{for (final e in _items) e._el};
    final out = <Element>[];
    for (final el in _query(selector)) {
      dom.Element? cur = el;
      while (cur != null && !scope.contains(cur)) {
        cur = cur.parent;
      }
      if (cur != null) out.add(Element._(el));
    }
    return Elements._(out, _query);
  }

  /// Element at [index] (throws [RangeError] if out of bounds).
  Element operator [](int index) => _items[index];

  @override
  int get length => _items.length;

  @override
  Iterator<Element> get iterator => _items.iterator;
}

/// A single element. Only `text()`, `attr()`, `parent()`.
final class Element {
  Element._(this._el);

  final dom.Element _el;

  /// Concatenated descendant text.
  String text() => _el.text;

  /// Attribute [name] (case-insensitive) or `null` if absent.
  String? attr(String name) => _el.attributes[name.toLowerCase()];

  /// Parent element, or `null` at top level.
  Element? parent() {
    final p = _el.parent;
    return p == null ? null : Element._(p);
  }
}
