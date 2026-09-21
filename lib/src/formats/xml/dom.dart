part of '../../../formats.dart';

/// A node in a parsed XML tree: an [XmlElement], an [XmlText], or an [XmlAttribute] selected
/// by an XPath `@` step.
///
/// {@category Formats}
sealed class XmlNode {
  /// The element containing this node, or `null` at the root.
  XmlElement? parent;

  /// The string value: an element's descendant text, a text node's data, an attribute's value.
  String get text;

  /// This node serialised.
  String get outerXml;

  @override
  String toString() => outerXml;
}

/// Character data, entities decoded; CDATA sections are text too.
///
/// {@category Formats}
final class XmlText extends XmlNode {
  final String data;

  XmlText(this.data);

  @override
  String get text => data;

  @override
  String get outerXml => _escapeXml(data);
}

/// An attribute, as an XPath `@name` step selects it.
///
/// {@category Formats}
final class XmlAttribute extends XmlNode {
  /// The qualified name, prefix included.
  final String name;
  final String value;

  XmlAttribute(this.name, this.value, XmlElement owner) {
    parent = owner;
  }

  @override
  String get text => value;

  @override
  String get outerXml => '$name="${_escapeAttr(value)}"';

  /// Two of these are the same attribute when they name the same thing on the same element;
  /// see [Attribute.operator ==].
  @override
  bool operator ==(Object other) => other is XmlAttribute && other.name == name && identical(other.parent, parent);

  @override
  int get hashCode => Object.hash(identityHashCode(parent), name);
}

/// An element: a qualified [name], its [attributes], and the [children] inside it.
///
/// {@category Formats}
final class XmlElement extends XmlNode {
  /// The qualified name as written: `item`, `media:content`.
  final String name;

  /// Attributes by qualified name, values decoded, in document order.
  final Map<String, String> attributes;

  /// Child nodes in document order: elements and text.
  final List<XmlNode> children = [];

  XmlElement(this.name, [Map<String, String>? attributes]) : attributes = attributes ?? {};

  /// The name without its prefix: `content` for `media:content`.
  String get local => name.contains(':') ? name.substring(name.indexOf(':') + 1) : name;

  /// The namespace prefix, or `null`.
  String? get prefix => name.contains(':') ? name.substring(0, name.indexOf(':')) : null;

  /// Child elements, skipping text.
  Iterable<XmlElement> get elements => children.whereType<XmlElement>();

  /// Attribute [name] on this element, or `null`.
  String? attr(String name) => attributes[name];

  /// The nodes matching XPath [expression], evaluated with this element as the context.
  XmlNodes $(String expression) => XmlNodes(XPath.parse(expression).select(this, _xmlTree));

  @override
  String get text {
    final sb = StringBuffer();
    void walk(XmlElement e) {
      for (final n in e.children) {
        n is XmlText ? sb.write(n.data) : walk(n as XmlElement);
      }
    }

    walk(this);
    return sb.toString();
  }

  /// The children serialised, without this element's own tags.
  String get innerXml => children.map((n) => n.outerXml).join();

  @override
  String get outerXml {
    final sb = StringBuffer('<$name');
    for (final MapEntry(:key, :value) in attributes.entries) {
      sb.write(' $key="${_escapeAttr(value)}"');
    }
    if (children.isEmpty) return '$sb/>';
    sb
      ..write('>')
      ..write(innerXml)
      ..write('</$name>');
    return sb.toString();
  }

  /// The next element sibling, or `null`.
  XmlElement? get nextElement => _sibling(1);

  /// The previous element sibling, or `null`.
  XmlElement? get previousElement => _sibling(-1);

  XmlElement? _sibling(int step) {
    final siblings = parent?.children;
    if (siblings == null) return null;
    for (var i = siblings.indexOf(this) + step; i >= 0 && i < siblings.length; i += step) {
      if (siblings[i] case final XmlElement e) return e;
    }
    return null;
  }
}

