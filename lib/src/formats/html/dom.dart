// The one markup tree HTML and XML both parse into, and the queries on it.

part of '../../../formats.dart';

/// Which markup an [Element] came from, and so how it serialises: HTML keeps void and
/// raw-text elements, XML closes everything, empty ones as `<e/>`.
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

  /// Removes this node from its parent element, or does nothing if it has no parent.
  void remove() {
    final p = parent;
    if (p == null) return;
    if (this is Attribute) {
      p.attributes.remove((this as Attribute).name);
    } else {
      p.nodes.remove(this);
    }
    parent = null;
  }

  /// Replaces this node in its parent's children with [other].
  void replaceWith(Node other) {
    final p = parent;
    if (p == null) return;
    if (this is Attribute) {
      throw StateError('Cannot replace an attribute with a node');
    }
    final index = p.nodes.indexOf(this);
    if (index != -1) {
      other.remove();
      other.parent = p;
      p.nodes[index] = other;
      parent = null;
    }
  }

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
    _writeEscaped(sb, data, attribute: false, xml: parent?.syntax == Syntax.xml);
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
    _writeEscaped(sb, value, attribute: true, xml: parent?.syntax == Syntax.xml);
    return (sb..write('"')).toString();
  }

  /// Equal when they name the same attribute on the same element: XPath mints a new instance
  /// per step, and a node-set must de-duplicate and sort them as one node.
  @override
  bool operator ==(Object other) => other is Attribute && other.name == name && identical(other.parent, parent);

  @override
  int get hashCode => Object.hash(identityHashCode(parent), name);
}

/// An element: a [name], its [attributes], and the [nodes] inside it. HTML names arrive
/// lowercased, XML ones as written; [syntax] decides serialisation and CSS case folding.
///
/// {@category Formats}
final class Element extends Node {
  /// The tag name: `div` for HTML, as written for XML (`media:content`).
  final String name;

  /// Attributes by name, values decoded; a valueless attribute is `''`.
  final Map<String, String> attributes;

  /// Child nodes in document order.
  final List<Node> nodes = [];

  /// Which markup this element came from.
  final Syntax syntax;

  /// Index in the parent's [nodes], checked before searching, so sibling walks stay linear.
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

  /// Attribute [name], or a [StateError] naming it and the tag; see [attrOrNull].
  String attr(String name) => attributes[name] ?? (throw StateError('<${this.name}> has no $name attribute'));

  /// Attribute [name] on this element, or `null`.
  String? attrOrNull(String name) => attributes[name];

  /// This element's `href` (or `src`) resolved against its document's base address,
  /// or `null` when neither attribute is present or valid.
  Uri? get link {
    final href = attributes['href'] ?? attributes['src'];
    if (href == null) return null;
    final uri = Uri.tryParse(href.trim());
    if (uri == null) return null;
    var top = this;
    for (var p = top.parent; p != null; p = p.parent) {
      top = p;
    }
    final base = _baseOf(top);
    return base == null ? uri : base.resolveUri(uri);
  }

  /// Appends [node] to this element's children.
  void append(Node node) {
    node.remove();
    node.parent = this;
    nodes.add(node);
  }

  /// Prepends [node] to this element's children.
  void prepend(Node node) {
    node.remove();
    node.parent = this;
    nodes.insert(0, node);
  }

  /// Removes all child nodes from this element.
  void clear() {
    for (final node in nodes) {
      node.parent = null;
    }
    nodes.clear();
  }

  /// Every descendant matching CSS [selector], in document order. HTML names fold to
  /// lowercase; for an XML prefix escape the colon, `r'media\:content'`.
  ///
  /// A leading combinator reads from this element, as in `:has()`: `> li.x` is its children,
  /// `+ dd` the next sibling, `~ p` the later ones; in `> a, b` the `b` is a descendant.
  Elements $(String selector) => Elements(_Selector.parse(selector, fold: syntax == Syntax.html).from(this));

  /// The nodes XPath [expression] selects with this element as the context.
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

  /// The text as it reads on the page, trimmed, blank lines dropped: lines break at `<br>`,
  /// newlines and block elements (`p`, `div`, `li`, `tr`…), cells in a row are tab-separated,
  /// and `head`, `script`, `style`, `template` and `noscript` are skipped.
  ///
  /// A non-breaking space is a space here but not in [text], which XPath compares against.
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

