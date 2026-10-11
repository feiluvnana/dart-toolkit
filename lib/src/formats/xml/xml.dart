part of '../../markup.dart';

/// A parsed XML document: the same tree and queries as [Html], with [Element.syntax]
/// [Syntax.xml], so names keep case and prefix and an empty element serialises as `<tag/>`.
///
/// ```dart
/// final feed = Xml.parse('<rss><channel><title>Hi</title></channel></rss>');
/// feed.$('//channel/title').texts;
/// ```
final class Xml implements Markup {
  /// The document element.
  @override
  final Element root;

  Xml._(this.root, {Uri? url}) {
    if (url != null) _urls[root] = url;
  }

  /// [text] parsed as XML; [url] is the document's address, which links resolve against (a
  /// feed's relative `<link>`). No document element is a [FormatException].
  static Xml parse(String text, {Uri? url}) => _parse(text, url, null);

  static Xml _parse(String text, Uri? url, String? where) => Xml._(parsedText('XML', where, text, _parseXml), url: url);

  /// The address the document was parsed with, if any.
  @override
  Uri? get url => _urls[root];

  /// Every element matching CSS [selector], in document order. Names match case-sensitively;
  /// escape a prefix's colon, `$(r'media\:content')`, or use [$x].
  @override
  Selection<Element> $(String selector) =>
      Selection._(_Selector.parse(selector, fold: false).inDocument(root), selector);

  /// The document's text: see [Node.text].
  @override
  String get text => root.text;

  /// Every text node's text as it is in the markup.
  String get rawText => root.rawText;

  /// The document as XML text, with an XML declaration.
  String encode() => '<?xml version="1.0" encoding="UTF-8"?>\n${root.markup}\n';

  @override
  String toString() => 'Xml(${url ?? root.name})';
}

/// Text read as XML.
extension XmlString on String {
  /// This text as XML, as [Xml.parse] reads it.
  Xml get xml => Xml.parse(this);
}
