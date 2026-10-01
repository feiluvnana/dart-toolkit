// The markup tree: nodes, elements, and the queries on them. HTML and XML differ in how
// they are parsed and serialised, not in what they parse into, so there is one tree.

part of '../../../formats.dart';

/// Which markup an [Element] was parsed from, and so how it serialises: HTML keeps its
/// void and raw-text elements, XML closes everything and may close it in one tag.
///
/// {@category Formats}
enum Syntax { html, xml }

/// A node in a parsed markup tree: an [Element], a [Text], or an [Attribute] selected by
/// an XPath `@` step.
///
/// {@category Formats}
sealed class Node {
  /// The element containing this node, or `null` at the root.
  Element? parent;

  /// The text of this node and everything below it, entities decoded.
  String get text;

  /// This node serialised back to the markup it came from.
  String get markup;

  @override
  String toString() => markup;
}

/// A run of text. [data] is decoded: `&amp;` is already `&`.
///
/// {@category Formats}
final class Text extends Node {
  final String data;

  Text(this.data);

  @override
  String get text => data;

  @override
  String get markup {
    final sb = StringBuffer();
    _writeEscaped(sb, data, attribute: false);
    return sb.toString();
  }
}

/// An attribute, as an XPath `@name` step selects it.
///
/// {@category Formats}
final class Attribute extends Node {
  final String name;
  final String value;

  Attribute(this.name, this.value, Element owner) {
    parent = owner;
  }

  @override
  String get text => value;

  @override
  String get markup {
    final sb = StringBuffer('$name="');
    _writeEscaped(sb, value, attribute: true);
    return (sb..write('"')).toString();
  }

  /// Two of these are the same attribute when they name the same thing on the same element.
  ///
  /// An `@href` step and a document-order walk each mint their own instance for one
  /// attribute, and the sets and maps that de-duplicate and order a node-set have to see
  /// those as one node — otherwise a union repeats attributes and cannot sort them.
  @override
  bool operator ==(Object other) => other is Attribute && other.name == name && identical(other.parent, parent);

  @override
  int get hashCode => Object.hash(identityHashCode(parent), name);
}

/// An element: a [name], its [attributes], and the [nodes] inside it.
///
/// One class for both markups: an HTML tag name and attribute name arrive lowercased, an
/// XML one as written, and [syntax] is what decides how the element serialises and whether
/// a CSS selector folds case.
///
/// {@category Formats}
final class Element extends Node {
  /// The tag name: lowercase for HTML (`a`, `div`, `td`), as written for XML
  /// (`item`, `media:content`).
  final String name;

  /// Attributes by name — lowercased for HTML, as written for XML — values decoded. A
  /// valueless attribute is `''`.
  final Map<String, String> attributes;

  /// Child nodes in document order.
  final List<Node> nodes = [];

  /// Which markup this element came from.
  final Syntax syntax;

  /// Where this element was put in its parent's [nodes]: a hint that [nextElement] checks
  /// before searching, so walking a run of siblings is linear rather than quadratic.
  int _slot = 0;

  Element(this.name, [Map<String, String>? attributes, this.syntax = Syntax.html]) : attributes = attributes ?? {};

  /// Child elements, skipping text.
  Iterable<Element> get children => nodes.whereType<Element>();

  /// The name without its namespace prefix: `content` for `media:content`.
  String get local => name.contains(':') ? name.substring(name.indexOf(':') + 1) : name;

  /// The namespace prefix, or `null`.
  String? get prefix => name.contains(':') ? name.substring(0, name.indexOf(':')) : null;

  /// The `id` attribute, or `null`.
  String? get id => attributes['id'];

  /// The `class` attribute split on whitespace.
  Set<String> get classes => switch (attributes['class']) {
    null || '' => const {},
    final s => {
      for (final c in s.split(_ws))
        if (c.isNotEmpty) c,
    },
  };

  /// Attribute [name] on this element. Throws a [StateError] naming the attribute and the tag
  /// when it is absent; [attrOrNull] is for the caller who expects that.
  String attr(String name) => attributes[name] ?? (throw StateError('<${this.name}> has no $name attribute'));

  /// Attribute [name] on this element, or `null`.
  String? attrOrNull(String name) => attributes[name];

  /// Every descendant matching CSS [selector], in document order.
  ///
  /// Names fold to lowercase for HTML and match as written for XML. A prefixed XML name
  /// (`media:content`) is not a CSS identifier; select those with the XPath form.
  Elements $(String selector) => Elements(_Selector.parse(selector, fold: syntax == Syntax.html).matchAll(this));

