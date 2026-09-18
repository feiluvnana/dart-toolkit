// The HTML tree: nodes, elements, and the queries on them.

part of '../../html.dart';

/// A node in a parsed HTML tree: an [Element] or a [Text].
///
/// {@category Formats}
sealed class Node {
  /// The element containing this node, or `null` at the root.
  Element? parent;

  /// The text of this node and everything below it, _entities decoded.
  String get text;

  /// This node serialised back to HTML.
  String get outerHtml;

  @override
  String toString() => outerHtml;
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
  String get outerHtml => _escapeText(data);
}

/// An element: a lowercase [name], its [attributes], and the [nodes] inside it.
///
/// {@category Formats}
final class Element extends Node {
  /// The tag name, lowercase: `a`, `div`, `td`.
  final String name;

  /// Attributes by lowercase name, values decoded. A valueless attribute is `''`.
  final Map<String, String> attributes;

  /// Child nodes in document order.
  final List<Node> nodes = [];

  Element(this.name, [Map<String, String>? attributes]) : attributes = attributes ?? {};

  /// Child elements, skipping text.
  Iterable<Element> get children => nodes.whereType<Element>();

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
  Elements $(String selector) => Elements(_Selector.parse(selector).matchAll(this));

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
  String get innerHtml => nodes.map((n) => n.outerHtml).join();

  @override
  String get outerHtml {
    final sb = StringBuffer('<$name');
    for (final MapEntry(:key, :value) in attributes.entries) {
      sb.write(' $key="${_escapeAttribute(value)}"');
    }
    sb.write('>');
    if (_voidElements.contains(name)) return sb.toString();
    if (_rawTextElements.contains(name)) {
      for (final n in nodes) {
        sb.write(n is Text ? n.data : n.outerHtml);
      }
    } else {
      sb.write(innerHtml);
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

  /// Attribute [name] on the first match, or `null` when it is absent or nothing matched.
  String? attr(String name) => _list.firstOrNull?.attributes[name];

  /// Every descendant of every match that matches [selector], each once, in document order.
  Elements $(String selector) {
    final s = _Selector.parse(selector);
    final seen = <Element>{};
    return Elements([
      for (final e in _list)
        for (final m in s.matchAll(e))
          if (seen.add(m)) m,
    ]);
  }

  Element get _first => _list.isEmpty ? throw StateError('Nothing matched the selector') : _list.first;
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

  /// The `<head>` element.
  Element get head => root.children.firstWhere((e) => e.name == 'head');

  /// The `<body>` element.
  Element get body => root.children.firstWhere((e) => e.name == 'body');

  /// The document's text, _entities decoded.
  String get text => root.text;

  /// The document serialised back to HTML.
  String get outerHtml => root.outerHtml;

  @override
  String toString() => outerHtml;
}

/// Decodes `&amp;`, `&#38;`, `&#x26;` and the HTML 4 named references in [text].
String decodeEntities(String text) {
  final amp = text.indexOf('&');
  if (amp == -1) return text;
  final sb = StringBuffer(text.substring(0, amp));
  var i = amp;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c != 0x26) {
      sb.writeCharCode(c);
      i++;
      continue;
    }
    final end = _referenceEnd(text, i + 1);
    if (end == -1) {
      sb.write('&');
      i++;
      continue;
    }
    final name = text.substring(i + 1, end);
    final decoded = _reference(name);
    if (decoded == null) {
      sb.write('&');
      i++;
      continue;
    }
    sb.write(decoded);
    i = end + (end < text.length && text.codeUnitAt(end) == 0x3b ? 1 : 0);
  }
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
