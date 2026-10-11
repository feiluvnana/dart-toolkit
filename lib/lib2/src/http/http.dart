import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/traits.dart';
import '../json/json.dart';

/// A buffered HTTP response.
final class Resp implements Closer {
  /// The status code, e.g. `200`.
  final int status;

  /// Response headers, lower-cased names.
  final Map<String, String> headers;

  /// The response body.
  final Uint8List body;

  /// The final URL after redirects.
  final String url;

  Resp(this.status, this.headers, this.body, this.url);

  /// Whether the status is 2xx.
  bool get ok => status >= 200 && status < 300;

  /// Whether the status is 4xx.
  bool get isClientError => status >= 400 && status < 500;

  /// Whether the status is 5xx.
  bool get isServerError => status >= 500;

  /// The body decoded as UTF-8.
  String text() => utf8.decode(body);

  /// The body parsed as JSON.
  dynamic json() => Json.parse(text());

  /// The raw body bytes.
  Uint8List get bytes => body;

  /// One header, or `null`.
  String? header(String name) => headers[name.toLowerCase()];

  @override
  Future<void> close() async {}
}

/// A tiny HTTP/1.1 client on `dart:io`: `Http.get`, [post], [put], [delete], [head].
///
/// ```dart
/// final res = await Http.get('https://api.example.com/data');
/// if (res.ok) print(res.json()['value']);
/// ```
abstract final class Http {
  /// Sends a GET to [url].
  static Future<Resp> get(String url, {Map<String, String>? headers, Duration? timeout}) =>
      _send('GET', url, headers: headers, timeout: timeout);

  /// Sends a HEAD to [url].
  static Future<Resp> head(String url, {Map<String, String>? headers, Duration? timeout}) =>
      _send('HEAD', url, headers: headers, timeout: timeout);

  /// Sends a POST; [json] is serialised and sent as JSON, or [body] is sent verbatim.
  static Future<Resp> post(String url, {Object? json, Object? body, Map<String, String>? headers, Duration? timeout}) =>
      _send('POST', url, json: json, body: body, headers: headers, timeout: timeout);

  /// Sends a PUT.
  static Future<Resp> put(String url, {Object? json, Object? body, Map<String, String>? headers, Duration? timeout}) =>
      _send('PUT', url, json: json, body: body, headers: headers, timeout: timeout);

  /// Sends a PATCH.
  static Future<Resp> patch(
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _send('PATCH', url, json: json, body: body, headers: headers, timeout: timeout);

  /// Sends a DELETE.
  static Future<Resp> delete(
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _send('DELETE', url, json: json, body: body, headers: headers, timeout: timeout);

  /// Streams [url] into the [Writer] [dst] (e.g. a `File`), returning the bytes copied.
  static Future<int> download(String url, Writer dst, {Map<String, String>? headers}) async {
    final client = io.HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers?.forEach(request.headers.set);
      final response = await request.close();
      var total = 0;
      final chunk = Uint8List(64 * 1024);
      await for (final data in response) {
        chunk.setRange(0, data.length, data);
        await dst.write(Uint8List.sublistView(chunk, 0, data.length));
        total += data.length;
      }
      await dst.flush();
      return total;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Resp> _send(
    String method,
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final client = io.HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      headers?.forEach(request.headers.set);
      Object? payload = body;
      if (json != null) {
        request.headers.contentType = io.ContentType.json;
        payload = Json.dump(json);
      }
      if (payload != null) {
        request.write(payload is String ? payload : payload.toString());
      }
      final response = timeout == null ? await request.close() : await request.close().timeout(timeout);
      final bytes = await _collect(response);
      final respHeaders = <String, String>{};
      response.headers.forEach((name, values) => respHeaders[name.toLowerCase()] = values.join(', '));
      return Resp(
        response.statusCode,
        respHeaders,
        bytes,
        response.redirects.isEmpty ? url : response.redirects.last.location.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List> _collect(io.HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final data in response) {
      builder.add(data);
    }
    return builder.takeBytes();
  }
}