  /// The nodes matching XPath [expression] with this element as the context; see XPath.
  Nodes $x(String expression) => Nodes(_XPath.parse(expression).select(this));

  @override
  String get text {
    // One text child is most elements that have text at all, and needs no buffer.
    if (nodes.length == 1 && nodes.first is Text) return (nodes.first as Text).data;
    final sb = StringBuffer();
    _writeText(this, sb, 0);
    return sb.toString();
  }

  static void _writeText(Element e, StringBuffer sb, int depth) {
    for (final n in e.nodes) {
      if (n is Text) {
        sb.write(n.data);
      } else if (n is Element) {
        if (depth < _deep) {
          _writeText(n, sb, depth + 1);
        } else {
          _eachBelow(n, (m) {
            if (m is Text) sb.write(m.data);
            return false;
          });
        }
      }
    }
  }

  /// The text as it reads on the page, one line per entry: a line ends at a `<br>`, a
  /// newline, and either edge of a block element (`p`, `div`, `li`, `tr`, `h1`…); table
  /// cells on one row are separated by a tab; `head`, `script`, `style`, `template` and
  /// `noscript` are skipped. Entities are decoded, blank lines dropped, each line trimmed.
  ///
  /// A non-breaking space counts as a space here, unlike in [text]: these are lines meant to
  /// be read, while [text] is the node's string value and has to stay faithful — XPath's
  /// `string()` and every predicate comparison go through it.
  List<String> get lines {
    final out = <String>[];
    final current = StringBuffer();

    void flush() {
      final line = current.toString().replaceAll('\u00a0', ' ').trim();
      if (line.isNotEmpty) out.add(line);
      current.clear();
    }

    final open = <Element>[this];
    final at = <int>[0];
    while (open.isNotEmpty) {
      final e = open.last;
      final i = at.last;
      if (i == e.nodes.length) {
        open.removeLast();
        at.removeLast();
        if (_blockElements.contains(e.name)) flush();
        continue;
      }
      at[at.length - 1] = i + 1;
      switch (e.nodes[i]) {
        case final Text t:
          final data = t.data;
          var from = 0;
          for (var nl = data.indexOf('\n'); nl != -1; nl = data.indexOf('\n', from)) {
            current.write(data.substring(from, nl));
            flush();
            from = nl + 1;
          }
          current.write(from == 0 ? data : data.substring(from));
        case final Element child:
          final name = child.name;
          if (name == 'br') {
            flush();
          } else if (!_hiddenElements.contains(name)) {
            if (_blockElements.contains(name)) {
              flush();
            } else if ((name == 'td' || name == 'th') && current.isNotEmpty) {
              current.write('\t');
            }
            open.add(child);
            at.add(0);
          }
        default:
      }
    }
    flush();
    return out;
  }

  /// The children serialised, without this element's own tags.
  String get innerMarkup {
    final sb = StringBuffer();
    for (final n in nodes) {
      _serialize(n, sb);
    }
    return sb.toString();
  }

  @override
  String get markup {
    final sb = StringBuffer();
    _serialize(this, sb);
    return sb.toString();
  }

  /// The next element sibling, or `null`.
  Element? get nextElement => _sibling(1);

  /// The previous element sibling, or `null`.
  Element? get previousElement => _sibling(-1);

  Element? _sibling(int step) {
    final siblings = parent?.nodes;
    if (siblings == null) return null;
    if (_slot >= siblings.length || !identical(siblings[_slot], this)) _slot = siblings.indexOf(this);
    for (var i = _slot + step; i >= 0 && i < siblings.length; i += step) {
      if (siblings[i] case final Element e) return e;
    }
    return null;
  }
}

final _ws = RegExp(r'\s+');

/// The elements a query matched, in document order. A [List], with the first match's
/// [text], [attr], [lines] and [$] one hop closer: `doc.$('a').attr('href')`.
///
/// {@category Formats}
extension type Elements(List<Element> _list) implements List<Element> {
  /// The first match's text. Throws [StateError] when nothing matched.
  String get text => _first.text;

  /// The first match's text lines; see [Element.lines]. Throws [StateError] when nothing matched.
  List<String> get lines => _first.lines;

  /// Every match's text, in document order; [text] is the first one.
  List<String> get texts => [for (final e in _list) e.text];

  /// Attribute [name] on the first match. Throws a [StateError] when nothing matched or the
  /// first match has no such attribute.
  String attr(String name) => _first.attr(name);