  /// This `<table>` (or the first one below this element) as rows of named columns.
  ///
  /// The header is the first all-`<th>` row or the first `<thead>` row; an unnamed column is
  /// `c1, c2, …` and a repeated name gets a suffix (`Price_2`). `colspan` and `rowspan` repeat
  /// a cell's text into every column and row it covers.
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
      // Cells carried past a short row's end keep their columns, with gaps between.
      for (var max = carried.keys.fold(-1, (m, k) => k > m ? k : m); row.length <= max;) {
        carried.containsKey(row.length) ? fill() : row.add(null);
      }
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

/// The elements a query matched, in document order: a [List] with the first match's [text],
/// [attr], [lines], [markup] and [table] (`doc.$('a').attr('href')`), and every match's
/// [texts], [attrs] and [links].
///
/// {@category Formats}
extension type Elements(List<Element> _list) implements List<Element> {
  /// The first match's text. Throws [StateError] when nothing matched.
  String get text => _first.text;

  /// The first match's text, or `null` when nothing matched.
  String? get textOrNull => _list.firstOrNull?.text;

  /// The first match's resolved [Element.link], or `null` when nothing matched or it has no link.
  Uri? get link => _list.firstOrNull?.link;

  /// The first match's [Element.lines]. Throws [StateError] when nothing matched.
  List<String> get lines => _first.lines;

  /// Every match's text, in document order; [text] is the first one.
  List<String> get texts => [for (final e in _list) e.text];

  /// Attribute [name] on the first match; a [StateError] when nothing matched or it is absent.
  String attr(String name) => _first.attr(name);

  /// Attribute [name] on the first match, or `null` when it is absent or nothing matched.
  String? attrOrNull(String name) => _list.firstOrNull?.attributes[name];

  /// Attribute [name] on every match that has it, in document order; [attr] is the first.
  List<String> attrs(String name) => [for (final e in _list) ?e.attributes[name]];

  /// The first match serialised; see [Element.markup]. Throws [StateError] when nothing matched.
  String get markup => _first.markup;

  /// The first match's [Element.table], or an empty table when nothing matched.
  Table get table => _list.isEmpty ? Table(const [], const []) : _list.first.table;

  /// Every match's `href` (or `src`) resolved against its [HtmlDocument.base], or as written
  /// without one: `doc.$('img').links`. A match with neither, or not a URI, is skipped.
  List<Uri> get links {
    final out = <Uri>[];
    Element? root;
    Uri? base;
    for (final e in _list) {
      final href = e.attributes['href'] ?? e.attributes['src'];
      if (href == null) continue;
      final uri = Uri.tryParse(href.trim());
      if (uri == null) continue;
      var top = e;
      for (var p = top.parent; p != null; p = p.parent) {
        top = p;
      }
      if (!identical(top, root)) (root, base) = (top, _baseOf(top));
      out.add(base == null ? uri : base.resolveUri(uri));
    }
    return out;
  }

  /// Every element each match's [Element.$] finds, each once, in document order.
  Elements $(String selector) {
    final s = _Selector.parse(selector, fold: _list.firstOrNull?.syntax != Syntax.xml);
    final seen = <Element>{};
    final out = [
      for (final e in _list)
        for (final m in s.from(e))
          if (seen.add(m)) m,
    ];
    // A descendant query from scopes in order finds in order; `> li` from nested ones does not.
    return Elements(s.relative && _list.length > 1 ? _inOrder(out) : out);
  }

  /// The nodes XPath [expression] selects from each match, each once, in document order.
  Nodes $x(String expression) {
    final x = _XPath.parse(expression);
    final seen = <Node>{};
    final out = [
      for (final e in _list)
        for (final n in x.select(e))
          if (seen.add(n)) n,
    ];
    return Nodes(_list.length > 1 && !(x.downward && _isFlat(_list)) ? _inOrder(out) : out);
  }

  /// Removes every matched element from its parent.
  void remove() {
    for (final e in _list) {
      e.remove();
    }
  }

