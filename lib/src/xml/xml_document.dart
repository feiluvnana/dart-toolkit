part of '../../xml.dart';

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
  /// Fetches this URI and parses the response body as XML; see `fetch`.
  Future<XmlDocument> xml({Map<String, String>? headers, http.Client? client}) async =>
      (await fetch(headers: headers, client: client)).xml;
}

/// Parsing on [String].
///
/// {@category Formats}
extension StringXmlExtensions on String {
  /// This string parsed as XML.
  XmlDocument get xml => XmlDocument.parse(this);
}
