/// Ultra-minimal HTTP client. Thin facade over `package:http`:
/// same syntax, the engine underneath.
///
/// ```dart
/// final res = await Http.get('https://example.com');
/// res.status();                  // e.g. 200
/// res.text();                    // response body as text
/// res.header('content-type');    // header value or null (case-insensitive)
/// await Http.post('https://example.com/form', body: 'a=1&b=2');
/// ```
///
/// Public surface is exactly: [Http], [Response].
/// - `Http.get/head/delete/options/post/put/patch()` return a [Response].
/// - [Response] supports only `status()`, `text()`, `header()`.
/// Non-2xx statuses are still a [Response] (never null); only network
/// failures throw. Everything else is private.
library;

import 'package:http/http.dart' as http;

/// Entry point: one method per HTTP verb. Throws only on network failures.
abstract final class Http {
  /// GET [url] with optional [headers].
  static Future<Response> get(
    String url, {
    Map<String, String>? headers,
  }) =>
      _send('GET', url, headers: headers);

  /// HEAD [url] with optional [headers].
  static Future<Response> head(
    String url, {
    Map<String, String>? headers,
  }) =>
      _send('HEAD', url, headers: headers);

  /// DELETE [url] with optional [headers].
  static Future<Response> delete(
    String url, {
    Map<String, String>? headers,
  }) =>
      _send('DELETE', url, headers: headers);

  /// OPTIONS [url] with optional [headers].
  static Future<Response> options(
    String url, {
    Map<String, String>? headers,
  }) =>
      _send('OPTIONS', url, headers: headers);

  /// POST [url] with optional text [body] and [headers].
  static Future<Response> post(
    String url, {
    String? body,
    Map<String, String>? headers,
  }) =>
      _send('POST', url, body: body, headers: headers);

  /// PUT [url] with optional text [body] and [headers].
  static Future<Response> put(
    String url, {
    String? body,
    Map<String, String>? headers,
  }) =>
      _send('PUT', url, body: body, headers: headers);

  /// PATCH [url] with optional text [body] and [headers].
  static Future<Response> patch(
    String url, {
    String? body,
    Map<String, String>? headers,
  }) =>
      _send('PATCH', url, body: body, headers: headers);
}

/// An HTTP response. Only `status()`, `text()`, `header()`.
final class Response {
  Response._(this._inner);

  final http.Response _inner;

  /// HTTP status code (e.g. 200, 404).
  int status() => _inner.statusCode;

  /// Response body as text.
  String text() => _inner.body;

  /// Response header [name] (case-insensitive) or `null` if absent.
  String? header(String name) {
    final key = name.toLowerCase();
    for (final entry in _inner.headers.entries) {
      if (entry.key.toLowerCase() == key) return entry.value;
    }
    return null;
  }
}

Future<Response> _send(
  String method,
  String url, {
  String? body,
  Map<String, String>? headers,
}) async {
  // Fresh client per request: no pooling, no shared state to leak.
  final client = http.Client();
  try {
    final request = http.Request(method, Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;
    final streamed = await client.send(request);
    return Response._(await http.Response.fromStream(streamed));
  } finally {
    client.close();
  }
}
