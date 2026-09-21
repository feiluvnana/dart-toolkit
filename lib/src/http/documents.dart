part of '../../http.dart';

final Expando<HtmlDocument> _htmlMemo = Expando<HtmlDocument>('htmlMemo');
final Expando<XmlDocument> _xmlMemo = Expando<XmlDocument>('xmlMemo');

/// HTML and XML on [Response]; `json` is a member, being the format `http` itself speaks.
///
/// {@category Networking}
extension ResponseDocumentExtensions on Response {
  /// The body parsed as HTML, once per response instance.
  HtmlDocument get html => _htmlMemo[this] ??= HtmlDocument.parse(text);

  /// The body parsed as XML, once per response instance.
  XmlDocument get xml => _xmlMemo[this] ??= XmlDocument.parse(text);
}

/// Fetch-and-parse on [Uri]; each throws [HttpException] unless the status is 2xx — an error
/// page parses fine and then matches nothing. Use `get` with `isOk` to handle it yourself.
///
/// {@category Networking}
extension UriDocumentExtensions on Uri {
  /// Fetches this URI and parses the body as HTML.
  Future<HtmlDocument> html({Map<String, String>? headers}) async => (await fetch(headers: headers)).html;

  /// Fetches this URI and parses the body as XML.
  Future<XmlDocument> xml({Map<String, String>? headers}) async => (await fetch(headers: headers)).xml;
}