/// The nodes an XPath query selected, in document order. A [List], with the first node's
/// [text] and [attr] one hop closer: `doc.$('//item/title').text`.
///
/// {@category Formats}
extension type XmlNodes(List<XmlNode> _list) implements List<XmlNode> {
  /// The first node's string value. Throws [StateError] when nothing matched.
  String get text => _list.isEmpty ? throw StateError('Nothing matched the XPath expression') : _list.first.text;

  /// Attribute [name] on the first element, or `null` when absent or nothing matched.
  String? attr(String name) => _list.whereType<XmlElement>().firstOrNull?.attributes[name];

  /// Only the elements among the selected nodes.
  Iterable<XmlElement> get elements => _list.whereType<XmlElement>();

  /// Every node's string value.
  List<String> get texts => [for (final n in _list) n.text];

  /// Evaluates [expression] with each selected element as context, each result once.
  XmlNodes $(String expression) {
    final x = XPath.parse(expression);
    final seen = <XmlNode>{};
    return XmlNodes([
      for (final e in elements)
        for (final n in x.select(e, _xmlTree))
          if (seen.add(n)) n,
    ]);
  }
}

/// A parsed XML document with XPath selectors.
///
/// {@category Formats}
final class XmlDocument {
  /// The document element.
  final XmlElement root;

  XmlDocument(this.root);

  /// Parses [text] as XML. Throws [FormatException] when there is no document element.
  factory XmlDocument.parse(String text) => XmlDocument(_parseXml(text));

  /// The nodes matching XPath [expression], evaluated from the document root: `//item`,
  /// `/rss/channel/item[1]/title`, `//a/@href`, `//book[@lang='en' and price>10]/title/text()`.
  XmlNodes $(String expression) => XmlNodes(XPath.parse(expression).select(root, _xmlTree));

  /// The document's text.
  String get text => root.text;

  /// The document serialised, with an XML declaration.
  String get outerXml => '<?xml version="1.0" encoding="UTF-8"?>${root.outerXml}';

  @override
  String toString() => outerXml;
}

/// Stands for the document above the root element, so `/rss` and `//item` have somewhere
/// to start.
final class _XmlDocumentNode extends XmlNode {
  final XmlElement root;
  _XmlDocumentNode(this.root);
  @override
  String get text => root.text;
  @override
  String get outerXml => root.outerXml;
}

final class _XmlTree implements XPathTree<XmlNode> {
  const _XmlTree();

  @override
  XPathKind kind(XmlNode n) => switch (n) {
    XmlElement() => XPathKind.element,
    XmlText() => XPathKind.text,
    XmlAttribute() => XPathKind.attribute,
    _XmlDocumentNode() => XPathKind.document,
  };

  @override
  XmlNode? parent(XmlNode n) => switch (n) {
    _XmlDocumentNode() => null,
    XmlElement(parent: null) => _XmlDocumentNode(n),
    _ => n.parent,
  };

  @override
  List<XmlNode> children(XmlNode n) => switch (n) {
    XmlElement() => n.children,
    _XmlDocumentNode() => [n.root],
    _ => const [],
  };

  @override
  String name(XmlNode n) => switch (n) {
    XmlElement() => n.name,
    XmlAttribute() => n.name,
    _ => '',
  };

  @override
  Map<String, String>? attributes(XmlNode n) => n is XmlElement ? n.attributes : null;

  @override
  String text(XmlNode n) => n.text;

  @override
  XmlNode attribute(XmlNode owner, String name, String value) => XmlAttribute(name, value, owner as XmlElement);

  @override
  XmlNode document(XmlNode root) => root is _XmlDocumentNode ? root : _XmlDocumentNode(root as XmlElement);
}

const _xmlTree = _XmlTree();

String _escapeXml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
String _escapeAttr(String s) => _escapeXml(s).replaceAll('"', '&quot;');

/// {@category Formats}
extension StringXmlExtensions on String {
  /// This string parsed as XML.
  XmlDocument get xml => XmlDocument.parse(this);
}
