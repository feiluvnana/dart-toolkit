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
/// - [Elements] supports `$` `[]` `without` `text` `attr` `attrs` (plus [Iterable] helpers).
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
// private (nothing is re-exported) and holds no public surface.
// ignore: implementation_imports
import 'package:html/src/query_selector.dart' as query;

import 'core.dart';
export 'core.dart';

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html]. Never throws on bad markup. Input that starts (after
  /// whitespace) with `<!doctype` or `<html` is a whole document (so
  /// `$('body')` works); anything else is a fragment.
  /// [baseUrl] is the base for relative links: with one, URL attributes
  /// (`href`, `src`, `data-src`, `poster`, `action`) are trimmed and made
  /// absolute.
  static Elements parse(String html, {String? baseUrl}) {
    var s = html.replaceFirst('\uFEFF', '').trimLeft();
    while (s.startsWith('<!--')) {
      final end = s.indexOf('-->');
      if (end < 0) break;
      s = s.substring(end + 3).trimLeft();
    }
    final head = s.length <= 9 ? s.toLowerCase() : s.substring(0, 9).toLowerCase();
    if (head.startsWith('<!doctype') || head.startsWith('<html')) {
      final doc = parser.parse(html);
      return Elements._(
        [for (final n in doc.nodes) if (n is dom.Element) Element._(n, baseUrl)],
        baseUrl,
      );
    }
    final frag = parser.parseFragment(html);
    return Elements._(
      [for (final n in frag.nodes) if (n is dom.Element) Element._(n, baseUrl)],
      baseUrl,
    );
  }
}

/// A list of elements. Query with `$()`, read with `[]`.
final class Elements extends Iterable<Element> {
  Elements._(this._items, this._baseUrl);

  final List<Element> _items;
  final String? _baseUrl;

  /// Matches in document order without duplicates: every element that is one
  /// of these elements or a descendant of one. The element itself is matched
  /// with the engine's `matches`, so combinators see the real tree.
  Elements $(String selector) {
    return Elements._(
      [
        for (final el in _queryRoots(
          [for (final e in _items) e._el],
          selector,
        ))
          Element._(el, _baseUrl),
      ],
      _baseUrl,
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
        out.add(Element._(clone, _baseUrl));
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
    return Elements._(out, _baseUrl);
  }

  /// Reads the **first** match (`''` when there is none), like [attr]; for
  /// every match use `.map((e) => e.text())`.
  /// Reads like `innerText`, so scraped text needs no `.trim()`.
  String text() {
    final first = _items.firstOrNull;
    if (first == null) return '';
    return first.text();
  }

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
  Element._(this._el, this._baseUrl);

  final dom.Element _el;
  final String? _baseUrl;

  /// Matches that are this element or a descendant of it, in document order
  /// without duplicates. The element itself is matched with the engine's
  /// `matches`, so combinators see the real tree.
  Elements $(String selector) {
    return Elements._(
      [for (final el in _queryRoots([_el], selector)) Element._(el, _baseUrl)],
      _baseUrl,
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
        return Element._(clone, _baseUrl);
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
    return Element._(clone, _baseUrl);
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
  /// base URL, resolved to absolute URLs.
  String? attr(String name) {
    final raw = _el.attributes[name.toLowerCase()];
    if (raw == null) return null;
    if (!_urlAttrs.contains(name.toLowerCase())) return raw;
    final value = raw.trim();
    final base = _baseUrl;
    if (base == null || value.isEmpty) return value;
    try {
      return Uri.parse(base).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  /// Parent element, or `null` at top level.
  Element? parent() {
    final p = _el.parent;
    return p == null ? null : Element._(p, _baseUrl);
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

/// Parse [selector] with the engine's parser; a bad selector is a
/// [FormatException] naming it.
css.SelectorGroup _parseSelector(String selector) {
  final errors = <css.Message>[];
  final group = css.parseSelectorGroup(selector, errors: errors);
  if (group == null || errors.isNotEmpty) {
    throw FormatException("invalid selector '$selector': $errors");
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
/// (or the file's URI); other readers parse without a base. A failure on
/// an error page names the HTTP status in the message.
extension ReaderHtml on Reader {
  Future<Elements> html() async {
    final text = await this.text();
    try {
      return Html.parse(text, baseUrl: _baseUrlOf(this));
    } on FormatException catch (e) {
      final status = _statusOf(this);
      if (status == null || (status >= 200 && status < 300)) rethrow;
      throw FormatException('${e.message} (HTTP $status)', e.source, e.offset);
    }
  }
}

int? _statusOf(Reader reader) {
  try {
    // ignore: avoid_dynamic_calls
    final s = (reader as dynamic).status() as int?;
    return s;
  } catch (_) {
    return null;
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
