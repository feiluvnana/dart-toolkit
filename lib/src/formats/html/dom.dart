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
  String get markup => _escapeText(data);
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
  String get markup => '$name="${_escapeAttribute(value)}"';

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
  Set<String> get classes => {
    for (final c in (attributes['class'] ?? '').split(_ws))
      if (c.isNotEmpty) c,
  };

  /// Attribute [name] on this element, or `null`.
  String? attr(String name) => attributes[name];

  /// Every descendant matching CSS [selector], in document order.
  ///
  /// Names fold to lowercase for HTML and match as written for XML. A prefixed XML name
  /// (`media:content`) is not a CSS identifier; select those with the XPath form.
  Elements $(String selector) => Elements(_Selector.parse(selector, fold: syntax == Syntax.html).matchAll(this));

  /// The nodes matching XPath [expression] with this element as the context; see [XPath].
  Nodes $x(String expression) => Nodes(XPath.parse(expression).select(this));

  @override
  String get text {
    final sb = StringBuffer();
    void walk(Element e) {
      for (final n in e.nodes) {
        n is Text ? sb.write(n.data) : walk(n as Element);
      }
    }

    walk(this);
    return sb.toString();
  }

  /// Text lines split at `<br>` and newlines, _entities decoded, tags dropped, blanks removed.
  ///
  /// A non-breaking space counts as a space here, unlike in [text]: these are lines meant to
  /// be read, while [text] is the node's string value and has to stay faithful — XPath's
  /// `string()` and every predicate comparison go through it.
  List<String> get lines {
    final out = <String>[];
    final current = StringBuffer();

    void flush() {
      final line = current.toString().replaceAll(' ', ' ').trim();
      if (line.isNotEmpty) out.add(line);
      current.clear();
    }

    void walk(Element node) {
      for (final child in node.nodes) {
        if (child is Element) {
          child.name == 'br' ? flush() : walk(child);
        } else if (child is Text) {
          final parts = child.data.split('\n');
          for (var i = 0; i < parts.length; i++) {
            if (i > 0) flush();
            current.write(parts[i]);
          }
        }
      }
    }

    walk(this);
    flush();
    return out;
  }

  /// The children serialised, without this element's own tags.
  String get innerMarkup => nodes.map((n) => n.markup).join();

  @override
  String get markup {
    final sb = StringBuffer('<$name');
    for (final MapEntry(:key, :value) in attributes.entries) {
      sb.write(' $key="${_escapeAttribute(value)}"');
    }
    if (syntax == Syntax.xml) {
      if (nodes.isEmpty) return '$sb/>';
      sb
        ..write('>')
        ..write(innerMarkup)
        ..write('</$name>');
      return sb.toString();
    }
    sb.write('>');
    if (_voidElements.contains(name)) return sb.toString();
    if (_rawTextElements.contains(name)) {
      for (final n in nodes) {
        sb.write(n is Text ? n.data : n.markup);
      }
    } else {
      sb.write(innerMarkup);
    }
    sb.write('</$name>');
    return sb.toString();
  }

  /// The next element sibling, or `null`.
  Element? get nextElement => _sibling(1);

  /// The previous element sibling, or `null`.
  Element? get previousElement => _sibling(-1);

  Element? _sibling(int step) {
    final siblings = parent?.nodes;
    if (siblings == null) return null;
    for (var i = siblings.indexOf(this) + step; i >= 0 && i < siblings.length; i += step) {
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

  /// Attribute [name] on the first match, or `null` when it is absent or nothing matched.
  String? attr(String name) => _list.firstOrNull?.attributes[name];

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
    final x = XPath.parse(expression);
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

  /// Attribute [name] on the first element, or `null` when absent or nothing matched.
  String? attr(String name) => _list.whereType<Element>().firstOrNull?.attributes[name];

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
  Nodes $x(String expression) => Nodes(XPath.parse(expression).select(root));

  /// The `<head>` element.
  Element get head => root.children.firstWhere((e) => e.name == 'head');

  /// The `<body>` element.
  Element get body => root.children.firstWhere((e) => e.name == 'body');

  /// The document's text, _entities decoded.
  String get text => root.text;

  /// The document serialised back to HTML.
  String get outerHtml => root.markup;

  @override
  String toString() => outerHtml;
}

/// Stands for the document above `<html>`, so an absolute XPath has somewhere to start.
final class _Document extends Node {
  final Element root;
  _Document(this.root);
  @override
  String get text => root.text;
  @override
  String get markup => root.markup;
}

/// Decodes `&amp;`, `&#38;`, `&#x26;` and the HTML 4 named references in [text].
String decodeEntities(String text) {
  var amp = text.indexOf('&');
  if (amp == -1) return text;
  // The run between two references is copied in one go. Walking it code unit at a time
  // costs about four times as much, and most text has far more prose than entities.
  final sb = StringBuffer();
  var last = 0;
  while (amp != -1) {
    final end = _referenceEnd(text, amp + 1);
    final decoded = end == -1 ? null : _reference(text.substring(amp + 1, end));
    if (decoded == null) {
      amp = text.indexOf('&', amp + 1);
      continue;
    }
    sb
      ..write(text.substring(last, amp))
      ..write(decoded);
    last = end + (end < text.length && text.codeUnitAt(end) == 0x3b ? 1 : 0);
    amp = text.indexOf('&', last);
  }
  sb.write(text.substring(last));
  return sb.toString();
}

/// Where the reference starting after `&` ends: the index of `;` or of the first character
/// that cannot be part of it, or -1 when there is no reference here.
int _referenceEnd(String text, int start) {
  var i = start;
  if (i < text.length && text.codeUnitAt(i) == 0x23) i++; // #
  final from = i;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    final alnum = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    if (!alnum) break;
    i++;
  }
  return i == from ? -1 : i;
}

