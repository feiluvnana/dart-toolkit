import 'dart:async';

import 'package:http/http.dart' as http;

import '../async/isolate.dart';
import '../core/json_document.dart';
import 'fetch.dart';
import 'session.dart';

final Expando<String> _bodyMemo = Expando<String>('bodyMemo');
final Expando<JsonDocument> _jsonMemo = Expando<JsonDocument>('jsonMemo');

/// Body access and JSON parsing on [http.Response].
///
/// `html()` and `xml()` live in `html/html.dart` and `xml/xml.dart`, with the parsers
/// they need, so a program that never parses them never compiles them.
///
/// {@category Networking}
extension ResponseExtensions on http.Response {
  /// Runs [action] on a copy of this response inside a background [Isolate].
  ///
  /// Copies the body, status, headers and URL — not the request graph. Extract data in
  /// [action]; returning a parsed document copies it all back and buys nothing.
  Future<R> isolate<R>(FutureOr<R> Function(http.Response res) action) {
    final rawBody = text;
    final code = statusCode;
    final hdrs = headers;
    final req = request;
    final method = req?.method ?? 'GET';
    final reqUrl = req?.url;

    return (() {
      final copy = http.Response(
        rawBody,
        code,
        headers: hdrs,
        request: reqUrl != null ? http.Request(method, reqUrl) : null,
      );
      return action(copy);
    }).isolate();
  }

  /// The decoded body, decoded once per response instance.
  ///
  /// `package:http` re-decodes `bodyBytes` on every `body` access; this does not.
  String get text => _bodyMemo[this] ??= body;

  /// The body parsed as JSON, once per response instance.
  JsonDocument get json => _jsonMemo[this] ??= JsonDocument.parse(text);

  /// The request URL of this response.
  Uri? get url => request?.url;

  /// Whether the status code is 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// HTTP requests and JSON on [Uri].
///
/// {@category Networking}
extension UriExtensions on Uri {
  /// Appends [part] as a path segment, treating this URI as a directory.
  ///
  /// `'https://x.com/api'.url / 'users'` is `https://x.com/api/users`. An absolute or
  /// `..` [part] still resolves as an href would.
  Uri operator /(String part) => (path.endsWith('/') ? this : replace(path: '$path/')).resolve(part);

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

  /// Fetches this URI and parses the response body as JSON.
  ///
  /// Throws [HttpException] unless the status is 2xx. Use [get] with
  /// [ResponseExtensions.isOk] to handle a failure yourself.
  Future<JsonDocument> json({Map<String, String>? headers, http.Client? client}) async =>
      (await fetchOk(this, headers, client)).json;
}
