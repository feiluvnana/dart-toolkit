import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/decoding.dart';
import '../core/native.dart' as native;
import '../core/traits.dart';
import '../fs/io.dart' as fs;

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// What the network said, as text: `on HttpException` catches every way a
/// request fails but running out of time (a [TimeoutException]).
class HttpException implements Exception {
  /// What went wrong.
  final String message;

  /// The URL that was asked for, when there is one.
  final Uri? uri;

  /// The non-2xx status, or null for a network failure.
  final int? status;

  /// What the transport threw (a `SocketException`) on a network failure.
  final Object? cause;

  const HttpException(this.message, {this.uri, this.status, this.cause});

  @override
  String toString() => uri == null ? 'HttpException: $message' : 'HttpException: $message from $uri';
}

/// A streaming HTTP response. A [Source], so the readings (`text`, `bytes`,
/// `lines`, `pipe` …) work on it — strictly: a reading on a non-2xx throws an
/// [HttpException], so check [ok] first when a non-2xx is data.
///
/// The body streams: it is never pre-read. Read it once, then [close].
final class Resp implements Source, Reader, Decoding {
  /// The status code, e.g. `200`.
  final int status;

  /// Response headers, lower-cased names.
  final Map<String, String> headers;

  /// The final URL after redirects.
  final String url;

  /// The reason phrase, e.g. `Not Found`.
  final String reason;

  final StreamIterator<Uint8List> _it;
  final io.HttpClient _client;
  final List<int> _carry = [];
  bool _done = false;

  Resp._(this.status, this.headers, this.url, this.reason, Stream<Uint8List> body, this._client)
    : _it = StreamIterator(body);

  /// Whether the status is 2xx.
  bool get ok => status >= 200 && status < 300;

  /// One header, or `null`.
  String? header(String name) => headers[name.toLowerCase()];

  /// The body's length from `content-length`, or null without one.
  @override
  int? get lengthHint => int.tryParse(header('content-length') ?? '');

  /// [bytes] of this body as text, in the charset the response declares.
  @override
  String decode(Uint8List bytes) => _decodeBody(bytes, header('content-type'));

  /// Fills [buf] with the next body bytes and answers how many were written.
  /// `0` means the body ended.
  @override
  Future<int> read(Uint8List buf) async {
    if (_done) return 0;
    while (_carry.isEmpty) {
      final hasNext = await _it.moveNext();
      if (!hasNext) {
        _done = true;
        await _release();
        return 0;
      }
      _carry.addAll(_it.current);
    }
    final n = math.min(buf.length, _carry.length);
    buf.setRange(0, n, _carry);
    _carry.removeRange(0, n);
    return n;
  }

  /// This response's body, strictly: a non-2xx throws an [HttpException].
  /// [from] must be 0 on a response that is already sent.
  @override
  Future<Reader> reader({int from = 0}) async {
    if (from != 0) {
      throw ArgumentError.value(from, 'from', 'Only 0: a sent response cannot seek');
    }
    return _bodyReader();
  }

  /// The strict body reader: a non-2xx closes the response and throws an
  /// [HttpException] carrying its status.
  Future<Reader> _bodyReader() async {
    if (!ok) {
      await close();
      throw HttpException('$status $reason from $url', uri: Uri.tryParse(url), status: status);
    }
    return this;
  }

  Future<void> _release() async {
    try {
      await _it.cancel();
    } catch (_) {
      // Already done: nothing to cancel.
    }
    try {
      _client.close(force: true);
    } catch (_) {
      // Already closed: nothing to do.
    }
  }

  /// Cancels the body stream and releases the connection.
  @override
  Future<void> close() async {
    _done = true;
    _carry.clear();
    await _release();
  }
}

/// A request that is sent on first use: `await` gives the [Resp]; a reading or `pipe` reads
/// the body. Sending late lets `pipe(file, resume: true)` add a `Range` header.
final class Request implements Future<Resp>, Source, Decoding {
  Request._(this._method, this._url, this._headers, this._timeout, this._retry, this._body);

  final String _method;
  final String _url;
  final Map<String, String>? _headers;
  final Duration? _timeout;
  final int? _retry;
  final _Body? _body;
  Future<Resp>? _sent;
  int _from = 0;
  Map<String, String>? _responseHeaders;

  Future<Resp> get _resp => _sent ??= Http._withRetry(
    _method,
    _url,
    headers: {...?_headers, if (_from > 0) 'range': 'bytes=$_from-'},
    timeout: _timeout,
    retry: _retry,
    body: _body,
  );

