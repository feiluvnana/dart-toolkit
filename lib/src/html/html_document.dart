/// The HTML bridges on `http.Response`, `Uri` and `String`; the tree itself is in `dom.dart`.
library;

import 'package:http/http.dart' as http;

import '../http/fetch.dart';
import '../http/response.dart';
import 'dom.dart';

export 'dom.dart' show Element, Elements, HtmlDocument, Node, Text, decodeEntities;

final Expando<HtmlDocument> _htmlMemo = Expando<HtmlDocument>('htmlMemo');

/// HTML parsing on [http.Response].
///
/// {@category Formats}
extension ResponseHtmlExtensions on http.Response {
  /// The body parsed as HTML, once per response instance.
  HtmlDocument get html => _htmlMemo[this] ??= HtmlDocument.parse(text);
}

/// HTML fetching on [Uri].
///
/// {@category Formats}
extension UriHtmlExtensions on Uri {
  /// Fetches this URI and parses the response body as HTML.
  ///
  /// Throws [HttpException] unless the status is 2xx — an error page parses fine and
  /// then matches nothing. Use `get` with `isOk` to handle it yourself.
  Future<HtmlDocument> html({Map<String, String>? headers, http.Client? client}) async =>
      (await fetchOk(this, headers, client)).html;
}

/// Parsing on [String].
///
/// {@category Formats}
extension StringHtmlExtensions on String {
  /// This string parsed as HTML.
  HtmlDocument get html => HtmlDocument.parse(this);
}
