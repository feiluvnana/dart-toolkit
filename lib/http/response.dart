import 'package:http/http.dart' as http;

import '../core/core.dart';

/// Barebone HTTP extension on [http.Response] providing format parser methods.
extension HttpToolkitResponse on http.Response {
  /// Parses the response body as HTML.
  HtmlDocument html() => HtmlDocument.parse(body);

  /// Parses the response body as XML.
  XmlDocument xml() => XmlDocument.parse(body);

  /// Parses the response body as JSON.
  JsonDocument json() => JsonDocument.parse(body);
}

/// Convenience format getters on [http.Client].
extension HttpClientFormatExtensions on http.Client {
  /// Fetches [url] and parses the response body as HTML.
  Future<HtmlDocument> html(Uri url, {Map<String, String>? headers}) async {
    final res = await get(url, headers: headers);
    return res.html();
  }

  /// Fetches [url] and parses the response body as JSON.
  Future<JsonDocument> json(Uri url, {Map<String, String>? headers}) async {
    final res = await get(url, headers: headers);
    return res.json();
  }

  /// Fetches [url] and parses the response body as XML.
  Future<XmlDocument> xml(Uri url, {Map<String, String>? headers}) async {
    final res = await get(url, headers: headers);
    return res.xml();
  }
}

/// Convenience operator on [Uri] for path resolution.
extension UriOperatorExtension on Uri {
  /// Resolves [subpath] against this URI.
  Uri operator /(String subpath) => resolve(subpath);
}