  /// The body's length from the response's `content-length` once sent,
  /// else null.
  @override
  int? get lengthHint => int.tryParse(_responseHeaders?['content-length'] ?? '');

  /// [bytes] of the body as text, in the charset the response declared.
  @override
  String decode(Uint8List bytes) => _decodeBody(bytes, _responseHeaders?['content-type']);

  @override
  Future<Reader> reader({int from = 0}) async {
    if (_sent != null && from != _from) throw StateError('Request already sent');
    _from = from;
    final resp = await _resp;
    _responseHeaders = resp.headers;
    if (from > 0 && resp.status == 200) {
      // The server ignored Range: restart. pipe() sees `from` bytes too many; signal it.
      await resp.close();
      throw HttpException('Server does not support resume', uri: Uri.parse(_url), status: 200);
    }
    return resp._bodyReader();
  }

  @override
  Stream<Resp> asStream() => _resp.asStream();
  @override
  Future<Resp> catchError(Function onError, {bool Function(Object error)? test}) =>
      _resp.catchError(onError, test: test);
  @override
  Future<R> then<R>(FutureOr<R> Function(Resp value) onValue, {Function? onError}) =>
      _resp.then(onValue, onError: onError);
  @override
  Future<Resp> timeout(Duration timeLimit, {FutureOr<Resp> Function()? onTimeout}) =>
      _resp.timeout(timeLimit, onTimeout: onTimeout);
  @override
  Future<Resp> whenComplete(FutureOr<void> Function() action) => _resp.whenComplete(action);
}

/// A request body: exactly one of JSON, form fields, or a streamed [Source].
sealed class _Body {
  const _Body();
}

/// A JSON body, sent as `application/json`.
final class _JsonBody extends _Body {
  final Object? value;
  const _JsonBody(this.value);
}

/// Form fields, sent as `application/x-www-form-urlencoded`.
final class _FormBody extends _Body {
  final Map<String, String> fields;
  const _FormBody(this.fields);
}

/// A streamed body: read chunk by chunk, never materialised.
final class _SourceBody extends _Body {
  final Source source;
  const _SourceBody(this.source);
}

/// The [_Body] for [json]/[form]/[body]: none gives null, more than one is an
/// [ArgumentError].
_Body? _bodyOf(String method, {Object? json, Map<String, String>? form, Source? body}) {
  var seen = 0;
  if (json != null) seen++;
  if (form != null) seen++;
  if (body != null) seen++;
  if (seen > 1) {
    throw ArgumentError.value(
      {'json': json, 'form': form, 'body': body},
      'body',
      'Give $method exactly one of json:, form: or body:',
    );
  }
  if (json != null) return _JsonBody(json);
  if (form != null) return _FormBody(form);
  if (body != null) return _SourceBody(body);
  return null;
}

/// A tiny HTTP/1.1 client on `dart:io`: `Http.get`, [post], [put], [delete].
///
/// ```dart
/// final data = await Http.get('https://api.example.com/data').text();
/// await Http.get('https://example.com/huge.iso').pipe(File('huge.iso'));
/// ```
///
/// A request is sent on first use, so `pipe(file, resume: true)` can still
/// ask for the rest with `Range`. Every request is retried twice on 5xx or
/// network errors ([retry]), with 30 s per response by default ([timeout]).
abstract final class Http {
  static const Duration _timeout = Duration(seconds: 30);
  static const int _retries = 2;

  /// A GET of [url], sent on first use: `await` gives the [Resp], a reading
  /// or `pipe` reads the body.
  static Request get(String url, {Map<String, String>? headers, Duration? timeout, int? retry}) =>
      Request._('GET', url, headers, timeout, retry, null);