String? _reference(String name) {
  if (name.startsWith('#')) {
    final hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X');
    final code = int.tryParse(name.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
    if (code == null || code <= 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return null;
    return String.fromCharCode(code);
  }
  return _entities[name];
}

/// [text] with `&`, `<` and `>` escaped for a text node.
String _escapeText(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// [value] with `&` and `"` escaped for a double-quoted attribute.
String _escapeAttribute(String value) => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

/// The nearest ancestor of [e] named [name], or `null`.
Element? _closest(Element e, String name) {
  for (var p = e.parent; p != null; p = p.parent) {
    if (p.name == name) return p;
  }
  return null;
}

/// An HTML `<table>` as a [Table].
///
/// {@category Formats}
extension ElementTableExtensions on Element {
  /// This `<table>` (or the first one below this element) as rows of named columns: `<th>`
  /// texts name the columns, or `c1, c2, …` when there are none; each `<tr>` with `<td>` is a row.
  Table get table {
    final t = name == 'table' ? this : $('table').firstOrNull;
    if (t == null) return Table(const [], const []);
    var header = <String>[];
    final body = <List<String>>[];
    // Scoped by nearest enclosing table and row: `$` searches the whole subtree, so a
    // nested table would otherwise contribute its rows and cells to this one.
    for (final tr in t.$('tr').where((tr) => _closest(tr, 'table') == t)) {
      final ths = [
        for (final th in tr.$('th'))
          if (_closest(th, 'tr') == tr) th,
      ];
      final tds = [
        for (final td in tr.$('td'))
          if (_closest(td, 'tr') == tr) td,
      ];
      if (header.isEmpty && ths.isNotEmpty && tds.isEmpty) {
        header = [for (final th in ths) th.text.trim()];
      } else if (tds.isNotEmpty) {
        body.add([for (final td in tds) td.text.trim()]);
      }
    }
    final width = body.fold(header.length, (w, r) => r.length > w ? r.length : w);
    final columns = [
      for (var i = 0; i < width; i++) i < header.length && header[i].isNotEmpty ? header[i] : 'c${i + 1}',
    ];
    return Table(columns, [
      for (final r in body) {for (var i = 0; i < columns.length; i++) columns[i]: i < r.length ? r[i] : null},
    ]);
  }
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
