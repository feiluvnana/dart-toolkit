/// Minimal HTML scraping. Thin facade over `package:html`.
///
/// ```dart
/// final doc = await Http.get('https://example.com/article').html();
/// final body = doc.without('script, style, nav').$('article').text();
/// final next = await Http.get(url).html().$('a.next')[0].attr('href');
/// ```
///
/// Public surface is exactly: [Html], [Elements], [Element].
/// - `Html.parse()` parses HTML and returns [Elements].
/// - [Elements] supports `$` `[]` `without` `text` `texts` `attr` `attrs`
///   (plus [Iterable] helpers).
/// - [Element] supports `$` `without` `text` `attr` `parent`.
/// A selector the engine rejects is a [FormatException] naming the selector.
/// Everything else is private.
library;

import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as css;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
// `query_selector.dart` is engine-internal: package:html offers no public
// `matches`, so `$` cannot test the element itself without it. The import is
// private (nothing is re-exported) and holds no public surface. Pinned to
// `html >=0.15.7 <0.16.0` (see pubspec.yaml) so a minor bump cannot break it;
// `matches` on a root element is covered in tests (self-matching groups).
// ignore: implementation_imports
import 'package:html/src/query_selector.dart' as query;

import 'core.dart';
export 'core.dart';

import 'src/origin.dart' as names;

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html]. Never throws on bad markup. Input that starts (after
  /// whitespace) with `<!doctype` or `<html` is a whole document (so
  /// `$('body')` works); anything else is a fragment.
  /// [baseUrl] is the base for relative links: with one, URL attributes
  /// (`href`, `src`, `data-src`, `poster`, `action`) are trimmed and made
  /// absolute. The base is parsed once per [Elements] and shared with every
  /// child (1000 links no longer parse it 1000 times).
  static Elements parse(String html, {String? baseUrl}) {
    final baseUri = _parseBase(baseUrl);
    var s = html.replaceFirst('﻿', '').trimLeft();
    while (s.startsWith('<!--')) {
      final end = s.indexOf('-->');
      if (end < 0) break;
      s = s.substring(end + 3).trimLeft();
    }
    final head = s.length <= 9 ? s.toLowerCase() : s.substring(0, 9).toLowerCase();
    if (head.startsWith('<!doctype') || head.startsWith('<html')) {
      final doc = parser.parse(html);
      return Elements._(
        [for (final n in doc.nodes) if (n is dom.Element) Element._(n, baseUri)],
        baseUri,
      );
    }
    final frag = parser.parseFragment(html);
    return Elements._(
      [for (final n in frag.nodes) if (n is dom.Element) Element._(n, baseUri)],
      baseUri,
    );
  }
}

/// Parse [baseUrl] once; null when absent or unparseable.
Uri? _parseBase(String? baseUrl) {
  if (baseUrl == null || baseUrl.isEmpty) return null;
  return Uri.tryParse(baseUrl);
}

/// A list of elements. Query with `$()`, read with `[]`.
final class Elements extends Iterable<Element> {
  Elements._(this._items, this._baseUri);

  final List<Element> _items;

  /// The base for relative links, parsed once and shared with every child.
  final Uri? _baseUri;

  /// Matches in document order without duplicates: every element that is one
  /// of these elements or a descendant of one. The element itself is matched
  /// with the engine's `matches`, so combinators see the real tree.
  /// Selectors are parsed once and cached (64-entry LRU keyed by the
  /// selector string): scrapes running the same selectors per page are O(1).
  Elements $(String selector) {
    return Elements._(
      [
        for (final el in _queryRoots(
          [for (final e in _items) e._el],
          selector,
        ))
          Element._(el, _baseUri),
      ],
      _baseUri,
    );
  }

  /// Element at [index] (throws [RangeError] if out of bounds).
  Element operator [](int index) => _items[index];

