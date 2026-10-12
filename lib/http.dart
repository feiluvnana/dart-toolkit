/// Ultra-minimal zero-dependency HTTP client (SDK libs only).
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
/// - `Http.get()` / `Http.post()` perform a request and return a [Response].
/// - [Response] supports only `status()`, `text()`, `header()`.
/// Non-2xx statuses are still a [Response] (never null); only network
/// failures throw. Everything else is private.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Entry point: minimal GET/POST. Throws only on network failures.
abstract final class Http {
  /// GET [url] with optional [headers] and [timeout].
  static Future<Response> get(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('GET', url, headers: headers, timeout: timeout);

  /// POST [url] with optional text [body], [headers], and [timeout].
  static Future<Response> post(
    String url, {
    String? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('POST', url, body: body, headers: headers, timeout: timeout);
}

/// An HTTP response. Only `status()`, `text()`, `header()`.
final class Response {
  Response._(this._status, Map<String, String> headers, this._text)
      : _headers = Map.unmodifiable(headers);

  final int _status;
  final Map<String, String> _headers;
  final String _text;

  /// HTTP status code (e.g. 200, 404).
  int status() => _status;

  /// Response body decoded as text (UTF-8, malformed sequences tolerated).
  String text() => _text;

  /// Response header [name] (case-insensitive) or `null` if absent.
  /// Multiple values are joined with `', '`.
  String? header(String name) => _headers[name.toLowerCase()];
}

Future<Response> _send(
  String method,
  String url, {
  String? body,
  Map<String, String>? headers,
  Duration? timeout,
}) {
  Future<Response> run() async {
    // Fresh client per request: no pooling, no shared state to leak.
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      headers?.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close();
      final buf = BytesBuilder();
      await for (final chunk in response) {
        buf.add(chunk);
      }
      const decoder = Utf8Decoder(allowMalformed: true);
      final text = decoder.convert(buf.toBytes());
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });
      return Response._(response.statusCode, responseHeaders, text);
    } finally {
      client.close(force: true);
    }
  }

  final future = run();
  return timeout == null ? future : future.timeout(timeout);
}