  /// Attribute [name] on the first match, or `null` when it is absent or nothing matched.
  String? attrOrNull(String name) => _list.firstOrNull?.attributes[name];

  /// Every descendant of every match that matches [selector], each once, in document order.
  Elements $(String selector) {
    final s = _Selector.parse(selector, fold: _list.firstOrNull?.syntax != Syntax.xml);
    final seen = <Element>{};
    return Elements([
      for (final e in _list)
        for (final m in s.matchAll(e))
          if (seen.add(m)) m,
    ]);
  }

  /// The nodes matching XPath [expression] from each match, each node once, in document order.
  Nodes $x(String expression) {
    final x = _XPath.parse(expression);
    final seen = <Node>{};
    return Nodes([
      for (final e in _list)
        for (final n in x.select(e))
          if (seen.add(n)) n,
    ]);
  }

  Element get _first => _list.isEmpty ? throw StateError('Nothing matched the selector') : _list.first;
}

/// The nodes an XPath query selected, in document order: elements, text and attributes. A
/// [List], with the first node's [text] and [attr] one hop closer, and [elements] to go on
/// with CSS: `doc.$x('//table[.//th="Title"]').elements.$('td')`.
///
/// {@category Formats}
extension type Nodes(List<Node> _list) implements List<Node> {
  /// The first node's string value. Throws [StateError] when nothing matched.
  String get text => _list.isEmpty ? throw StateError('Nothing matched the XPath expression') : _list.first.text;

  /// Attribute [name] on the first element. Throws a [StateError] when no element was
  /// selected or the first has no such attribute.
  String attr(String name) =>
      (_list.whereType<Element>().firstOrNull ?? (throw StateError('No element matched the XPath expression'))).attr(
        name,
      );

  /// Attribute [name] on the first element, or `null` when absent or nothing matched.
  String? attrOrNull(String name) => _list.whereType<Element>().firstOrNull?.attributes[name];

  /// Only the elements among the selected nodes.
  Elements get elements => Elements(_list.whereType<Element>().toList());

  /// Every node's string value.
  List<String> get texts => [for (final n in _list) n.text];

  /// Every descendant of every selected element matching CSS [selector], each once.
  Elements $(String selector) => elements.$(selector);

  /// XPath [expression] from each selected element, each node once.
  Nodes $x(String expression) => elements.$x(expression);
}

/// A parsed HTML document with CSS selectors.
///
/// {@category Formats}
final class HtmlDocument {
  /// The `<html>` element. Parsing always produces one, with `<head>` and `<body>` inside.
  final Element root;

  HtmlDocument(this.root);

  /// Parses [text] as HTML. Tag soup is fine: unclosed `<p>` and `<li>`, missing
  /// `<html>`/`<body>`, and `<tr>` straight inside `<table>` all land where a browser puts them.
  factory HtmlDocument.parse(String text) => HtmlDocument(_parseHtml(text));

  /// Every element matching CSS [selector], in document order.
  Elements $(String selector) => Elements(_Selector.parse(selector).matchAll(root, includeSelf: true));

  /// The nodes matching XPath [expression], from the document: `//a/@href`,
  /// `//tr[td[2]="FLAC"]/td[1]/a`, `//h2[contains(., "Tracks")]/following-sibling::table[1]`.
  Nodes $x(String expression) => Nodes(_XPath.parse(expression).select(root));

  /// The `<head>` element.
  Element get head => root.children.firstWhere((e) => e.name == 'head');

  /// The `<body>` element.
  Element get body => root.children.firstWhere((e) => e.name == 'body');

  /// The document's text, entities decoded.
  String get text => root.text;

  /// The document serialised back to HTML.
  String get markup => root.markup;

  @override
  String toString() => markup;
}

/// Stands for the document above `<html>`, so an absolute XPath has somewhere to start.
///
/// One is made whenever a walk reaches the top, so two of them are the same node when they
/// stand above the same root.
final class _Document extends Node {
  final Element root;
  _Document(this.root);
  @override
  String get text => root.text;
  @override
  String get markup => root.markup;
  @override
  bool operator ==(Object other) => other is _Document && identical(other.root, root);
  @override
  int get hashCode => identityHashCode(root);
}

/// [make]'s result for [key], made once and kept among the last 256 — the cache every
/// compiled query uses (CSS, XPath, JSONPath). A program that builds queries from data, a
/// column name or a user's input, would otherwise grow it forever.
V _compiled<K, V>(Map<K, V> cache, K key, V Function() make) {
  final hit = cache[key];
  if (hit != null) return hit;
  if (cache.length >= 256) cache.remove(cache.keys.first);
  return cache[key] = make();
}

