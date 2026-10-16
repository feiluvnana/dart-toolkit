/// Minimal HTML scraping: an in-house HTML5 parser (`src/html_parser.dart`)
/// and CSS selector engine (`src/selector.dart`).
///
/// ```dart
/// final doc = await http.get('https://example.com/article').html();
/// final body = doc.not('script, style, nav').$('article').text();
/// final next = await http.get(url).html().$('a.next').attr('href');
/// ```
///
/// Public surface is exactly: [Html], [Elements], [Element] (and
/// everything `json` exports, since `json()` returns a [Json]).
/// - `Html.parse()` parses HTML and returns [Elements]; `Reader.html()`
///   parses a body (`http.get(u).html()`), its URL the base.
/// - [Elements] supports `$` `[]` `not` `text` `texts` `markup` `attr` `attrs`
///   `json` (embedded data) `table` (rows as maps) `form` (fields to post)
///   (plus [Iterable] helpers).
/// - [Element] supports `$` `text` `markup` `attr` `parent`.
/// `html()` always parses (a reader, a page); `markup()` writes HTML back out.
/// A selector the engine rejects is a [ContentException] naming the selector.
/// Everything else is private.
library;

import 'json.dart';
export 'core.dart';
// The json names by `show`: a bare `export 'json.dart'` re-exports core
// through json, which costs startup.
export 'json.dart' show Json, JsonFuture, ReaderJson, ReaderFutureJson;

import 'src/dom.dart' as dom;
import 'src/html_parser.dart' as parser;
import 'src/selector.dart' as sel;

/// Entry point: parse HTML source into top-level [Elements].
abstract final class Html {
  /// Parse [html]. Never throws on bad markup. Input that starts (after
  /// whitespace, comments and an `<?xml …?>` declaration) with `<!doctype`,
  /// `<html`, `<head` or `<body` is a whole document (so `$('body')` works);
  /// anything else is a fragment.
  /// [base] is the document's URL and the base for relative links: with
  /// one, URL attributes (see [Element.attr]) are trimmed and made
  /// absolute. The base is parsed once per [Elements] and shared with every
  /// child. A document's `<base href>` overrides it for links (a form
  /// without an `action` still posts to [base]). A fragment with loose
  /// top-level text is returned as its root, which holds the text and every
  /// element (and matches no selector itself).
  static Elements parse(String html, {String? base}) {
    final baseUri = _parseBase(base);
    final doc = _Ctx(baseUri, baseUri);
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
      final ctx = declared == null || declared.isEmpty
          ? doc
          : _Ctx(_resolveBase(baseUri, declared) ?? baseUri, baseUri);
      return Elements._([for (final n in root.children) Element._(n, ctx)], ctx);
    }
    final nodes = parser.parseFragment(html);
    final root = _hold(nodes);
    if (nodes.any((n) => n is dom.Text && n.data.trim().isNotEmpty)) {
      // Loose text (`Tom &amp; Jerry`) has no element to live in: the
      // fragment's root holds it, so text() reads it. The root itself never
      // matches a selector, so no element appears that the source lacks.
      return Elements._([Element._(root, doc)], doc);
    }
    return Elements._([for (final n in root.children) Element._(n, doc)], doc);
  }
}

/// What every element of one parse shares: the base for links (after
/// `<base href>`) and the document's own URL.
final class _Ctx {
  const _Ctx(this.base, this.doc);

  final Uri? base;
  final Uri? doc;
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
    dom.touch(p);
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
  Elements._(this._items, this._ctx);

  final List<Element> _items;

  /// The base for links and the document URL, shared with every child.
  final _Ctx _ctx;

  /// Matches in document order without duplicates: every element that is one
  /// of these elements or a descendant of one. The element itself is matched
  /// with the engine's `matches`, so combinators see the real tree.
  /// `:scope` is any of these elements, and a selector may start with a
  /// combinator relative to them: `list.$('> li')` is the direct items,
  /// `headings.$('+ p')` the paragraph after each.
  /// Selectors are parsed once and cached (64-entry LRU keyed by the
  /// selector string): scrapes running the same selectors per page are O(1).
  Elements $(String selector) {
    return Elements._([
      for (final el in _queryRoots([for (final e in _items) e._el], selector)) Element._(el, _ctx),
    ], _ctx);
  }

