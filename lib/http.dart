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
/// - [Response] supports `status` `ok` `header` `url` `size` `name`
///   (plus [Reader]/[Closeable]).
/// A non-2xx status is still a [Response]; only network failures and
/// timeouts throw. Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'core.dart';
export 'core.dart';

import 'src/charset.dart' as charset;
import 'src/origin.dart' as origin;

/// Entry point: one method per HTTP verb. A verb completes when the headers
/// arrive; the body streams as a [Reader].
///
/// - Redirects are followed for every verb, up to 10 hops: 301/302/303 after
///   a POST become a GET (the body is dropped); 307/308 keep the method and
///   resend an in-memory body. A 307/308 (or a 301/302 that keeps the method)
///   with a streamed [Reader] body cannot be resent, so it throws
///   [HttpException] naming the limitation. `url()` is the final URL.
/// - `body` is a `String` (`text/plain; charset=utf-8` unless `content-type`
///   is given), a `List<int>`, a `Reader` (streamed), or a
///   `Map<String, String>` (a URL-encoded form). `json:` sends
///   `jsonEncode(value)` as `application/json`. Giving both is an
///   [ArgumentError].
/// - `retries` re-sends on network errors, timeouts, 5xx and 429, with
///   doubling backoff from 1 s or the server's `Retry-After`. It applies only
///   when the body is in memory (and only to the send: a body that stalls
///   after the [Response] is delivered throws [TimeoutException] instead);
///   a [Reader] body is sent once and never retried.
abstract final class Http {
  /// Bound on the wait for the headers, then on any stall streaming.
  static const Duration _defaultTimeout = Duration(seconds: 30);

  /// Redirect hops followed per send before failing with [HttpException].
  static const int _maxRedirects = 10;

