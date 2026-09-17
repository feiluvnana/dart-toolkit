import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../async/isolate.dart';
import '../html/html_document.dart';
import '../core/json_document.dart';
import '../xml/xml_document.dart';
import 'session.dart';

final Expando<String> _bodyMemo = Expando<String>('bodyMemo');
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
  ///
  /// Extract data in [action]; returning the parsed document copies the whole object
  /// graph back and buys nothing over parsing here.
  Future<R> isolate<R>(FutureOr<R> Function(http.Response res) action) {
    final rawBody = text;
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
    final rawBody = text;
    return (() => action(HtmlDocument.parse(rawBody))).isolate();
  }

  /// Parses the response body as JSON and extracts data inside a background [Isolate].
  Future<R> isolateJson<R>(FutureOr<R> Function(JsonDocument doc) action) {
    final rawBody = text;
    return (() => action(JsonDocument.parse(rawBody))).isolate();
  }

  /// Parses the response body as XML and extracts data inside a background [Isolate].
  Future<R> isolateXml<R>(FutureOr<R> Function(XmlDocument doc) action) {
    final rawBody = text;
    return (() => action(XmlDocument.parse(rawBody))).isolate();
  }

  /// The decoded body, decoded once per response instance.
  ///
  /// `package:http` re-decodes `bodyBytes` on every `body` access; this does not.
  String get text => _bodyMemo[this] ??= body;

  /// Parses the response body as HTML (memoized per response instance).
  HtmlDocument html() => _htmlMemo[this] ??= HtmlDocument.parse(text);

  /// Parses the response body as XML (memoized per response instance).
  XmlDocument xml() => _xmlMemo[this] ??= XmlDocument.parse(text);

  /// Parses the response body as JSON (memoized per response instance).
  JsonDocument json() => _jsonMemo[this] ??= JsonDocument.parse(text);

  /// The request URL of this response.
  Uri? get url => request?.url;

  /// Whether the status code is 2xx.
  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// HTTP requests and format parsing on [Uri].
///
/// {@category Networking}
extension UriExtensions on Uri {
  /// Resolves [subpath] against this URI.
  Uri operator /(String subpath) => resolve(subpath);

  /// Performs an HTTP GET request to this URI.
  Future<http.Response> get({Map<String, String>? headers, http.Client? client}) async {
    final lease = clientFor(client);
    try {
      return await lease.client.get(this, headers: headers);
    } finally {
      lease.close();
    }
  }

  /// Performs an HTTP POST request to this URI.
  Future<http.Response> post({Map<String, String>? headers, Object? body, http.Client? client}) async {
    final lease = clientFor(client);
    try {
      return await lease.client.post(this, headers: headers, body: body);
    } finally {
      lease.close();
    }
  }

  /// Fetches this URI and parses the response body as HTML.
  ///
  /// Throws [HttpException] unless the status is 2xx — an error page parses fine and
  /// then matches nothing. Use [get] with [ResponseExtensions.ok] to handle it yourself.
  Future<HtmlDocument> html({Map<String, String>? headers, http.Client? client}) async =>
      (await _fetched(headers, client)).html();

  /// Fetches this URI and parses the response body as JSON.
  ///
  /// Throws [HttpException] unless the status is 2xx.
  Future<JsonDocument> json({Map<String, String>? headers, http.Client? client}) async =>
      (await _fetched(headers, client)).json();

  /// Fetches this URI and parses the response body as XML.
  ///
  /// Throws [HttpException] unless the status is 2xx.
  Future<XmlDocument> xml({Map<String, String>? headers, http.Client? client}) async =>
      (await _fetched(headers, client)).xml();

  Future<http.Response> _fetched(Map<String, String>? headers, http.Client? client) async {
    final res = await get(headers: headers, client: client);
    if (!res.ok) throw HttpException('GET failed with status ${res.statusCode}', uri: this);
    return res;
  }
}