  /// A new tree without every match of [selector] and its subtree.
  /// Returns a new tree (one O(n) clone, table parts included); the receiver
  /// is unchanged. A top-level element that matches is dropped whole.
  Elements without(String selector) {
    final group = _parseSelector(selector);
    final evaluator = query.SelectorEvaluator();
    final out = <Element>[];
    try {
      for (final item in _items) {
        if (evaluator.matches(item._el, group)) continue;
        final clone = item._el.clone(true);
        final found = <dom.Element>[];
        evaluator.querySelectorAll(clone, group, found);
        for (final m in found) {
          m.remove();
        }
        out.add(Element._(clone, _baseUri));
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
    return Elements._(out, _baseUri);
  }

  /// Reads the **first** match (`''` when there is none), like [attr]; for
  /// every match use [texts].
  /// Reads like `innerText`, so scraped text needs no `.trim()`.
  String text() {
    final first = _items.firstOrNull;
    if (first == null) return '';
    return first.text();
  }

  /// Every match's text in document order. Pairs `text`/`texts` like
  /// `attr`/`attrs`; replaces `.map((e) => e.text()).toList()`.
  List<String> texts() => [for (final e in _items) e.text()];

  /// The first match's attribute, or `null` when nothing matched or the
  /// attribute is absent. Case-insensitive; `href`/`src` resolve with the base.
  String? attr(String name) {
    final first = _items.firstOrNull;
    return first?.attr(name);
  }

  /// Every match's value of [name] in document order, absent ones skipped.
  /// Links resolve against the base, so `$('a.item').attrs('href')` is the
  /// list of links to follow.
  List<String> attrs(String name) => [for (final e in _items) ?e.attr(name)];

  @override
  int get length => _items.length;

  @override
  Iterator<Element> get iterator => _items.iterator;
}

/// A single element.
final class Element {
  Element._(this._el, this._baseUri);

  final dom.Element _el;

  /// The base for relative links, shared from the parent [Elements].
  final Uri? _baseUri;

  /// Matches that are this element or a descendant of it, in document order
  /// without duplicates. The element itself is matched with the engine's
  /// `matches`, so combinators see the real tree.
  Elements $(String selector) {
    return Elements._(
      [for (final el in _queryRoots([_el], selector)) Element._(el, _baseUri)],
      _baseUri,
    );
  }

  /// A copy of this element without every match of [selector] and its
  /// subtree. The receiver is unchanged.
  Element without(String selector) {
    final clone = _el.clone(true);
    List<dom.Element> found;
    try {
      final group = _parseSelector(selector);
      final evaluator = query.SelectorEvaluator();
      found = [];
      if (evaluator.matches(clone, group)) {
        // Self matches whole (like Elements.without drops it): clear content.
        clone.nodes.clear();
        return Element._(clone, _baseUri);
      }
      evaluator.querySelectorAll(clone, group, found);
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
    return Element._(clone, _baseUri);
  }

  /// Text like `innerText`, so scraped text needs no `.trim()`. Runs of
  /// spaces collapse to one space, and a run that holds a newline becomes one
  /// newline. Block elements and `<br>` break lines; the result has no
  /// leading/trailing collapsed whitespace, and `<pre>` keeps its whitespace.
  String text() {
    final out = StringBuffer();
    var gaps = 0;
    var gapNewline = false;
    void flushGap() {
      if (gaps > 0) {
        // Drop leading collapsed whitespace; keep a single space/newline
        // between content.
        if (out.isNotEmpty) out.write(gapNewline ? '\n' : ' ');
        gaps = 0;
        gapNewline = false;
      }
    }

    void gap({required bool newline}) {
      gaps++;
      if (newline) gapNewline = true;
    }

    void push(String s) {
      for (var i = 0; i < s.length; i++) {
        final c = s.codeUnitAt(i);
        if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D) {
          gaps++;
          if (c == 0x0A || c == 0x0D) gapNewline = true;
        } else {
          flushGap();
          out.writeCharCode(c);
        }
      }
    }

    void walk(dom.Node node, bool pre) {
      if (node is dom.Text) {
        if (pre) {
          flushGap();
          out.write(node.data);
        } else {
          push(node.data);
        }
      } else if (node is dom.Element) {
        final tag = node.localName;
        if (tag == 'script' || tag == 'style' || tag == 'noscript' || tag == 'template') {
          return;
        }
        if (tag == 'br') {
          // A line break even with no surrounding text nodes.
          gap(newline: true);
          return;
        }
        final isBlock = tag != null && _blocks.contains(tag);
        if (isBlock && !pre && out.isNotEmpty) gap(newline: true);
        final inner = pre || tag == 'pre';
        for (final child in node.nodes) {
          walk(child, inner);
        }
        if (isBlock && !pre && out.isNotEmpty) gap(newline: true);
      }
    }

    walk(_el, _el.localName == 'pre');
    // Drop trailing collapsed whitespace; pre's own trailing spaces stay.
    return out.toString();
  }

  /// Attribute [name] (case-insensitive) or `null` if absent. URL attributes
  /// (`href`, `src`, `data-src`, `poster`, `action`) are trimmed and, with a
  /// base URL, resolved to absolute URLs (the base was parsed once per
  /// [Elements], not per attribute).
  String? attr(String name) {
    final raw = _el.attributes[name.toLowerCase()];
    if (raw == null) return null;
    if (!_urlAttrs.contains(name.toLowerCase())) return raw;
    final value = raw.trim();
    final base = _baseUri;
    if (base == null || value.isEmpty) return value;
    try {
      return base.resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  /// Parent element, or `null` at top level.
  Element? parent() {
    final p = _el.parent;
    return p == null ? null : Element._(p, _baseUri);
  }
}

/// URL attributes: trimmed and resolved against the base.
const _urlAttrs = {'href', 'src', 'data-src', 'poster', 'action'};

/// Elements that break lines in `text()` (like `innerText`).
const _blocks = {
  'address',
  'article',
  'aside',
  'blockquote',
  'details',
  'dialog',
  'div',
  'dl',
  'dd',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tbody',
  'thead',
  'tfoot',
  'tr',
  'ul',
};

/// Parsed selectors, keyed by the selector string. Scrapes run the same
/// handful of selectors on every page, so repeats are O(1). Bounded at 64
/// entries (LRU: a hit moves to the end, a miss evicts the oldest).
final _selectorCache = <String, css.SelectorGroup>{};

/// Parse [selector] with the engine's parser; a bad selector is a
/// [FormatException] naming it.
css.SelectorGroup _parseSelector(String selector) {
  final hit = _selectorCache.remove(selector);
  if (hit != null) {
    // Re-insert to mark most-recently-used.
    _selectorCache[selector] = hit;
    return hit;
  }
  final errors = <css.Message>[];
  final group = css.parseSelectorGroup(selector, errors: errors);
  if (group == null || errors.isNotEmpty) {
    throw FormatException("invalid selector '$selector': $errors");
  }
  _selectorCache[selector] = group;
  if (_selectorCache.length > 64) {
    _selectorCache.remove(_selectorCache.keys.first);
  }
  return group;
}

/// One query path for [Element.$] and [Elements.$]: every root that matches
/// plus every matching descendant, in document order without duplicates.
/// Roots match through the engine's `matches`, so no wrapper stands between
/// a combinator and the real tree.
List<dom.Element> _queryRoots(List<dom.Element> roots, String selector) {
  final group = _parseSelector(selector);
  final evaluator = query.SelectorEvaluator();
  final seen = <dom.Element>{};
  final out = <dom.Element>[];
  void add(dom.Element el) {
    if (seen.add(el)) out.add(el);
  }

  try {
    for (final root in roots) {
      if (evaluator.matches(root, group)) add(root);
      final found = <dom.Element>[];
      evaluator.querySelectorAll(root, group, found);
      for (final el in found) {
        add(el);
      }
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
  return out;
}

/// Bytes → a value. Relative links resolve against the response's URL
/// (or the file's URI) from the typed [Origin]; other readers parse without
/// a base. A failure on an error page names the HTTP status in the message.
extension ReaderHtml on Reader {
  Future<Elements> html() async {
    final o = origin();
    final text = await this.text();
    try {
      return Html.parse(
        text,
        baseUrl: names.baseUrlFor(url: o.url, path: o.path),
      );
    } on FormatException catch (e) {
      final status = o.status;
      if (status == null || (status >= 200 && status < 300)) rethrow;
      throw FormatException('${e.message} (HTTP $status)', e.source, e.offset);
    }
  }
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
  Future<List<String>> texts() async => (await this).texts();
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
