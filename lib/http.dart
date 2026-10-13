/// Minimal HTTP client. Thin facade over `package:http`.
///
/// ```dart
/// final user = await Http.get('https://api.example.com/me',
///     headers: {'authorization': token}).json();
/// await (Http.get(url) > Fs.file('page.html'));
/// await Http.put('https://cdn.example.com/d.iso', body: Fs.file('d.iso'));
/// ```
///
/// Public surface is exactly: [Http], [Response].
/// - `Http.get/head/delete/options/post/put/patch()` return a [Response].
/// - [Response] supports `status` `header` `url` (plus [Reader]/[Closeable]).
/// A non-2xx status is still a [Response]; only network failures and
/// timeouts throw. Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'core.dart';
export 'core.dart';

/// Entry point: one method per HTTP verb. A verb completes when the headers
/// arrive; the body streams as a [Reader]. Redirects are followed.
abstract final class Http {
  /// Default bound on the wait for the headers, then on any stall streaming.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// GET [url] with optional [headers] and [timeout].
  static Future<Response> get(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('GET', url, headers: headers, timeout: timeout);

  /// HEAD [url] with optional [headers] and [timeout].
  static Future<Response> head(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('HEAD', url, headers: headers, timeout: timeout);

  /// DELETE [url] with optional [headers] and [timeout].
  static Future<Response> delete(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('DELETE', url, headers: headers, timeout: timeout);

  /// OPTIONS [url] with optional [headers] and [timeout].
  static Future<Response> options(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('OPTIONS', url, headers: headers, timeout: timeout);

  /// POST [url] with a [body] (`String` as UTF-8, `List<int>` as is, or a
  /// [Reader] streamed, chunked unless a `content-length` header is given).
  static Future<Response> post(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('POST', url, body: body, headers: headers, timeout: timeout);

  /// PUT [url] with a [body] (same as [post]).
  static Future<Response> put(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('PUT', url, body: body, headers: headers, timeout: timeout);

  /// PATCH [url] with a [body] (same as [post]).
  static Future<Response> patch(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _send('PATCH', url, body: body, headers: headers, timeout: timeout);
}

/// An HTTP response: a [Reader] of the body, streamed from the socket.
final class Response with Reader implements Closeable {
  Response._(this._resp, this._client, this._timeout);

  final http.StreamedResponse _resp;
  final http.Client _client;
  final Duration _timeout;

  List<int>? _cached;
  var _streaming = false;
  var _closed = false;
  var _done = false;

  /// HTTP status code (e.g. 200, 404). Sync from when the headers arrive.
  int status() => _resp.statusCode;

  /// Response header [name] (case-insensitive) or `null` if absent.
  String? header(String name) {
    final key = name.toLowerCase();
    for (final entry in _resp.headers.entries) {
      if (entry.key.toLowerCase() == key) return entry.value;
    }
    return null;
  }

  /// The final URL, after redirects.
  String url() {
    final r = _resp;
    Uri? finalUri;
    if (r case http.BaseResponseWithUrl(:final url)) {
      finalUri = url;
    }
    final base = r.request?.url;
    if (finalUri == null) return base?.toString() ?? '';
    // The engine reports the last `Location` verbatim, which is often
    // relative; resolve it against the request URL.
    if (finalUri.hasScheme) return finalUri.toString();
    if (base == null) return finalUri.toString();
    return base.resolveUri(finalUri).toString();
  }

  /// The body, decoded with the charset in `content-type`, or UTF-8 when the
  /// header doesn't name one. Malformed bytes are replaced. Reads into memory
  /// and caches, so calling again (or [bytes]) is free.
  @override
  Future<String> text() async => _decode(await bytes());

  /// The body as bytes, cached like [text].
  @override
  Future<List<int>> bytes() async {
    if (_closed) {
      throw StateError('response is closed: ${url()}');
    }
    final cached = _cached;
    if (cached != null) return cached;
    if (_streaming) {
      throw StateError('body already streaming: ${url()}');
    }
    _streaming = true;
    try {
      final out = BytesBuilder(copy: false);
      await for (final chunk in _bodyStream()) {
        out.add(chunk);
      }
      _cached = out.takeBytes();
      return _cached!;
    } finally {
      _finish();
    }
  }

  @override
  Stream<List<int>> stream() {
    if (_closed) {
      throw StateError('response is closed: ${url()}');
    }
    final cached = _cached;
    if (cached != null) return Stream.value(cached);
    if (_streaming) {
      throw StateError('body already streaming: ${url()}');
    }
    _streaming = true;
    // async* so a downstream failure (a writer that throws mid-run, a pipe
    // that throws, a cancelled subscription) still releases the socket via
    // the finally: without this the client leaks and keeps the script alive.
    return _streamBody();
  }

  Stream<List<int>> _streamBody() async* {
    try {
      await for (final chunk in _bodyStream()) {
        yield chunk;
      }
    } finally {
      _finish();
    }
  }

  /// Drop a body nobody will read, so the socket doesn't keep the script
  /// alive. Idempotent; a no-op after the body is consumed. Reading after
  /// [close] is a [StateError].
  @override
  Future<void> close() async {
    if (_closed || _done) return;
    _closed = true;
    try {
      // Cancel the socket's subscription if the body never started.
      await _resp.stream.drain<void>();
    } catch (_) {
      // Dropping must not throw.
    } finally {
      _finish();
    }
  }

  Stream<List<int>> _bodyStream() => _resp.stream.timeout(
        _timeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'body stalled for ${_timeout.inSeconds}s: ${url()}',
              _timeout,
            ),
          );
        },
      );

  String _decode(List<int> bytes) {
    final contentType = header('content-type');
    if (contentType != null) {
      final m = RegExp(
        r'charset\s*=\s*["'']?([^;"'']+)',
        caseSensitive: false,
      ).firstMatch(contentType);
      if (m != null) {
        final enc = Encoding.getByName(m.group(1)!.trim());
        if (enc != null) {
          try {
            return enc.decode(bytes);
          } catch (_) {
            return utf8.decode(bytes, allowMalformed: true);
          }
        }
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _finish() {
    _done = true;
    _client.close();
  }
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension ResponseFuture on Future<Response> {
  Future<int> status() async => (await this).status();
  Future<String?> header(String name) async => (await this).header(name);
  Future<String> url() async => (await this).url();
}

Future<Response> _send(
  String method,
  String url, {
  Object? body,
  Map<String, String>? headers,
  Duration? timeout,
}) async {
  final limit = timeout ?? Http.defaultTimeout;
  Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (e) {
    throw ArgumentError.value(url, 'url', 'invalid URL: $e');
  }
  // Fresh client per request: no pooling, no shared state to leak.
  final client = http.Client();
  try {
    if (body is Reader) {
      final req = http.StreamedRequest(method, uri);
      if (headers != null) req.headers.addAll(headers);
      final contentLength = req.headers['content-length'];
      if (contentLength != null) {
        final n = int.tryParse(contentLength);
        if (n == null || n < 0) {
          client.close();
          throw ArgumentError.value(
            contentLength,
            'headers[content-length]',
            'must be a non-negative integer',
          );
        }
        req.contentLength = n;
      }
      final streaming = req.sink
          .addStream(body.stream())
          .then((_) => req.sink.close());
      http.StreamedResponse resp;
      try {
        resp = await client
            .send(req)
            .timeout(
              limit,
              onTimeout: () => throw TimeoutException(
                'no headers for ${limit.inSeconds}s: $url',
                limit,
              ),
            );
      } catch (_) {
        try {
          await req.sink.close();
        } catch (_) {}
        await streaming.catchError((Object _) {});
        rethrow;
      }
      unawaited(streaming.catchError((Object _) {}));
      return Response._(resp, client, limit);
    }
    final req = http.Request(method, uri);
    if (headers != null) req.headers.addAll(headers);
    if (body is String) {
      req.body = body;
    } else if (body is List<int>) {
      req.bodyBytes = body;
    } else if (body != null) {
      client.close();
      throw ArgumentError.value(
        body,
        'body',
        'must be a String, List<int>, or Reader',
      );
    }
    final resp = await client.send(req).timeout(
          limit,
          onTimeout: () => throw TimeoutException(
            'no headers for ${limit.inSeconds}s: $url',
            limit,
          ),
        );
    return Response._(resp, client, limit);
  } on TimeoutException {
    client.close();
    rethrow;
  } catch (_) {
    client.close();
    rethrow;
  }
}
