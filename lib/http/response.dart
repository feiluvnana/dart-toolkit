import 'dart:async';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../async/isolate.dart';
import '../core/core.dart';
import '../fs/path.dart';

/// Format parser extensions on [http.Response].
extension HttpToolkitResponse on http.Response {
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

  /// Parses the response body as HTML.
  HtmlDocument html() => HtmlDocument.parse(body);

  /// Parses the response body as XML.
  XmlDocument xml() => XmlDocument.parse(body);

  /// Parses the response body as JSON.
  JsonDocument json() => JsonDocument.parse(body);

  /// Direct CSS selector query on the HTML document parsed from this response body.
  List<Element> $(String selector) => html().$(selector);

  /// Direct XPath query on the HTML document parsed from this response body.
  List<Element> $xpath(String query) => html().$xpath(query);

  /// The request URL of this response.
  Uri? get url => request?.url;
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

  /// Fetches [url] and executes [action] on a background [Isolate].
  Future<R> isolate<R>(Uri url, FutureOr<R> Function(http.Response res) action, {Map<String, String>? headers}) async {
    final res = await get(url, headers: headers);
    return res.isolate(action);
  }

  /// Fetches [url] and parses HTML inside a background [Isolate].
  Future<R> isolateHtml<R>(
    Uri url,
    FutureOr<R> Function(HtmlDocument doc) action, {
    Map<String, String>? headers,
  }) async {
    final res = await get(url, headers: headers);
    return res.isolateHtml(action);
  }

  /// Fetches [url] and parses JSON inside a background [Isolate].
  Future<R> isolateJson<R>(
    Uri url,
    FutureOr<R> Function(JsonDocument doc) action, {
    Map<String, String>? headers,
  }) async {
    final res = await get(url, headers: headers);
    return res.isolateJson(action);
  }

  /// Fetches [url] and parses XML inside a background [Isolate].
  Future<R> isolateXml<R>(Uri url, FutureOr<R> Function(XmlDocument doc) action, {Map<String, String>? headers}) async {
    final res = await get(url, headers: headers);
    return res.isolateXml(action);
  }
}

/// Convenience HTTP request, format parsing, and path operators on [Uri].
extension UriHttpExtensions on Uri {
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

  /// Fetches this URI and executes [action] on a background [Isolate].
  Future<R> isolate<R>(
    FutureOr<R> Function(http.Response res) action, {
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final res = await get(headers: headers, client: client);
    return res.isolate(action);
  }

  /// Fetches this URI and parses HTML inside a background [Isolate].
  Future<R> isolateHtml<R>(
    FutureOr<R> Function(HtmlDocument doc) action, {
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final res = await get(headers: headers, client: client);
    return res.isolateHtml(action);
  }

  /// Fetches this URI and parses JSON inside a background [Isolate].
  Future<R> isolateJson<R>(
    FutureOr<R> Function(JsonDocument doc) action, {
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final res = await get(headers: headers, client: client);
    return res.isolateJson(action);
  }

  /// Fetches this URI and parses XML inside a background [Isolate].
  Future<R> isolateXml<R>(
    FutureOr<R> Function(XmlDocument doc) action, {
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final res = await get(headers: headers, client: client);
    return res.isolateXml(action);
  }

  /// Downloads content from this URI to [destination] path, streaming [DownloadProgress] updates.
  Stream<DownloadProgress> download(Path destination, {http.Client? client, bool overwrite = false}) =>
      destination.download(this, client: client, overwrite: overwrite);
}
