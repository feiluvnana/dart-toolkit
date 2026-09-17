import 'dart:async';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../async/isolate.dart';
import '../core/core.dart';

final Expando<HtmlDocument> _htmlMemo = Expando<HtmlDocument>('htmlMemo');
final Expando<XmlDocument> _xmlMemo = Expando<XmlDocument>('xmlMemo');
final Expando<JsonDocument> _jsonMemo = Expando<JsonDocument>('jsonMemo');

/// Format parser extensions on [http.Response].
///
/// {@category Networking}
extension ResponseExtensions on http.Response {
  /// Executes a computation [action] on this response inside a background [Isolate].
  ///
  /// Only copies essential fields (body string, status code, headers, URL) into
  /// the isolate, avoiding serialization overhead of the entire request/response object graph.
  Future<R> isolate<R>(FutureOr<R> Function(http.Response res) action) {
    final rawBody = body;
    final code = statusCode;
    final hdrs = headers;
    final reqUrl = url;

    return (() {
      final isolatedRes = http.Response(
        rawBody,
        code,
        headers: hdrs,
        request: reqUrl != null ? http.Request('GET', reqUrl) : null,
      );
      return action(isolatedRes);
    }).isolate();
  }

  /// Parses the response body as HTML and extracts data inside a background [Isolate].
  Future<R> isolateHtml<R>(FutureOr<R> Function(HtmlDocument doc) action) {
    final rawBody = body;
    return (() => action(HtmlDocument.parse(rawBody))).isolate();
  }

  /// Parses the response body as JSON and extracts data inside a background [Isolate].
  Future<R> isolateJson<R>(FutureOr<R> Function(JsonDocument doc) action) {
    final rawBody = body;
    return (() => action(JsonDocument.parse(rawBody))).isolate();
  }

  /// Parses the response body as XML and extracts data inside a background [Isolate].
  Future<R> isolateXml<R>(FutureOr<R> Function(XmlDocument doc) action) {
    final rawBody = body;
    return (() => action(XmlDocument.parse(rawBody))).isolate();
  }

  /// Parses the response body as HTML (memoized per response instance).
  HtmlDocument html() => _htmlMemo[this] ??= HtmlDocument.parse(body);

  /// Parses the response body as XML (memoized per response instance).
  XmlDocument xml() => _xmlMemo[this] ??= XmlDocument.parse(body);

  /// Parses the response body as JSON (memoized per response instance).
  JsonDocument json() => _jsonMemo[this] ??= JsonDocument.parse(body);

  /// The request URL of this response.
  Uri? get url => request?.url;
}

/// HTTP requests and format parsing on [Uri].
///
/// {@category Networking}
extension UriExtensions on Uri {
  /// Resolves [subpath] against this URI.
  Uri operator /(String subpath) => resolve(subpath);

  /// Performs an HTTP GET request to this URI.
  Future<http.Response> get({Map<String, String>? headers, http.Client? client}) async {
    final httpClient = client ?? http.Client();
    try {
      return await httpClient.get(this, headers: headers);
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Performs an HTTP POST request to this URI.
  Future<http.Response> post({Map<String, String>? headers, Object? body, http.Client? client}) async {
    final httpClient = client ?? http.Client();
    try {
      return await httpClient.post(this, headers: headers, body: body);
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Fetches this URI and parses the response body as HTML.
  Future<HtmlDocument> html({Map<String, String>? headers, http.Client? client}) async {
    final res = await get(headers: headers, client: client);
    return res.html();
  }

  /// Fetches this URI and parses the response body as JSON.
  Future<JsonDocument> json({Map<String, String>? headers, http.Client? client}) async {
    final res = await get(headers: headers, client: client);
    return res.json();
  }

  /// Fetches this URI and parses the response body as XML.
  Future<XmlDocument> xml({Map<String, String>? headers, http.Client? client}) async {
    final res = await get(headers: headers, client: client);
    return res.xml();
  }
}
