part of '../../http.dart';

/// HTML and XML on [Response]; `json` is a member, being the format `http` itself speaks.
///
/// {@category Networking}
extension ResponseDocumentExtensions on Response {
  /// The body parsed as HTML, once per response instance, with [url] as its address.
  HtmlDocument get html => _html ??= HtmlDocument.parse(text, url: url ?? request?.url);

  /// The body parsed as XML, once per response instance.
  XmlDocument get xml => _xml ??= XmlDocument.parse(text);
}
