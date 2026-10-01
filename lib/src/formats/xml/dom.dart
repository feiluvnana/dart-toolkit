part of '../../../formats.dart';

/// A parsed XML document: the same tree and queries as [HtmlDocument], with [Element.syntax]
/// [Syntax.xml], so names keep case and prefix and an empty element serialises as `<tag/>`.
///
/// {@category Formats}
final class XmlDocument {
  /// The document element.
  final Element root;

  XmlDocument(this.root);

  /// Parses [text] as XML. Throws [FormatException] when there is no document element.
  factory XmlDocument.parse(String text) => XmlDocument(_parseXml(text));

  /// Every element matching CSS [selector], in document order. Names match case-sensitively;
  /// escape a prefix's colon, `$(r'media\:content')`, or use [$x].
  Elements $(String selector) => Elements(_Selector.parse(selector, fold: false).inDocument(root));

  /// The nodes XPath [expression] selects from the root: `//item`, `//a/@href`,
  /// `//book[@lang='en' and price>10]/title/text()`.

  Nodes $x(String expression) => Nodes(_XPath.parse(expression).select(root));

  /// The document's text.
  String get text => root.text;

  /// The document serialised, with an XML declaration.
  String get markup => '<?xml version="1.0" encoding="UTF-8"?>${root.markup}';

  @override
  String toString() => markup;
}
