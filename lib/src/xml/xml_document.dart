import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:xml/xpath.dart';

import '../http/fetch.dart';
import '../http/response.dart';

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

  /// Finds all nodes matching XPath [query].
  // ignore: experimental_member_use
  Iterable<xml.XmlNode> $(String query) => raw.xpath(query);
}

final Expando<XmlDocument> _xmlMemo = Expando<XmlDocument>('xmlMemo');

/// XML parsing on [http.Response].
///
/// {@category Formats}
extension ResponseXmlExtensions on http.Response {
  /// The body parsed as XML, once per response instance.
  XmlDocument get xml => _xmlMemo[this] ??= XmlDocument.parse(text);
}

/// XML fetching on [Uri].
///
/// {@category Formats}
extension UriXmlExtensions on Uri {
  /// Fetches this URI and parses the response body as XML.
  ///
  /// Throws [HttpException] unless the status is 2xx.
  Future<XmlDocument> xml({Map<String, String>? headers, http.Client? client}) async =>
      (await fetchOk(this, headers, client)).xml;
}