  /// Element at [index] (throws [RangeError] if out of bounds).
  Element operator [](int index) => _items[index];

  /// A new tree without every match of [selector] and its subtree.
  /// Returns a new tree (one O(n) clone, table parts included); the receiver
  /// is unchanged. A top-level element that matches is dropped whole.
  Elements not(String selector) {
    final group = _parseSelector(selector);
    final out = <Element>[];
    for (final item in _items) {
      if (group.matches(item._el, scope: {item._el})) continue;
      final clone = item._el.clone(true);
      final found = <dom.Element>[];
      group.collect(clone, found, scope: {clone});
      _removeAll(found);
      out.add(Element._(clone, _ctx));
    }
    return Elements._(out, _ctx);
  }

  /// Reads the **first** match (`''` when there is none), like [attr]; for
  /// every match use [texts].
  /// Reads like `innerText`, so scraped text needs no `.trim()`.
  String text() => _items.firstOrNull?.text() ?? '';

  /// Every match's text in document order. Pairs `text`/`texts` like
  /// `attr`/`attrs`.
  List<String> texts() => [for (final e in _items) e.text()];

  /// The first match's markup, itself included (`''` when there is none);
  /// see [Element.markup].
  String markup() => _items.firstOrNull?.markup() ?? '';

  /// The first match's attribute, or `null` when nothing matched or the
  /// attribute is absent. Case-insensitive; links resolve with the base (see
  /// [Element.attr]).
  String? attr(String name) => _items.firstOrNull?.attr(name);

  /// Every match's value of [name] in document order, absent ones skipped.
  /// Links resolve against the base, so `$('a.item').attrs('href')` is the
  /// list of links to follow.
  List<String> attrs(String name) => [for (final e in _items) ?e.attr(name)];

