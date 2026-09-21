part of '../../../formats.dart';

/// A parsed XML document.
///
/// The tree is the package's one markup tree — [Element], [Text], [Attribute] and [Node] —
/// with [Element.syntax] set to [Syntax.xml], so names keep their case and their prefixes
/// and an empty element serialises as `<tag/>`.
///
/// Queries read the same as they do on [HtmlDocument]: `$` is CSS and `$x` is XPath.
///
/// {@category Formats}
final class XmlDocument {
  /// The document element.
  final Element root;

  XmlDocument(this.root);

  /// Parses [text] as XML. Throws [FormatException] when there is no document element.
  factory XmlDocument.parse(String text) => XmlDocument(_parseXml(text));

  /// Every element matching CSS [selector], in document order.
  ///
  /// XML names are matched as written, not folded: `$('item')` and `$('Item')` are
  /// different elements. A prefixed name is not a CSS identifier, so `media:content`
  /// needs [$x].
  Elements $(String selector) => Elements(_Selector.parse(selector, fold: false).matchAll(root, includeSelf: true));

  /// The nodes matching XPath [expression], evaluated from the document root: `//item`,
  /// `/rss/channel/item[1]/title`, `//a/@href`, `//book[@lang='en' and price>10]/title/text()`.
  Nodes $x(String expression) => Nodes(XPath.parse(expression).select(root));

  /// The document's text.
  String get text => root.text;

  /// The document serialised, with an XML declaration.
  String get outerXml => '<?xml version="1.0" encoding="UTF-8"?>${root.markup}';

  @override
  String toString() => outerXml;
}

/// {@category Formats}
extension StringXmlExtensions on String {
  /// This string parsed as XML.
  XmlDocument get xml => XmlDocument.parse(this);
}
