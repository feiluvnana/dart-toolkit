/// Minimal HTML scraping: an in-house HTML5 parser (`src/html_parser.dart`)
/// and CSS selector engine (`src/selector.dart`).
///
/// ```dart
/// final doc = await http.get('https://example.com/article').html();
/// final body = doc.not('script, style, nav').$('article').text();
/// final next = await http.get(url).html().$('a.next').attr('href');
/// ```
///
/// Public surface is exactly: [Html], [Elements], [Element].
/// - `Html.parse()` parses HTML and returns [Elements].
/// - [Elements] supports `$` `[]` `not` `text` `texts` `attr` `attrs`
///   `json` (embedded data) `table` (rows as maps) `form` (fields to post)
///   (plus [Iterable] helpers).
/// - [Element] supports `$` `not` `text` `attr` `parent`.
/// A selector the engine rejects is a [ContentException] naming the selector.
/// Everything else is private.
library;

import 'json.dart';
export 'core.dart';

import 'src/dom.dart' as dom;
import 'src/html_parser.dart' as parser;
import 'src/names.dart' as names;
import 'src/selector.dart' as sel;

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html]. Never throws on bad markup. Input that starts (after
  /// whitespace, comments and an `<?xml …?>` declaration) with `<!doctype`,
  /// `<html`, `<head` or `<body` is a whole document (so `$('body')` works);
  /// anything else is a fragment.
  /// [base] is the base for relative links: with one, URL attributes
  /// (`href`, `src`, `data-src`, `poster`, `action`) are trimmed and made
  /// absolute. The base is parsed once per [Elements] and shared with every
  /// child. A document's
  /// `<base href>` overrides it. A fragment with loose top-level text is
  /// returned as its root, which holds the text and every element (and
  /// matches no selector itself).
  static Elements parse(String html, {String? base}) {
    final baseUri = _parseBase(base);
    var s = html.replaceFirst('﻿', '').trimLeft();
    while (s.startsWith('<!--') || s.startsWith('<?')) {
      final end = s.startsWith('<?') ? s.indexOf('>') : s.indexOf('-->');
      if (end < 0) break;
      s = s.substring(end + (s.startsWith('<?') ? 1 : 3)).trimLeft();
    }
    final head = s.length <= 9 ? s.toLowerCase() : s.substring(0, 9).toLowerCase();
    if (_documentStart.hasMatch(head)) {
      final root = _hold(parser.parseDocument(html));
      final found = <dom.Element>[];
      _baseHref.collect(root, found);
      final declared = found.firstOrNull?.attributes['href']?.trim();
      final base = declared == null || declared.isEmpty ? baseUri : _resolveBase(baseUri, declared) ?? baseUri;
      return Elements._([for (final n in root.children) Element._(n, base)], base);
    }
    final nodes = parser.parseFragment(html);
    final root = _hold(nodes);
    if (nodes.any((n) => n is dom.Text && n.data.trim().isNotEmpty)) {
      // Loose text (`Tom &amp; Jerry`) has no element to live in: the
      // fragment's root holds it, so text() reads it. The root itself never
      // matches a selector, so no element appears that the source lacks.
      return Elements._([Element._(root, baseUri)], baseUri);
    }
    return Elements._([for (final n in root.children) Element._(n, baseUri)], baseUri);
  }
}

/// Detach every node in [found] with one pass per parent (one `remove()`
/// each was O(n²): 50,000 siblings took 8 s).
void _removeAll(List<dom.Element> found) {
  final dead = Set<dom.Node>.identity()..addAll(found);
  final parents = Set<dom.Element>.identity();
  for (final m in found) {
    final p = m.parent;
    if (p != null) parents.add(p);
  }
  for (final p in parents) {
    p.nodes.removeWhere(dead.contains);
    p.edits++;
  }
  for (final m in found) {
    m.parent = null;
  }
}

final _baseHref = sel.Selector.parse('base[href]');
final _documentStart = RegExp(r'^<(!doctype|html|head|body)(?=[\s>/]|$)');