  /// A POST; exactly one of [json] (sent as JSON), [form] (sent as
  /// form fields) or [body] (a [Source], streamed with chunked encoding —
  /// never materialised).
  static Request post(
    String url, {
    Object? json,
    Map<String, String>? form,
    Source? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => Request._('POST', url, headers, timeout, retry, _bodyOf('POST', json: json, form: form, body: body));

  /// A PUT; the body works like [post]'s.
  static Request put(
    String url, {
    Object? json,
    Map<String, String>? form,
    Source? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => Request._('PUT', url, headers, timeout, retry, _bodyOf('PUT', json: json, form: form, body: body));

  /// A DELETE; the body works like [post]'s.
  static Request delete(
    String url, {
    Object? json,
    Map<String, String>? form,
    Source? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => Request._('DELETE', url, headers, timeout, retry, _bodyOf('DELETE', json: json, form: form, body: body));

  static Future<Resp> _withRetry(
    String method,
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
    _Body? body,
  }) async {
    final attempts = (retry ?? _retries) + 1;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final resp = await _send(method, url, headers: headers, timeout: timeout ?? _timeout, body: body);
        if (resp.status >= 500 && attempt < attempts) {
          lastError = HttpException(
            '${resp.status} ${resp.reason} from ${resp.url}',
            uri: Uri.tryParse(url),
            status: resp.status,
          );
          await resp.close();
          continue;
        }
        return resp;
      } on HttpException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt >= attempts) break;
        if (!_retryable(e)) break;
      }
    }
    if (lastError is HttpException) throw lastError;
    throw HttpException('Request failed: $lastError', uri: Uri.tryParse(url), cause: lastError);
  }

  static bool _retryable(Object e) => e is io.SocketException || e is io.HttpException || e is TimeoutException;

  static Future<Resp> _send(
    String method,
    String url, {
    Map<String, String>? headers,
    required Duration timeout,
    _Body? body,
  }) async {
    final client = io.HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url)).timeout(timeout);
      headers?.forEach(request.headers.set);
      if (body != null) await _writeBody(request, body);
      final response = await request.close().timeout(timeout);
      final respHeaders = <String, String>{};
      response.headers.forEach((name, values) => respHeaders[name.toLowerCase()] = values.join(', '));
      final finalUrl = response.redirects.isEmpty ? url : response.redirects.last.location.toString();
      return Resp._(
        response.statusCode,
        respHeaders,
        finalUrl,
        response.reasonPhrase,
        response.map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
        client,
      );
    } catch (_) {
      try {
        client.close(force: true);
      } catch (_) {
        // Closing a failed client never hides the failure.
      }
      rethrow;
    }
  }

  /// Writes [body] into [request]: JSON as `application/json`, form fields
  /// URL-encoded, a [Source] streamed with chunked encoding (never
  /// materialised; a file sends its size as `content-length`).
  static Future<void> _writeBody(io.HttpClientRequest request, _Body body) async {
    switch (body) {
      case _JsonBody(:final value):
        request.headers.contentType = io.ContentType.json;
        request.write(jsonEncode(value));
      case _FormBody(:final fields):
        request.headers.contentType = io.ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        request.write(Uri(queryParameters: fields).query);
      case _SourceBody(:final source):
        request.bufferOutput = false;
        if (source case final fs.File file) {
          try {
            request.contentLength = await file.size();
          } catch (_) {
            request.contentLength = -1;
          }
        }
        final reader = await source.reader();
        try {
          final chunk = Uint8List(64 * 1024);
          while (true) {
            final n = await reader.read(chunk);
            if (n <= 0) break;
            request.add(chunk.sublist(0, n));
          }
        } finally {
          await reader.close();
        }
    }
  }
}

/// An HTTP body as text, decoded like a browser does: the `Content-Type` charset, else (for
/// HTML) a `<meta charset>` in the first 1024 bytes, else UTF-8. Malformed bytes become U+FFFD
/// (web bodies are often slightly broken); a legacy charset decodes in the native engine.
String _decodeBody(Uint8List bytes, String? contentType) {
  final label = (_declaredCharset(contentType) ?? _metaCharset(bytes, contentType))?.toLowerCase();
  return switch (label) {
    null || 'utf-8' || 'utf8' || 'unicode-1-1-utf-8' => utf8.decode(bytes, allowMalformed: true),
    'us-ascii' || 'ascii' => ascii.decode(bytes, allowInvalid: true),
    final other => native.decodeCharset(other, bytes),
  };
}

final _charsetParam = RegExp(r'''charset\s*=\s*["']?([A-Za-z0-9._:\-]+)''', caseSensitive: false);
final _metaTag = RegExp(r'''<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9._:\-]+)''', caseSensitive: false);

String? _declaredCharset(String? contentType) => contentType == null ? null : _charsetParam.firstMatch(contentType)?[1];

String? _metaCharset(Uint8List bytes, String? contentType) {
  if (contentType != null && !contentType.toLowerCase().contains('html')) return null;
  final head = latin1.decode(Uint8List.sublistView(bytes, 0, bytes.length < 1024 ? bytes.length : 1024));
  return _metaTag.firstMatch(head)?[1];
}