  Element get _first => _list.isEmpty ? throw StateError('Nothing matched the selector') : _list.first;
}

/// The nodes an XPath query selected, in document order: a [List] with the first node's
/// [text] and [attr], and [elements] to go on with CSS: `doc.$x('//table').elements.$('td')`.
///
/// {@category Formats}
extension type Nodes(List<Node> _list) implements List<Node> {
  /// The first node's string value. Throws [StateError] when nothing matched.
  String get text => _list.isEmpty ? throw StateError('Nothing matched the XPath expression') : _list.first.text;

  /// The first node's string value, or `null` when nothing matched.
  String? get textOrNull => _list.firstOrNull?.text;

  /// Attribute [name] on the first element; a [StateError] when there is none or it is absent.
  String attr(String name) =>
      (_list.whereType<Element>().firstOrNull ?? (throw StateError('No element matched the XPath expression'))).attr(
        name,
      );

  /// Attribute [name] on the first element, or `null` when absent or nothing matched.
  String? attrOrNull(String name) => _list.whereType<Element>().firstOrNull?.attributes[name];

  /// Only the elements among the selected nodes.
  Elements get elements => Elements(_list.whereType<Element>().toList());

  /// The first match's resolved [Element.link], or `null` when nothing matched or it has no link.
  Uri? get link => elements.link;

  /// The resolved link of every element with an `href` or `src`.
  List<Uri> get links => elements.links;

  /// Every node's string value.
  List<String> get texts => [for (final n in _list) n.text];

  /// Every descendant of every selected element matching CSS [selector], each once.
  Elements $(String selector) => elements.$(selector);

  /// XPath [expression] from each selected element, each node once.
  Nodes $x(String expression) => elements.$x(expression);

  /// Removes every matched node from its parent.
  void remove() {
    for (final n in _list) {
      n.remove();
    }
  }
}

/// A parsed HTML document with CSS selectors.
///
/// {@category Formats}
final class HtmlDocument {
  /// The `<html>` element. Parsing always produces one, with `<head>` and `<body>` inside.
  final Element root;

  /// A document over [root]; relative links resolve against [url].
  HtmlDocument(this.root, {Uri? url}) {
    // The first address a root is given stays: another document over it must not move links.
    if (url != null) _urls[root] ??= url;
  }

  /// Parses [text] as HTML; tag soup lands where a browser puts it. [url] is the page's
  /// address, which [base] and [Elements.links] resolve against.
  factory HtmlDocument.parse(String text, {Uri? url}) => HtmlDocument(_parseHtml(text), url: url);

  /// What relative links resolve against: `<base href>` (resolved against the parse address),
  /// else that address, else `null`.
  Uri? get base => _baseOf(root);

  /// Every element matching CSS [selector], in document order.
  Elements $(String selector) => Elements(_Selector.parse(selector).inDocument(root));

