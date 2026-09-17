import 'package:xml/xml.dart' as xml;
import 'package:xml/xpath.dart';

/// A parsed XML document with XPath selector support.
///
/// {@category Formats}
class XmlDocument {
  /// The underlying parsed XML document.
  final xml.XmlDocument raw;

  /// Creates an [XmlDocument] wrapping an existing [raw] document.
  XmlDocument(this.raw);

  /// Parses [text] as XML.
  factory XmlDocument.parse(String text) => XmlDocument(xml.XmlDocument.parse(text));

  /// XPath selector query.
  // ignore: experimental_member_use
  Iterable<xml.XmlNode> $xpath(String query) => raw.xpath(query);
}