  /// GET [url] with optional [headers], [timeout] and [retries].
  static Future<Response> get(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send('GET', url, headers: headers, timeout: timeout, retries: retries);

  /// HEAD [url] with optional [headers], [timeout] and [retries].
  static Future<Response> head(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send('HEAD', url, headers: headers, timeout: timeout, retries: retries);

  /// DELETE [url] with optional [headers], [timeout] and [retries].
  static Future<Response> delete(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send(
        'DELETE',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
      );

  /// OPTIONS [url] with optional [headers], [timeout] and [retries].
  static Future<Response> options(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send(
        'OPTIONS',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
      );

  /// POST [url] with a [body] (`String`, `List<int>`, [Reader] or
  /// `Map<String, String>` form) or [json]. Giving both is an
  /// [ArgumentError].
  static Future<Response> post(
    String url, {
    Object? body,
    Object? json,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send(
        'POST',
        url,
        body: body,
        json: json,
        headers: headers,
        timeout: timeout,
        retries: retries,
      );

  /// PUT [url] with a [body] or [json] (same as [post]).
  static Future<Response> put(
    String url, {
    Object? body,
    Object? json,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send(
        'PUT',
        url,
        body: body,
        json: json,
        headers: headers,
        timeout: timeout,
        retries: retries,
      );

  /// PATCH [url] with a [body] or [json] (same as [post]).
  static Future<Response> patch(
    String url, {
    Object? body,
    Object? json,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
  }) =>
      _send(
        'PATCH',
        url,
        body: body,
        json: json,
        headers: headers,
        timeout: timeout,
        retries: retries,
      );
}

/// An HTTP response: a [Reader] of the body, streamed from the socket.
///
/// - A non-2xx status is still a [Response]. [ok] tests 200–299. The
///   readings ([text], [bytes]) work on any status, but only a 2xx body can
///   be piped: [stream] (and so `>`/`to`) throws [HttpException] naming the
///   status and URL otherwise.
/// - [text] decodes with the charset in `content-type`, then
///   `<meta charset>`, then UTF-8 (WHATWG CJK decoders included). Unknown
///   charsets fall back to UTF-8; bad bytes become `�`.
/// - [close] drops an unread body. A body read or piped to the end releases
///   the connection by itself. The `Future<Response>` mirrors
///   (`Http.get(u).status()`) close the response after reading: a response
///   reached only through a mirror can never be read later.
final class Response with Reader implements Closeable {
  Response._(this._resp, this._client, this._timeout, this._url);

  final http.StreamedResponse _resp;
  final http.Client _client;
  final Duration _timeout;

  /// The final URL, after redirects.
  final String _url;

  List<int>? _cached;
  var _streaming = false;
  var _closed = false;
  var _done = false;

  /// HTTP status code (e.g. 200, 404). Sync from when the headers arrive.
  int status() => _resp.statusCode;

  /// Whether the status is 2xx.
  bool ok() {
    final code = _resp.statusCode;
    return code >= 200 && code < 300;
  }

  /// Response header [name] (case-insensitive) or `null` if absent.
  String? header(String name) {
    final key = name.toLowerCase();
    for (final entry in _resp.headers.entries) {
      if (entry.key.toLowerCase() == key) return entry.value;
    }
    return null;
  }

  /// The final URL, after redirects.
  String url() => _url;

  /// The `content-length`, or `null` when absent or unparseable.
  int? size() {
    final value = header('content-length');
    if (value == null) return null;
    final n = int.tryParse(value.trim());
    if (n == null || n < 0) return null;
    return n;
  }

  /// A file name for the body: the `content-disposition` filename
  /// (`filename*=` wins over `filename=`, paths stripped), else the final
  /// URL's last segment, else `'download'`.
  String name() => _fileName(
    url: _url,
    contentDisposition: header('content-disposition'),
  );

  /// Typed provenance: replaces `(reader as dynamic).url()`/`.status()`/
  /// `.name()` probes in `html`/`json`/`chrome`.
  @override
  Origin origin() => Origin(
        url: _url,
        status: _resp.statusCode,
        name: name(),
      );

  /// The body as text (see the class doc for the charset rules). Reads into
  /// memory and caches, so calling again (or [bytes]) is free. Works on any
  /// status.
  @override
  Future<String> text() async =>
      charset.Charset.decode(await bytes(), contentType: header('content-type'));

  /// The body as bytes, cached like [text]. Works on any status.
  /// Returns a copy so callers can't mutate the cache.
  @override
  Future<List<int>> bytes() async {
    if (_closed) {
      throw StateError('response is closed: ${url()}');
    }
    final cached = _cached;
    if (cached != null) return Uint8List.fromList(cached);
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
      return Uint8List.fromList(_cached!);
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
    if (cached != null) {
      if (!ok()) {
        throw HttpException(
          'HTTP ${status()}: ${url()}',
          uri: Uri.tryParse(url()),
        );
      }
      return Stream.value(Uint8List.fromList(cached));
    }
    if (_streaming) {
      throw StateError('body already streaming: ${url()}');
    }
    if (!ok()) {
      // Only a 2xx body can be piped, so an error page is never saved.
      // Drop the body (releasing the client) and fail loudly; readings
      // still work only when the body was never piped.
      unawaited(close());
      throw HttpException(
        'HTTP ${status()}: ${url()}',
        uri: Uri.tryParse(url()),
      );
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
      // Drop, don't hang: a stalled body can't block close forever.
      // Drain with the response timeout, then release via _finish
      // (which closes the client).
      await _resp.stream.drain<void>().timeout(_timeout, onTimeout: () {});
    } catch (_) {
      // Dropping must not throw.
    } finally {
      _finish();
    }
  }

  Stream<List<int>> _bodyStream() => _resp.stream
      .timeout(
        _timeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'body stalled for $_timeout: ${url()}',
              _timeout,
            ),
          );
        },
      )
      .handleError((Object e) {
        if (e is http.ClientException) {
          throw HttpException(e.message, uri: Uri.tryParse(url()));
        }
        throw e;
      });

  void _finish() {
    _done = true;
    _client.close();
  }
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
///
/// Each mirror closes the response after reading: a response reached only
/// through a mirror can never be read later.
extension ResponseFuture on Future<Response> {
  Future<int> status() async {
    final res = await this;
    try {
      return res.status();
    } finally {
      await res.close();
    }
  }

  Future<bool> ok() async {
    final res = await this;
    try {
      return res.ok();
    } finally {
      await res.close();
    }
  }

  Future<String?> header(String name) async {
    final res = await this;
    try {
      return res.header(name);
    } finally {
      await res.close();
    }
  }

  Future<String> url() async {
    final res = await this;
    try {
      return res.url();
    } finally {
      await res.close();
    }
  }

  Future<int?> size() async {
    final res = await this;
    try {
      return res.size();
    } finally {
      await res.close();
    }
  }

  Future<String> name() async {
    final res = await this;
    try {
      return res.name();
    } finally {
      await res.close();
    }
  }
}

/// A file name for a response body. Kept as one helper so `Visit.name()`
/// can share it later. Delegates to `src/origin.dart` (the single owner).
String _fileName({required String url, String? contentDisposition}) =>
    origin.fileName(url: url, contentDisposition: contentDisposition);

/// Retryable send failure, caught inside [_send] only.
final class _Retryable {
  _Retryable(this.cause);

  final Object cause;
}

/// In-memory bodies resend on redirect and retry; streamed ones go once.
sealed class _Body {
  const _Body();
}

final class _NoBody extends _Body {
  const _NoBody();
}

final class _MemBody extends _Body {
  const _MemBody(this.bytes, this.contentType);

  /// The encoded bytes.
  final List<int> bytes;

  /// The default `content-type`, used only when the caller gave none.
  final String? contentType;
}

final class _StreamBody extends _Body {
  const _StreamBody(this.reader);

  final Reader reader;
}

Future<Response> _send(
  String method,
  String url, {
  Object? body,
  Object? json,
  Map<String, String>? headers,
  Duration? timeout,
  int retries = 0,
}) async {
  final limit = timeout ?? Http._defaultTimeout;
  if (retries < 0) {
    throw ArgumentError.value(retries, 'retries', 'must not be negative');
  }
  late final Uri first;
  try {
    first = Uri.parse(url);
  } catch (e) {
    throw ArgumentError.value(url, 'url', 'invalid URL: $e');
  }
  if (first.scheme != 'http' && first.scheme != 'https') {
    throw ArgumentError.value(
      url,
      'url',
      'must be an absolute http(s) URL',
    );
  }
  final encoded = _encodeBody(body, json);
  final resendable = encoded is! _StreamBody;
  var attempt = 0;
  Duration? retryAfter;
  while (true) {
    if (attempt > 0) {
      await Future<void>.delayed(_backoff(attempt - 1, retryAfter));
    }
    retryAfter = null;
    try {
      final res = await _attempt(method, first, encoded, headers, limit);
      if (resendable &&
          (res.status() == 429 || res.status() >= 500) &&
          attempt < retries) {
        retryAfter = _retryAfter(res.header('retry-after'));
        await res.close();
        attempt++;
        continue;
      }
      return res;
    } on _Retryable catch (e) {
      if (!resendable || attempt >= retries) throw e.cause;
      attempt++;
    }
  }
}

_Body _encodeBody(Object? body, Object? json) {
  if (json != null && body != null) {
    throw ArgumentError.value(
      json,
      'json',
      'cannot give both body: and json:',
    );
  }
  if (json != null) {
    return _MemBody(utf8.encode(jsonEncode(json)), 'application/json');
  }
  if (body == null) return const _NoBody();
  if (body is String) {
    return _MemBody(utf8.encode(body), 'text/plain; charset=utf-8');
  }
  if (body is List<int>) return _MemBody(body, null);
  if (body is Map) {
    final entries = <String, String>{};
    for (final entry in body.entries) {
      final key = entry.key, value = entry.value;
      if (key is! String || value is! String) {
        throw ArgumentError.value(
          body,
          'body',
          'a form map must be Map<String, String>',
        );
      }
      entries[key] = value;
    }
    return _MemBody(
      utf8.encode(Uri(queryParameters: entries).query),
      'application/x-www-form-urlencoded',
    );
  }
  if (body is Reader) return _StreamBody(body);
  throw ArgumentError.value(
    body,
    'body',
    'must be a String, List<int>, Map<String, String>, or Reader',
  );
}

Duration _backoff(int attempt, Duration? server) {
  final shift = attempt > 10 ? 10 : attempt;
  var wait = Duration(seconds: 1 << shift);
  if (server != null && server > wait) wait = server;
  return wait;
}

Duration? _retryAfter(String? value) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
  try {
    final date = HttpDate.parse(value.trim());
    final wait = date.difference(DateTime.now().toUtc());
    if (wait > Duration.zero) return wait;
  } catch (_) {}
  return null;
}

/// One send: the request plus manual redirect following. Retryable network
/// failures arrive as [_Retryable]; anything else (including a redirect that
/// cannot resend a streamed body) throws as-is.
Future<Response> _attempt(
  String method,
  Uri first,
  _Body body,
  Map<String, String>? headers,
  Duration limit,
) async {
  // Fresh client per attempt: no pooling, no shared state to leak.
  var client = http.Client();
  try {
    var currentMethod = method;
    var currentUri = first;
    _Body currentBody = body;
    Map<String, String>? currentHeaders = headers;
    for (var hop = 0; ; hop++) {
      http.StreamedResponse resp;
      try {
        resp = await _singleSend(
          client,
          currentMethod,
          currentUri,
          currentBody,
          currentHeaders,
          limit,
        );
      } on TimeoutException catch (e) {
        throw _Retryable(e);
      } on HttpException catch (e) {
        throw _Retryable(e);
      } on http.ClientException catch (e) {
        throw _Retryable(HttpException(e.message, uri: currentUri));
      } on IOException catch (e) {
        throw _Retryable(e);
      }
      if (!_isRedirect(resp.statusCode)) {
        return Response._(resp, client, limit, currentUri.toString());
      }
      final location = _locationOf(resp.headers);
      if (location == null || location.isEmpty) {
        return Response._(resp, client, limit, currentUri.toString());
      }
      if (hop >= Http._maxRedirects) {
        try {
          await resp.stream.drain<void>().timeout(limit);
        } catch (_) {}
        throw HttpException(
          'too many redirects (>${Http._maxRedirects}): $currentUri',
          uri: currentUri,
        );
      }
      final next = currentUri.resolve(location);
      try {
        await resp.stream.drain<void>().timeout(limit);
      } catch (_) {
        // A stalled drain can't hold the socket for the next hop:
        // drop the pooled connection and continue with a fresh client.
        try {
          client.close();
        } catch (_) {}
        client = http.Client();
      }
      final code = resp.statusCode;
      if ((code == 301 || code == 302) && currentMethod == 'POST') {
        currentMethod = 'GET';
        currentBody = const _NoBody();
        currentHeaders = _withoutContent(currentHeaders);
      } else if (code == 303) {
        if (currentMethod != 'HEAD') {
          currentMethod = 'GET';
          currentBody = const _NoBody();
          currentHeaders = _withoutContent(currentHeaders);
        }
      } else if (currentBody is _StreamBody) {
        // 307/308, or 301/302 keeping the method: resending would need the
        // bytes back, but a streamed body is gone. Failing loudly beats
        // silently downgrading to a GET without a body.
        throw HttpException(
          'redirect $code cannot resend a streamed body: $currentUri',
          uri: currentUri,
        );
      }
      if (currentUri.hasScheme && next.hasScheme && currentUri.origin != next.origin) {
        currentHeaders = _stripSensitiveHeaders(currentHeaders);
      }
      currentUri = next;
    }
  } catch (_) {
    client.close();
    rethrow;
  }
}

bool _isRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

/// The `location` header, case-insensitively (servers send `Location`).
String? _locationOf(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'location') return entry.value;
  }
  return null;
}

bool _hasHeader(Map<String, String> headers, String name) {
  final key = name.toLowerCase();
  for (final existing in headers.keys) {
    if (existing.toLowerCase() == key) return true;
  }
  return false;
}

Map<String, String>? _withoutContent(Map<String, String>? headers) {
  if (headers == null) return null;
  final out = Map<String, String>.of(headers);
  out.removeWhere(
    (key, _) =>
        key.toLowerCase() == 'content-type' ||
        key.toLowerCase() == 'content-length',
  );
  return out;
}

Map<String, String>? _stripSensitiveHeaders(Map<String, String>? headers) {
  if (headers == null) return null;
  final out = Map<String, String>.of(headers);
  out.removeWhere((key, _) {
    final k = key.toLowerCase();
    return k == 'authorization' || k == 'cookie' || k == 'proxy-authorization';
  });
  return out;
}

/// Send one request without following redirects. On a header timeout with a
/// [Reader] body the client is closed first and the body feed is cancelled
/// without awaiting it, so a server that never reads the body cannot hang
/// the send; guarded callbacks keep it from surfacing async errors later.
Future<http.StreamedResponse> _singleSend(
  http.Client client,
  String method,
  Uri uri,
  _Body body,
  Map<String, String>? headers,
  Duration limit,
) async {
  TimeoutException timeout() =>
      TimeoutException('no headers for $limit: $uri', limit);
  try {
    if (body is _StreamBody) {
      final req = http.StreamedRequest(method, uri);
      req.followRedirects = false;
      if (headers != null) req.headers.addAll(headers);
      final contentLength = _headerValue(req.headers, 'content-length');
      if (contentLength != null) {
        final n = int.tryParse(contentLength);
        if (n == null || n < 0) {
          throw ArgumentError.value(
            contentLength,
            'headers[content-length]',
            'must be a non-negative integer',
          );
        }
        req.contentLength = n;
      }
      StreamSubscription<List<int>>? feed;
      try {
        feed = body.reader.stream().listen(
          (chunk) {
            try {
              req.sink.add(chunk);
            } catch (_) {}
          },
          onError: (Object e) {
            try {
              req.sink.addError(e);
            } catch (_) {}
            try {
              req.sink.close();
            } catch (_) {}
          },
          onDone: () {
            try {
              req.sink.close();
            } catch (_) {}
          },
          cancelOnError: true,
        );
      } catch (_) {
        try {
          req.sink.close();
        } catch (_) {}
        rethrow;
      }
      try {
        return await client.send(req).timeout(limit, onTimeout: () {
          throw timeout();
        });
      } catch (_) {
        client.close();
        unawaited(_cancelFeed(feed));
        rethrow;
      }
    }
    final req = http.Request(method, uri);
    req.followRedirects = false;
    if (headers != null) req.headers.addAll(headers);
    if (body is _MemBody) {
      req.bodyBytes = body.bytes;
      final contentType = body.contentType;
      if (contentType != null && !_hasHeader(req.headers, 'content-type')) {
        req.headers['content-type'] = contentType;
      }
    }
    return await client.send(req).timeout(limit, onTimeout: () {
      throw timeout();
    });
  } on http.ClientException catch (e) {
    throw HttpException(e.message, uri: uri);
  }
}

String? _headerValue(Map<String, String> headers, String name) {
  final key = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == key) return entry.value;
  }
  return null;
}

/// Cancel a body feed without ever throwing (H1: never awaited after a
/// failure, and never surfacing async errors).
Future<void> _cancelFeed(StreamSubscription<List<int>>? feed) async {
  try {
    await feed?.cancel();
  } catch (_) {}
}