  /// The nodes XPath [expression] selects: `//a/@href`, `//tr[td[2]="FLAC"]/td[1]/a`,
  /// `//h2[contains(., "Tracks")]/following-sibling::table[1]`.
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

/// Each document's address by root element, kept outside the tree so no element pays a field.
final _urls = Expando<Uri>('url');

/// See [HtmlDocument.base]: the first `<base href>` anywhere, as a browser reads it.
Uri? _baseOf(Element root) {
  final url = _urls[root];
  String? href;
  _eachBelow(root, (e) => e is Element && e.name == 'base' && (href = e.attributes['href']) != null);
  final uri = href == null ? null : Uri.tryParse(href!.trim());
  if (uri == null) return url;
  return url == null ? uri : url.resolveUri(uri);
}

/// [nodes] in document order, sorted only when they are not already.
List<T> _inOrder<T extends Node>(List<T> nodes) {
  if (nodes.length < 2) return nodes;
  final order = <Node, int>{};
  int key(Node n) {
    final e = n is Attribute ? n.parent! : n;
    final k = order[e];
    if (k != null) return k;
    var top = e;
    for (var p = top.parent; p != null; p = p.parent) {
      top = p;
    }
    order[top] = order.length;
    _eachBelow(top, (m) {
      order[m] = order.length;
      return false;
    });
    return order[e] ?? -1;
  }

  var sorted = true;
  for (var i = 1; i < nodes.length && sorted; i++) {
    sorted = key(nodes[i - 1]) <= key(nodes[i]);
  }
  if (sorted) return nodes;
  return nodes..sort((x, y) {
    final c = key(x).compareTo(key(y));
    if (c != 0) return c;
    if (x is! Attribute) return y is Attribute ? -1 : 0;
    return y is! Attribute ? 1 : _slotOf(x).compareTo(_slotOf(y));
  });
}

/// The document node above the root, where an absolute XPath starts; minted per walk, so equal
/// by root.
final class _Document extends Element {
  final Element root;
  _Document(this.root) : super('#document', const {}, root.syntax);
  @override
  String get text => root.text;
  @override
  String get markup => root.markup;
  @override
  bool operator ==(Object other) => other is _Document && identical(other.root, root);
  @override
  int get hashCode => identityHashCode(root);
}

/// [make]'s result for [key], cached among the last 256: the CSS, XPath and JSONPath cache,
/// bounded for programs that build queries from data.
V _compiled<K, V>(Map<K, V> cache, K key, V Function() make) {
  final hit = cache[key];
  if (hit != null) return hit;
  if (cache.length >= 256) cache.remove(cache.keys.first);
  return cache[key] = make();
}

/// How deep tree walks recurse before switching to an explicit stack: recursion is a third
/// faster, the stack survives documents nested 100 000 deep.
const _deep = 256;

/// Visits the nodes below [n] in document order until [visit] returns true, and returns
/// whether it did; [depth] 1 is the children only.
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

/// Writes [root] as markup into [sb], with an explicit stack so deep documents don't overflow.
void _serialize(Node root, StringBuffer sb) {
  if (root is! Element) {
    sb.write(root.markup);
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
      _writeEscaped(sb, n.data, attribute: false, xml: e.syntax == Syntax.xml);
    }
  }
}

/// Writes [e]'s start tag, and returns whether its children and end tag are still to come:
/// not for a void element, an empty XML one, or a raw-text one, written whole here.
bool _writeStartTag(Element e, StringBuffer sb) {
  sb
    ..write('<')
    ..write(e.name);
  for (final MapEntry(:key, :value) in e.attributes.entries) {
    sb
      ..write(' ')
      ..write(key)
      ..write('="');
    _writeEscaped(sb, value, attribute: true, xml: e.syntax == Syntax.xml);
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
  if (e.name == 'pre' || e.name == 'textarea' || e.name == 'listing') {
    final first = e.nodes.firstOrNull;
    if (first is Text && first.data.startsWith('\n')) sb.write('\n');
  }
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
/// double-quoted attribute, copying the runs between them whole. XML also escapes a carriage
/// return, which its parser would read back as a newline.
void _writeEscaped(StringBuffer sb, String s, {required bool attribute, bool xml = false}) {
  var from = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final String? escape = switch (c) {
      0x26 => '&amp;',
      0x3c => '&lt;',
      0x3e when !attribute => '&gt;',
      0x22 when attribute => '&quot;',
      0x0a when attribute && xml => '&#10;',
      0x0d when xml => '&#13;',
      0x09 when attribute && xml => '&#9;',
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

/// Elements below [root] named in [names], in document order, not entering one named in
/// [stop]: a nested table keeps its own rows, a row its own cells.

List<Element> _within(Element root, Set<String> names, Set<String> stop) {
  final out = <Element>[];
  final lists = <List<Node>>[];
  final at = <int>[];
  var list = root.nodes;
  var i = 0;
  while (true) {
    if (i < list.length) {
      final node = list[i++];
      if (node is! Element || stop.contains(node.name)) continue;
      if (names.contains(node.name)) {
        out.add(node);
      } else if (node.nodes.isNotEmpty) {
        lists.add(list);
        at.add(i);
        list = node.nodes;
        i = 0;
      }
    } else if (lists.isEmpty) {
      return out;
    } else {
      list = lists.removeLast();
      i = at.removeLast();
    }
  }
}

/// A cell's `colspan` or `rowspan`: 1 when absent or unreadable, at most [max].
int _span(Element cell, String name, int max) {
  final n = int.tryParse(cell.attributes[name]?.trim() ?? '') ?? 1;
  return n < 1 ? 1 : (n > max ? max : n);
}