/// How deep the tree walks recurse before they carry on with an explicit stack. Recursion
/// measured a third faster on real pages; the stack is what lets a document nested a
/// hundred thousand deep be read rather than overflow.
const _deep = 256;

/// Visits the nodes below [n] in document order until [visit] returns true, and returns
/// whether it did. [depth] limits how far down: 1 is the children. `$`'s `:has()` and every
/// XPath axis that goes down walk with this.
bool _eachBelow(Node n, bool Function(Node) visit, {int depth = 1 << 30}) {
  final lists = <List<Node>>[];
  final at = <int>[];
  var list = _down(n);
  var i = 0;
  while (true) {
    if (i < list.length) {
      final m = list[i++];
      if (visit(m)) return true;
      if (m is Element && m.nodes.isNotEmpty && lists.length + 1 < depth) {
        lists.add(list);
        at.add(i);
        list = m.nodes;
        i = 0;
      }
    } else if (lists.isEmpty) {
      return false;
    } else {
      list = lists.removeLast();
      i = at.removeLast();
    }
  }
}

/// Elements [Element.lines] breaks a line around.
const _blockElements = {
  'address', 'article', 'aside', 'blockquote', 'body', 'caption', 'center', 'dd', 'details', 'dialog', 'dir', //
  'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'header', 'hgroup', 'hr', 'html', 'legend', 'li', 'main', 'menu', 'nav', 'ol', 'option', 'p', 'pre', 'section',
  'summary', 'table', 'tbody', 'tfoot', 'thead', 'tr', 'ul',
};

/// Elements [Element.lines] leaves out: nothing in them is read on the page.
const _hiddenElements = {'script', 'style', 'template', 'noscript', 'head'};

/// Writes [root] and everything below it into [sb] as markup, in one buffer.
///
/// One buffer and an explicit stack: concatenating each element's children into a string
/// for its parent copied every subtree once per level above it, and recursing overflowed
/// on a document nested deep enough.
void _serialize(Node root, StringBuffer sb) {
  if (root is! Element) {
    switch (root) {
      case final Text t:
        _writeEscaped(sb, t.data, attribute: false);
      default:
        sb.write(root.markup);
    }
    return;
  }
  if (!_writeStartTag(root, sb)) return;
  final open = <Element>[root];
  final at = <int>[0];
  while (open.isNotEmpty) {
    final e = open.last;
    final i = at.last;
    if (i == e.nodes.length) {
      sb
        ..write('</')
        ..write(e.name)
        ..write('>');
      open.removeLast();
      at.removeLast();
      continue;
    }
    at[at.length - 1] = i + 1;
    final n = e.nodes[i];
    if (n is Element) {
      if (_writeStartTag(n, sb)) {
        open.add(n);
        at.add(0);
      }
    } else if (n is Text) {
      _writeEscaped(sb, n.data, attribute: false);
    }
  }
}

/// Writes [e]'s start tag. Returns whether its children and end tag are still to come:
/// false for a void element, an empty XML one (`<e/>`), and a raw-text one, whose content
/// is written here, unescaped, with its end tag.
bool _writeStartTag(Element e, StringBuffer sb) {
  sb
    ..write('<')
    ..write(e.name);
  for (final MapEntry(:key, :value) in e.attributes.entries) {
    sb
      ..write(' ')
      ..write(key)
      ..write('="');
    _writeEscaped(sb, value, attribute: true);
    sb.write('"');
  }
  if (e.syntax == Syntax.xml) {
    if (e.nodes.isNotEmpty) {
      sb.write('>');
      return true;
    }
    sb.write('/>');
    return false;
  }
  sb.write('>');
  if (_voidElements.contains(e.name)) return false;
  if (!_rawTextElements.contains(e.name)) return true;
  for (final n in e.nodes) {
    n is Text ? sb.write(n.data) : _serialize(n, sb);
  }
  sb
    ..write('</')
    ..write(e.name)
    ..write('>');
  return false;
}

/// Writes [s] with `&`, `<` and `>` escaped for a text node, or `&` and `"` for a
/// double-quoted attribute, copying the runs between them whole.
void _writeEscaped(StringBuffer sb, String s, {required bool attribute}) {
  var from = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final String? escape = switch (c) {
      0x26 => '&amp;',
      0x3c when !attribute => '&lt;',
      0x3e when !attribute => '&gt;',
      0x22 when attribute => '&quot;',
      _ => null,
    };
    if (escape == null) continue;
    if (i > from) sb.write(s.substring(from, i));
    sb.write(escape);
    from = i + 1;
  }
  if (from == 0) {
    sb.write(s);
  } else if (from < s.length) {
    sb.write(s.substring(from));
  }
}