  /// The embedded data in these elements: every `<script>` of type
  /// `application/json` or `application/ld+json` (parameters such as
  /// `; charset=utf-8` allowed), or with id `__NEXT_DATA__`, parsed into one
  /// [Json] list in document order. Invalid ones are skipped.
  /// `page.json().$('**.user')` searches them all.
  Json json() {
    final out = <Object?>[];
    for (final el in _queryRoots([for (final e in _items) e._el], 'script')) {
      final type = (el.attributes['type'] ?? '').split(';').first.trim().toLowerCase();
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
  /// repeats its cell across columns and a `rowspan` down the rows below; a
  /// nested table belongs to its own cell. Empty when there is no table.
  List<Map<String, String>> table() {
    final table = _queryRoots([for (final e in _items) e._el], 'table').firstOrNull;
    if (table == null) return const [];
    final rows = <List<String>>[];
    // Cells a rowspan carries into later rows: column → (text, rows left).
    final carried = <int, (String, int)>{};
    void collect(dom.Element parent) {
      for (final child in parent.children) {
        switch (child.localName) {
          case 'thead' || 'tbody' || 'tfoot':
            collect(child);
          case 'tr':
            final cells = <String>[];
            void fill() {
              while (true) {
                final c = carried[cells.length];
                if (c == null) return;
                final (text, left) = c;
                cells.add(text);
                if (left <= 1) {
                  carried.remove(cells.length - 1);
                } else {
                  carried[cells.length - 1] = (text, left - 1);
                }
              }
            }

            for (final cell in child.children) {
              if (cell.localName != 'td' && cell.localName != 'th') continue;
              fill();
              final span = (int.tryParse(cell.attributes['colspan'] ?? '') ?? 1).clamp(1, 1000);
              var down = (int.tryParse(cell.attributes['rowspan'] ?? '') ?? 1).clamp(0, 65534);
              if (down == 0) down = 65534; // rowspan=0: to the end of the table
              final text = Element._(cell, _ctx).text();
              for (var k = 0; k < span; k++) {
                if (down > 1) carried[cells.length] = (text, down - 1);
                cells.add(text);
              }
            }
            fill();
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
  /// `action` resolves against the base, and an empty or absent one is the
  /// document's own URL (not `<base href>`); the `method` is upper case
  /// (`GET` by default). `fields` maps every named control the form owns
  /// (as a browser: inside it, after it in a table, or `form="id"`) to its
  /// current values in document order, hidden ones included: a repeated name or a
  /// `<select multiple>` keeps every value, and unchecked boxes, buttons
  /// and file inputs are left out. Null when there is no form.
  ({String action, String method, Map<String, List<String>> fields})? form() {
    final form = _queryRoots([for (final e in _items) e._el], 'form').firstOrNull;
    if (form == null) return null;
    final fields = <String, List<String>>{};
    void add(String name, String value) => (fields[name] ??= []).add(value);
    // The form's controls by owner, as a browser posts them: the ones the
    // parser gave it (a form in a table holds none), descendants, and
    // `form="id"` ones anywhere in the document.
    final id = form.attributes['id'];
    bool inside(dom.Element c) {
      for (var p = c.parent; p != null; p = p.parent) {
        if (identical(p, form)) return true;
      }
      return false;
    }

    bool owned(dom.Element c) => switch (c.attributes['form']) {
      final ref? => id != null && id.isNotEmpty && ref == id,
      _ => switch (dom.formOwner[c]) {
        final owner? => identical(owner, form),
        null => inside(c),
      },
    };
    var top = form;
    while (top.parent != null) {
      top = top.parent!;
    }
    for (final c in _queryRoots([top], 'input, select, textarea')) {
      if (!owned(c)) continue;
      final name = c.attributes['name'];
      if (name == null || name.isEmpty || c.attributes.containsKey('disabled')) continue;
      switch (c.localName) {
        case 'textarea':
          add(name, c.text);
        case 'select':
          final options = [
            for (final o in _queryRoots([c], 'option'))
              if (!o.attributes.containsKey('disabled')) o,
          ];
          final selected = options.where((o) => o.attributes.containsKey('selected')).toList();
          final chosen = c.attributes.containsKey('multiple')
              ? selected
              : [?(selected.lastOrNull ?? options.firstOrNull)];
          for (final o in chosen) {
            add(name, o.attributes['value'] ?? Element._(o, _ctx).text());
          }
        default:
          final type = (c.attributes['type'] ?? 'text').toLowerCase();
          if (const {'submit', 'button', 'image', 'reset', 'file'}.contains(type)) continue;
          if ((type == 'checkbox' || type == 'radio') && !c.attributes.containsKey('checked')) continue;
          add(name, c.attributes['value'] ?? (type == 'checkbox' || type == 'radio' ? 'on' : ''));
      }
    }
    final action = Element._(form, _ctx).attr('action');
    return (
      action: action == null || action.isEmpty ? (_ctx.doc?.toString() ?? '') : action,
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
  Element._(this._el, this._ctx);

  final dom.Element _el;

  /// The base for links and the document URL, shared from the parent
  /// [Elements].
  final _Ctx _ctx;

  /// Matches that are this element or a descendant of it, in document order
  /// without duplicates. The element itself is matched with the engine's
  /// `matches`, so combinators see the real tree. `:scope` is this element,
  /// and a leading combinator is relative to it: `ul.$('> li')`, and
  /// `h2.$('+ p')` / `$('~ p')` reach its later siblings.
  Elements $(String selector) {
    return Elements._([
      for (final el in _queryRoots([_el], selector)) Element._(el, _ctx),
    ], _ctx);
  }

  /// The element's markup, itself included (`outerHTML`): attributes in
  /// source order, text escaped, raw text (`script`, `style`) as it is, void
  /// elements without an end tag.
  String markup() => _serialize(_el);

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

  /// Attribute [name] (case-insensitive) or `null` if absent. With a base
  /// URL, links come back absolute: the URL attributes (`href`, `src`,
  /// `data-src`, `poster`, `action`) are trimmed and resolved, every
  /// candidate of a `srcset`/`data-srcset` is resolved (descriptors kept),
  /// and a `<meta>` `content` that is a path (`/`, `./`, `../`) is resolved,
  /// so `page.$('meta[property="og:image"]').attr('content')` is a URL to
  /// fetch. Other values are as written.
  String? attr(String name) {
    final key = name.toLowerCase();
    final raw = _el.attributes[key];
    if (raw == null) return null;
    final base = _ctx.base;
    if (_urlAttrs.contains(key)) return _resolve(base, raw.trim());
    if (key == 'srcset' || key == 'data-srcset') return base == null ? raw.trim() : _srcset(base, raw);
    if (key == 'content' && base != null && _el.localName == 'meta') {
      final v = raw.trim();
      if (v.startsWith('/') || v.startsWith('./') || v.startsWith('../')) return _resolve(base, v);
    }
    return raw;
  }

  /// Parent element, or `null` at top level.
  Element? parent() {
    final p = sel.up(_el);
    return p == null ? null : Element._(p, _ctx);
  }
}

/// URL attributes: trimmed and resolved against the base.
const _urlAttrs = {'href', 'src', 'data-src', 'poster', 'action'};

/// [value] against [base]; as it is without a base or when it is not a URL.
String _resolve(Uri? base, String value) {
  if (base == null || value.isEmpty) return value;
  try {
    return base.resolve(value).toString();
  } on FormatException {
    return value;
  }
}

/// A `srcset` with every candidate URL resolved against [base]: candidates
/// are split as the HTML standard does (a URL runs to whitespace, a comma
/// ends a candidate outside parentheses) and rejoined with `, `.
String _srcset(Uri base, String v) {
  bool space(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;
  final out = <String>[];
  var i = 0;
  while (i < v.length) {
    while (i < v.length && (space(v.codeUnitAt(i)) || v.codeUnitAt(i) == 0x2C)) {
      i++;
    }
    if (i >= v.length) break;
    final start = i;
    while (i < v.length && !space(v.codeUnitAt(i))) {
      i++;
    }
    var url = v.substring(start, i);
    var desc = '';
    if (url.endsWith(',')) {
      url = url.replaceFirst(RegExp(r',+$'), '');
    } else {
      final from = i;
      var depth = 0;
      while (i < v.length) {
        final c = v.codeUnitAt(i);
        if (c == 0x28) depth++;
        if (c == 0x29 && depth > 0) depth--;
        if (c == 0x2C && depth == 0) break;
        i++;
      }
      desc = v.substring(from, i).trim();
    }
    final abs = _resolve(base, url);
    out.add(desc.isEmpty ? abs : '$abs $desc');
  }
  return out.join(', ');
}

/// Void elements: no end tag, no content.
const _void = {
  'area', 'base', 'basefont', 'bgsound', 'br', 'col', 'embed', 'frame', 'hr', 'img', 'input', 'keygen', //
  'link', 'meta', 'param', 'source', 'track', 'wbr',
};

/// Elements whose text serializes unescaped (scripting is on, so
/// `noscript` too).
const _rawText = {'style', 'script', 'xmp', 'iframe', 'noembed', 'noframes', 'plaintext', 'noscript'};

/// [root] as HTML (the "serializing HTML fragments" algorithm, root
/// included); the holder of loose top-level nodes writes its content only.
/// An explicit stack: a page nested 10,000 deep must not overflow.
String _serialize(dom.Element root) {
  final out = StringBuffer();
  // A String is an end tag to write; a node is content.
  final stack = <Object>[root];
  while (stack.isNotEmpty) {
    final item = stack.removeLast();
    switch (item) {
      case String():
        out.write(item);
      case dom.Text():
        final p = item.parent;
        final raw = p != null && p.space == dom.Space.html && _rawText.contains(p.localName);
        out.write(raw ? item.data : _escape(item.data, attribute: false));
      case dom.Element():
        final holder = item.localName == '#root';
        if (!holder) {
          out
            ..write('<')
            ..write(item.localName);
          for (final MapEntry(:key, :value) in item.attributes.entries) {
            out
              ..write(' ')
              ..write(key)
              ..write('="')
              ..write(_escape(value, attribute: true))
              ..write('"');
          }
          out.write('>');
          if (item.space == dom.Space.html && _void.contains(item.localName)) continue;
          stack.add('</${item.localName}>');
        }
        for (var i = item.nodes.length - 1; i >= 0; i--) {
          stack.add(item.nodes[i]);
        }
    }
  }
  return out.toString();
}

/// HTML's escaping: `&` and no-break space always, then `"` in an
/// attribute or `<` `>` in text.
String _escape(String s, {required bool attribute}) {
  var plain = true;
  for (var i = 0; i < s.length && plain; i++) {
    final c = s.codeUnitAt(i);
    plain = c != 0x26 && c != 0xA0 && (attribute ? c != 0x22 : c != 0x3C && c != 0x3E);
  }
  if (plain) return s;
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    out.write(switch (c) {
      0x26 => '&amp;',
      0xA0 => '&nbsp;',
      0x22 when attribute => '&quot;',
      0x3C when !attribute => '&lt;',
      0x3E when !attribute => '&gt;',
      _ => String.fromCharCode(c),
    });
  }
  return out.toString();
}

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
/// a combinator and the real tree; every root is in `:scope`. A root inside
/// another root is dropped from the walk: the outer walk already covers it
/// (`$('div').$('a')` on nested divs walks the tree once, not once per div).
List<dom.Element> _queryRoots(List<dom.Element> roots, String selector) {
  final group = _parseSelector(selector);
  final scope = Set<dom.Element>.identity()..addAll(roots);
  if (roots.length > 1) {
    bool nested(dom.Element el) {
      for (var p = sel.up(el); p != null; p = sel.up(p)) {
        if (scope.contains(p)) return true;
      }
      return false;
    }

    roots = [
      for (final r in roots)
        if (!nested(r)) r,
    ];
  }
  final seen = Set<dom.Element>.identity();
  final out = <dom.Element>[];
  void walk(dom.Element root) {
    if (group.matches(root, scope: scope) && seen.add(root)) out.add(root);
    final found = <dom.Element>[];
    group.collect(root, found, scope: scope);
    for (final el in found) {
      if (seen.add(el)) out.add(el);
    }
  }

  // `+ p` / `~ p` match beside a root: its later siblings are walked too,
  // each once (a walked sibling's later ones were walked with it).
  final beside = Set<dom.Element>.identity();
  for (final root in roots) {
    if (!beside.contains(root)) walk(root);
    if (!group.sideways) continue;
    final (siblings, at) = sel.position(root);
    for (var k = at + 1; k < siblings.length && beside.add(siblings[k]); k++) {
      walk(siblings[k]);
    }
  }
  return out;
}

/// The base for `html()`: the final URL when present, else the file path
/// as a `file:` URI.
String? _baseFor(Origin o) {
  final url = o.url(), path = o.path();
  if (url != null && url.isNotEmpty) return url;
  if (path == null) return null;
  try {
    return Uri.file(path).toString();
  } on ArgumentError {
    return null; // a path this platform cannot express as a URI
  }
}

/// Bytes → a value. Relative links resolve against the response's URL
/// (or the file's URI) from the typed [Origin]; other readers parse without
/// a base.
extension ReaderHtml on Reader {
  /// The body parsed as HTML, its URL (or file) the base for links.
  Future<Elements> html() async => Html.parse(await text(), base: _baseFor(origin()));
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
  Future<String> markup() async => (await this).markup();
  Future<String?> attr(String name) async => (await this).attr(name);
  Future<List<String>> attrs(String name) async => (await this).attrs(name);
  Future<Json> json() async => (await this).json();
  Future<List<Map<String, String>>> table() async => (await this).table();
  Future<({String action, String method, Map<String, List<String>> fields})?> form() async => (await this).form();
}

/// Future mirrors for [Element].
extension ElementFuture on Future<Element> {
  Future<Elements> $(String selector) async => (await this).$(selector);
  Future<String> text() async => (await this).text();
  Future<String> markup() async => (await this).markup();
  Future<String?> attr(String name) async => (await this).attr(name);
  Future<Element?> parent() async => (await this).parent();
}