/// The top-level [nodes] under one holder, so they are siblings (for
/// `:first-child`, `+`, `~`) without a parent element.
dom.Element _hold(List<dom.Node> nodes) {
  final root = dom.Element('#root');
  nodes.forEach(root.append);
  return root;
}

/// A document's `<base href>` against [base]; null when it is not a URL
/// (a bad base is ignored, as browsers do: parse never throws).
Uri? _resolveBase(Uri? base, String declared) {
  try {
    return base?.resolve(declared) ?? Uri.parse(declared);
  } on FormatException {
    return null;
  }
}

/// Parse [base] once; null when absent or unparseable.
Uri? _parseBase(String? base) {
  if (base == null || base.isEmpty) return null;
  return Uri.tryParse(base);
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
    return Elements._([
      for (final el in _queryRoots([for (final e in _items) e._el], selector)) Element._(el, _baseUri),
    ], _baseUri);
  }

  /// Element at [index] (throws [RangeError] if out of bounds).
  Element operator [](int index) => _items[index];

  /// A new tree without every match of [selector] and its subtree.
  /// Returns a new tree (one O(n) clone, table parts included); the receiver
  /// is unchanged. A top-level element that matches is dropped whole.
  Elements not(String selector) {
    final group = _parseSelector(selector);
    final out = <Element>[];
    try {
      for (final item in _items) {
        if (group.matches(item._el)) continue;
        final clone = item._el.clone(true);
        final found = <dom.Element>[];
        group.collect(clone, found);
        _removeAll(found);
        out.add(Element._(clone, _baseUri));
      }
    } on FormatException catch (e) {
      throw ContentException("invalid selector '$selector': ${e.message}", e.source, e.offset);
    } on StackOverflowError {
      rethrow; // a document nested too deep, not a bad selector
    } catch (e) {
      throw ContentException("invalid selector '$selector': $e");
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
  /// `attr`/`attrs`.
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

  /// The embedded data in these elements: every `<script>` of type
  /// `application/json` or `application/ld+json`, or with id
  /// `__NEXT_DATA__`, parsed into one [Json] list in document order.
  /// Invalid ones are skipped. `page.json().$('**.user')` searches them all.
  Json json() {
    final out = <Object?>[];
    for (final el in _queryRoots([for (final e in _items) e._el], 'script')) {
      final type = (el.attributes['type'] ?? '').trim().toLowerCase();
      if (type != 'application/json' && type != 'application/ld+json' && el.attributes['id'] != '__NEXT_DATA__') {
        continue;
      }
      try {
        out.add(Json.parse(el.text).value<Object>());
      } on ContentException {
        continue;
      }
    }
    return Json.of(out);
  }

  /// The first table among these elements as rows of `header → cell text`.
  /// The first row (`<th>` or `<td>`) names the columns; a `colspan`
  /// repeats its cell; a nested table belongs to its own cell.
  /// Empty when there is no table.
  List<Map<String, String>> table() {
    final table = _queryRoots([for (final e in _items) e._el], 'table').firstOrNull;
    if (table == null) return const [];
    final rows = <List<String>>[];
    void collect(dom.Element parent) {
      for (final child in parent.children) {
        switch (child.localName) {
          case 'thead' || 'tbody' || 'tfoot':
            collect(child);
          case 'tr':
            final cells = <String>[];
            for (final cell in child.children) {
              if (cell.localName != 'td' && cell.localName != 'th') continue;
              final span = (int.tryParse(cell.attributes['colspan'] ?? '') ?? 1).clamp(1, 1000);
              final text = Element._(cell, _baseUri).text();
              for (var k = 0; k < span; k++) {
                cells.add(text);
              }
            }
            rows.add(cells);
        }
      }
    }

    collect(table);
    if (rows.isEmpty) return const [];
    // The first row names the columns, <th> or not.
    final header = rows.first;
    return [
      for (final row in rows.skip(1)) {for (var k = 0; k < row.length && k < header.length; k++) header[k]: row[k]},
    ];
  }

  /// The first form among these elements, ready to post:
  /// `client.post(f.action, body: .form({...f.fields, 'user': u}))`. The
  /// `action` resolves against the base (the page itself when absent), the
  /// `method` is upper case (`GET` by default), and `fields` holds every named
  /// control's current value, hidden ones included (unchecked boxes, buttons
  /// and file inputs left out). Null when there is no form.
  ({String action, String method, Map<String, String> fields})? form() {
    final form = _queryRoots([for (final e in _items) e._el], 'form').firstOrNull;
    if (form == null) return null;
    final fields = <String, String>{};
    for (final c in _queryRoots([form], 'input, select, textarea')) {
      final name = c.attributes['name'];
      if (name == null || name.isEmpty || c.attributes.containsKey('disabled')) continue;
      switch (c.localName) {
        case 'textarea':
          fields[name] = c.text;
        case 'select':
          final options = _queryRoots([c], 'option');
          final chosen = options.where((o) => o.attributes.containsKey('selected')).firstOrNull ?? options.firstOrNull;
          if (chosen != null) fields[name] = chosen.attributes['value'] ?? Element._(chosen, null).text();
        default:
          final type = (c.attributes['type'] ?? 'text').toLowerCase();
          if (const {'submit', 'button', 'image', 'reset', 'file'}.contains(type)) continue;
          if ((type == 'checkbox' || type == 'radio') && !c.attributes.containsKey('checked')) continue;
          fields[name] = c.attributes['value'] ?? (type == 'checkbox' || type == 'radio' ? 'on' : '');
      }
    }
    final action = Element._(form, _baseUri).attr('action');
    return (
      action: action == null || action.isEmpty ? (_baseUri?.toString() ?? '') : action,
      method: (form.attributes['method'] ?? 'get').trim().toUpperCase(),
      fields: fields,
    );
  }

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
    return Elements._([
      for (final el in _queryRoots([_el], selector)) Element._(el, _baseUri),
    ], _baseUri);
  }

  /// A copy of this element without every match of [selector] and its
  /// subtree. The receiver is unchanged.
  Element not(String selector) {
    final clone = _el.clone(true);
    List<dom.Element> found;
    try {
      final group = _parseSelector(selector);
      found = [];
      if (group.matches(clone)) {
        // Self matches whole (like Elements.without drops it): clear content.
        clone.nodes.clear();
        return Element._(clone, _baseUri);
      }
      group.collect(clone, found);
    } on FormatException catch (e) {
      throw ContentException("invalid selector '$selector': ${e.message}", e.source, e.offset);
    } on StackOverflowError {
      rethrow; // a document nested too deep, not a bad selector
    } catch (e) {
      throw ContentException("invalid selector '$selector': $e");
    }
    _removeAll(found);
    return Element._(clone, _baseUri);
  }

  /// Text like `innerText`, so scraped text needs no `.trim()`. Runs of
  /// spaces collapse to one space, and a run that holds a newline becomes one
  /// newline. Block elements and `<br>` break lines, table cells are space-separated; the result has no
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

    // An explicit stack, not recursion: a page nested 10,000 deep must not
    // overflow the call stack. A null node marks the end of a block.
    void walk(dom.Node root, bool rootPre) {
      final stack = <(dom.Node?, bool)>[(root, rootPre)];
      while (stack.isNotEmpty) {
        final (node, pre) = stack.removeLast();
        if (node == null) {
          if (!pre && out.isNotEmpty) gap(newline: true);
        } else if (node is dom.Text) {
          if (pre) {
            flushGap();
            out.write(node.data);
          } else {
            push(node.data);
          }
        } else if (node is dom.Element) {
          final tag = node.localName;
          if (tag == 'script' || tag == 'style' || tag == 'noscript' || tag == 'template') {
            continue;
          }
          if (tag == 'br') {
            // A line break even with no surrounding text nodes.
            gap(newline: true);
            continue;
          }
          final isBlock = _blocks.contains(tag);
          if (isBlock && !pre && out.isNotEmpty) gap(newline: true);
          if ((tag == 'td' || tag == 'th') && !pre && out.isNotEmpty) gap(newline: false);
          final inner = pre || tag == 'pre';
          if (isBlock) stack.add((null, pre));
          final children = node.nodes;
          for (var i = children.length - 1; i >= 0; i--) {
            stack.add((children[i], inner));
          }
        }
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
    final p = sel.up(_el);
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
final _selectorCache = <String, sel.Selector>{};

/// Parse [selector]; a bad selector is a [ContentException] naming it.
sel.Selector _parseSelector(String selector) {
  final hit = _selectorCache.remove(selector);
  if (hit != null) {
    // Re-insert to mark most-recently-used.
    _selectorCache[selector] = hit;
    return hit;
  }
  final sel.Selector group;
  try {
    group = sel.Selector.parse(selector);
  } on FormatException catch (e) {
    throw ContentException("invalid selector '$selector': ${e.message}", e.source, e.offset, e);
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
/// a combinator and the real tree. A root inside another root is dropped
/// first: the outer walk already covers it (`$('div').$('a')` on nested
/// divs walks the tree once, not once per div).
List<dom.Element> _queryRoots(List<dom.Element> roots, String selector) {
  final group = _parseSelector(selector);
  if (roots.length > 1) {
    final all = roots.toSet();
    bool nested(dom.Element el) {
      for (var p = sel.up(el); p != null; p = sel.up(p)) {
        if (all.contains(p)) return true;
      }
      return false;
    }

    roots = [
      for (final r in roots)
        if (!nested(r)) r,
    ];
  }
  final seen = <dom.Element>{};
  final out = <dom.Element>[];
  void add(dom.Element el) {
    if (seen.add(el)) out.add(el);
  }

  try {
    for (final root in roots) {
      if (group.matches(root)) add(root);
      final found = <dom.Element>[];
      group.collect(root, found);
      for (final el in found) {
        add(el);
      }
    }
  } on FormatException catch (e) {
    throw ContentException("invalid selector '$selector': ${e.message}", e.source, e.offset);
  } on StackOverflowError {
    rethrow; // a document nested too deep, not a bad selector
  } catch (e) {
    throw ContentException("invalid selector '$selector': $e");
  }
  return out;
}

/// Bytes → a value. Relative links resolve against the response's URL
/// (or the file's URI) from the typed [Origin]; other readers parse without
/// a base. A failure on an error page names the HTTP status in the message.
extension ReaderHtml on Reader {
  Future<Elements> html() async {
    final text = await this.text();
    final o = origin();
    try {
      return Html.parse(
        text,
        base: names.baseUrlFor(url: o.url(), path: o.path()),
      );
    } on FormatException catch (e) {
      final status = o.status();
      if (status == null || (status >= 200 && status < 300)) rethrow;
      throw ContentException('${e.message} (HTTP $status)', e.source, e.offset, e);
    }
  }
}

/// Same, from an async reader.
extension ReaderFutureHtml on Future<Reader> {
  Future<Elements> html() async => (await this).html();
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension ElementsFuture on Future<Elements> {
  Future<Elements> $(String selector) async => (await this).$(selector);
  Future<Element> operator [](int index) async => (await this)[index];
  Future<Elements> not(String selector) async => (await this).not(selector);
  Future<String> text() async => (await this).text();
  Future<List<String>> texts() async => (await this).texts();
  Future<String?> attr(String name) async => (await this).attr(name);
  Future<List<String>> attrs(String name) async => (await this).attrs(name);
  Future<Json> json() async => (await this).json();
  Future<List<Map<String, String>>> table() async => (await this).table();
  Future<({String action, String method, Map<String, String> fields})?> form() async => (await this).form();
}

/// Future mirrors for [Element].
extension ElementFuture on Future<Element> {
  Future<Elements> $(String selector) async => (await this).$(selector);
  Future<Element> not(String selector) async => (await this).not(selector);
  Future<String> text() async => (await this).text();
  Future<String?> attr(String name) async => (await this).attr(name);
  Future<Element?> parent() async => (await this).parent();
}