/// Elements below [root] named in [names], skipping whatever is inside a nested element
/// named in [stop], in document order.
///
/// The walk a `<table>` needs: a table inside a cell keeps its own rows, and a row keeps
/// its own cells. Doing it with `$` instead meant a subtree search per row whose matches
/// then had to be filtered back down by their nearest ancestor.
List<Element> _within(Element root, Set<String> names, Set<String> stop) {
  final out = <Element>[];
  void walk(Element e) {
    for (final node in e.nodes) {
      if (node is! Element || stop.contains(node.name)) continue;
      names.contains(node.name) ? out.add(node) : walk(node);
    }
  }

  walk(root);
  return out;
}

/// An HTML `<table>` as a [Table].
///
/// {@category Formats}
extension ElementTableExtensions on Element {
  /// This `<table>` (or the first one below this element) as rows of named columns.
  ///
  /// The header is the first row of `<th>` cells, or the first row of a `<thead>` whatever
  /// its cells; a column without a name is `c1, c2, …`, and a name that repeats gets a
  /// suffix (`Price`, `Price_2`) so no column hides another. Every other `<tr>` with a `<td>`
  /// is a row. A cell's `colspan` and `rowspan` repeat its text into every column and row it
  /// covers, so a row's values stay under their headings.
  Table get table {
    final t = name == 'table' ? this : $('table').firstOrNull;
    if (t == null) return Table(const [], const []);
    List<String>? header;
    final body = <List<String?>>[];
    // Cells a rowspan carries down: column → (text, rows still to fill).
    final carried = <int, (String, int)>{};
    for (final tr in _within(t, const {'tr'}, const {'table'})) {
      final cells = _within(tr, const {'th', 'td'}, const {'table', 'tr'});
      if (cells.isEmpty) continue;
      if (header == null && (tr.parent?.name == 'thead' || cells.every((c) => c.name == 'th'))) {
        header = [
          for (final c in cells)
            for (var k = _span(c, 'colspan', 1000); k > 0; k--) c.text.trim(),
        ];
        continue;
      }
      if (!cells.any((c) => c.name == 'td')) continue;
      final row = <String?>[];
      void fill() {
        for (var c = carried[row.length]; c != null; c = carried[row.length]) {
          final (text, left) = c;
          left == 1 ? carried.remove(row.length) : carried[row.length] = (text, left - 1);
          row.add(text);
        }
      }

      for (final c in cells) {
        fill();
        final text = c.text.trim();
        final down = _span(c, 'rowspan', 65534);
        for (var k = _span(c, 'colspan', 1000); k > 0; k--) {
          if (down > 1) carried[row.length] = (text, down - 1);
          row.add(text);
        }
      }
      fill();
      body.add(row);
    }
    final names = header ?? const <String>[];
    final width = body.fold(names.length, (w, r) => r.length > w ? r.length : w);
    final seen = <String, int>{};
    final columns = <String>[];
    for (var i = 0; i < width; i++) {
      var name = i < names.length && names[i].isNotEmpty ? names[i] : 'c${i + 1}';
      final n = seen[name] = (seen[name] ?? 0) + 1;
      if (n > 1) {
        var k = n;
        while (seen.containsKey('${name}_$k')) {
          k++;
        }
        name = '${name}_$k';
        seen[name] = 1;
      }
      columns.add(name);
    }
    return Table(columns, [
      for (final r in body) {for (var i = 0; i < columns.length; i++) columns[i]: i < r.length ? r[i] : null},
    ]);
  }
}

/// A cell's `colspan` or `rowspan`: 1 when absent or unreadable, at most [max].
int _span(Element cell, String name, int max) {
  final n = int.tryParse(cell.attributes[name]?.trim() ?? '') ?? 1;
  return n < 1 ? 1 : (n > max ? max : n);
}

/// {@category Formats}
extension ElementsTableExtensions on Elements {
  /// The first matched element's [ElementTableExtensions.table].
  Table get table => isEmpty ? Table(const [], const []) : first.table;
}

/// {@category Formats}
extension StringHtmlExtensions on String {
  /// This string parsed as HTML.
  HtmlDocument get html => HtmlDocument.parse(this);
}
