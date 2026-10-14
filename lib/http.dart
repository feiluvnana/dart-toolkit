/// Minimal HTTP client. Thin facade over SDK `dart:io` `HttpClient`.
///
/// ```dart
/// final user = await Http.get('https://api.example.com/me',
///     headers: {'authorization': token}).json();
/// await (Http.get(url) > Fs.file('page.html'));
/// await Http.put('https://cdn.example.com/d.iso', body: .stream(Fs.file('d.iso')));
/// ```
///
/// Public surface is exactly: [Http], [Response], [Body], [HttpHold].
/// - `Http.get/head/delete/options/post/put/patch()` return a [Response].
/// - [Response] supports `statusCode` `isSuccess` `header` `finalUrl`
///   `contentLength` `fileName` (plus [Reader]/[Closeable]).
/// - [Body] is a sealed request body: `.text` `.bytes` `.form` `.json`
///   `.stream`. A [Body.stream] is sent once and never retried.
/// - [HttpHold] keeps the shared client open for a crawl (see [Http.hold]).
/// A non-2xx status is still a [Response]; only network failures and
/// timeouts throw. Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

import 'src/charset.dart' as charset;
import 'src/origin.dart' as names;
import 'src/retry.dart' as retry;

/// A request body. The compiler rejects a wrong shape; there is no
/// `body:`/`json:` pair to pass together and no runtime `ArgumentError`.
///
/// ```dart
/// await Http.post('$api/items', body: .json(item));
/// await Http.post('$base/ajax', body: .form({'action': 'decode'}));
/// await Http.put(uploadUrl, body: .stream(Archive.pack('site', .zip)));
/// ```
sealed class Body {
  const Body._();

  /// `text/plain; charset=utf-8` (unless `content-type` is given).
  const factory Body.text(String text) = TextBody;

  /// Raw bytes; no default `content-type`.
  const factory Body.bytes(List<int> bytes) = BytesBody;

  /// URL-encoded form (`application/x-www-form-urlencoded`).
  const factory Body.form(Map<String, String> fields) = FormBody;

  /// `jsonEncode(value)` as `application/json`.
  const factory Body.json(Object? value) = JsonBody;

  /// Streamed from [reader]: sent once, never retried.
  const factory Body.stream(Reader reader) = StreamBody;
}

/// `text/plain; charset=utf-8`.
final class TextBody extends Body {
  const TextBody(this.text) : super._();

  final String text;
}

/// Raw bytes.
final class BytesBody extends Body {
  const BytesBody(this.bytes) : super._();

  final List<int> bytes;
}

/// URL-encoded form fields.
final class FormBody extends Body {
  const FormBody(this.fields) : super._();

  final Map<String, String> fields;
}

/// JSON-encoded value.
final class JsonBody extends Body {
  const JsonBody(this.value) : super._();

  final Object? value;
}

/// A streamed body. Sent once, never retried: a 307/308 (or a 301/302 that
/// keeps the method) that would need the bytes back throws [HttpException]
/// naming the limitation instead of silently downgrading.
final class StreamBody extends Body {
  const StreamBody(this.reader) : super._();

  final Reader reader;
}

/// Entry point: one method per HTTP verb. A verb completes when the headers
/// arrive; the body streams as a [Reader].
///
/// - Connections are pooled on one shared `HttpClient` per certificate mode
///   (secure + `insecure`), counted by responses (and requests) in flight.
///   When the count reaches 0, `close()` is scheduled with `Timer.run`, so a
///   sequential `for … await` loop still finds the open connection while a
///   finished script exits without waiting on an idle timeout. Picked over
///   (a) no reuse and (b) a 1 s `idleTimeout` delaying exit, by A/B.
///   [Http.hold] keeps the client open for a whole crawl.
/// - Redirects are followed for every verb, up to 10 hops: 301/302/303 after
///   a POST become a GET (the body is dropped); 307/308 keep the method and
///   resend an in-memory body. A 307/308 (or a 301/302 that keeps the method)
///   with a [Body.stream] cannot be resent, so it throws [HttpException]
///   naming the limitation. `finalUrl()` is the final URL.
/// - `body` is a [Body] (`.text`/`.bytes`/`.form`/`.json`/`.stream`).
/// - `insecure` accepts a bad certificate for this call only (one broken CDN
///   chain): it uses the shared insecure client, scoped to the request and
///   visible at the call site. It replaces the example's hand-written
///   `_getPageInsecure` (~40 lines of `dart:io`).
/// - `retries` re-sends on network errors, timeouts, 5xx and 429, with
///   doubling backoff from 1 s or the server's `Retry-After` (see
///   `src/retry.dart`; TLS/Handshake errors are permanent and never
///   retried). It applies only when the body is in memory (and only to the
///   send: a body that stalls after the [Response] is delivered throws
///   [TimeoutException] instead); a [Body.stream] is sent once and never
///   retried. A 5xx retry force-closes the socket instead of draining the
///   error body (which would wait up to the full timeout).
abstract final class Http {
  /// Bound on the wait for the headers, then on any stall streaming.
  static const Duration _defaultTimeout = Duration(seconds: 30);

  /// Redirect hops followed per send before failing with [HttpException].
  static const int _maxRedirects = 10;

  /// Hold the shared client open across many requests (a crawl). While the
  /// hold is open, the idle `Timer.run` close is suppressed; closing the
  /// hold releases it. `scrape` (a later pass) holds for the crawl lifetime.
  static HttpHold hold() {
    _securePool._hold();
    _insecurePool._hold();
    return HttpHold._();
  }

  /// GET [url] with optional [headers], [timeout], [retries] and [insecure].
  static Future<Response> get(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'GET',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );

  /// HEAD [url] with optional [headers], [timeout], [retries] and [insecure].
  static Future<Response> head(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'HEAD',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );

  /// DELETE [url] with optional [headers], [timeout], [retries] and
  /// [insecure].
  static Future<Response> delete(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'DELETE',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );

  /// OPTIONS [url] with optional [headers], [timeout], [retries] and
  /// [insecure].
  static Future<Response> options(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'OPTIONS',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );

  /// POST [url] with a [Body] (`body: .json(item)`).
  static Future<Response> post(
    String url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'POST',
        url,
        body: body,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );

  /// PUT [url] with a [Body] (same as [post]).
  static Future<Response> put(
    String url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'PUT',
        url,
        body: body,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );

  /// PATCH [url] with a [Body] (same as [post]).
  static Future<Response> patch(
    String url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
  }) =>
      _send(
        'PATCH',
        url,
        body: body,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
      );
}

/// Keeps the shared client open. Close to release; idempotent.
final class HttpHold implements Closeable {
  HttpHold._();

  var _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _securePool._unhold();
    _insecurePool._unhold();
  }
}

/// One pooled `HttpClient`: shared by every request with the same
/// certificate mode, counted by requests + live responses + holds. When all
/// reach 0, `close()` is scheduled with `Timer.run`.
final class _ClientPool {
  _ClientPool({required this.insecure});

  final bool insecure;
  HttpClient? _client;
  var _active = 0;
  var _holds = 0;

  HttpClient _ensure() {
    var c = _client;
    if (c == null) {
      c = HttpClient();
      if (insecure) {
        c.badCertificateCallback = (cert, host, port) => true;
      }
      _client = c;
    }
    return c;
  }

  /// A request starts: count it and hand out the shared client.
  HttpClient retain() {
    _active++;
    return _ensure();
  }

  /// A request failed before delivering a [Response]: uncount it.
  void release() {
    _active--;
    assert(_active >= 0, 'client pool over-released');
    if (_active == 0 && _holds == 0) Timer.run(_maybeClose);
  }

  /// A [Response] takes ownership of its request's count: it will
  /// [release] when it finishes. Called implicitly by [_attempt].

  void _hold() {
    _holds++;
  }

  void _unhold() {
    _holds--;
    assert(_holds >= 0, 'client pool hold over-released');
    if (_active == 0 && _holds == 0) Timer.run(_maybeClose);
  }

  /// Called by [Response] when its body is consumed or dropped.
  void releaseResponse() => release();

  void _maybeClose() {
    if (_active != 0 || _holds != 0) return;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}

final _securePool = _ClientPool(insecure: false);
final _insecurePool = _ClientPool(insecure: true);

/// An HTTP response: a [Reader] of the body, streamed from the socket.
///
/// - A non-2xx status is still a [Response]. [isSuccess] tests 200–299. The
///   readings ([text], [bytes]) work on any status, but only a 2xx body can
///   be piped: [stream] (and so `>`/`writeTo`) throws [HttpException] naming
///   the status and URL otherwise.
/// - [text] decodes with the charset in `content-type`, then
///   `<meta charset>`, then UTF-8 (WHATWG CJK decoders included). Unknown
///   charsets fall back to UTF-8; bad bytes become `�`.
/// - [close] drops an unread body. A body read or piped to the end releases
///   the connection by itself (back to the pool). The `Future<Response>`
///   mirrors (`Http.get(u).statusCode()`) close the response after reading:
///   a response reached only through a mirror can never be read later. (This
///   keeps the code; VISION §4.2 still says mirrors leave the body readable
///   and needs the fix, not the code.)
final class Response with Reader implements Closeable {
  Response._(this._resp, this._pool, this._timeout, this._url);

  final HttpClientResponse _resp;
  final _ClientPool _pool;
  final Duration _timeout;

  /// The final URL, after redirects.
  final String _url;

  Uint8List? _cached;
  var _streaming = false;
  var _closed = false;
  var _done = false;
  var _released = false;

  /// HTTP status code (e.g. 200, 404). Sync from when the headers arrive.
  int statusCode() => _resp.statusCode;

  /// Whether the status is 2xx.
  bool isSuccess() {
    final code = _resp.statusCode;
    return code >= 200 && code < 300;
  }

  /// Response header [name] (case-insensitive) or `null` if absent. The
  /// engine already lowercases keys, so this is one map lookup: O(1).
  String? header(String name) {
    final values = _resp.headers[name];
    if (values == null || values.isEmpty) return null;
    return values.join(', ');
  }

  /// The final URL, after redirects.
  String finalUrl() => _url;

  /// The `content-length`, or `null` when absent or unparseable.
  int? contentLength() {
    final value = header('content-length');
    if (value == null) return null;
    final n = int.tryParse(value.trim());
    if (n == null || n < 0) return null;
    return n;
  }

  /// A file name for the body: the `content-disposition` filename
  /// (`filename*=` wins over `filename=`, paths stripped), else the final
  /// URL's last segment, else `'download'`. Shared with scrape/chrome via
  /// `src/origin.dart`.
  String fileName() => names.fileName(
        url: _url,
        contentDisposition: header('content-disposition'),
      );

  /// Typed provenance: replaces `(reader as dynamic).url()`/`.status()`/
  /// `.name()` probes in `html`/`json`/`chrome`.
  @override
  Origin origin() => Origin(
        url: _url,
        status: _resp.statusCode,
        name: fileName(),
      );

  /// The body as text (see the class doc for the charset rules). Reads into
  /// memory and caches, so calling again (or [bytes]) is free. Works on any
  /// status.
  @override
  Future<String> text() async => charset.Charset.decode(
        await bytes(),
        contentType: header('content-type'),
      );

  /// The body as bytes, cached like [text]. Works on any status. Returns an
  /// unmodifiable view of the cache: O(1), no copy (returning
  /// `Uint8List.fromList` each call peaks at 2x the body).
  @override
  Future<List<int>> bytes() async {
    if (_closed) {
      throw StateError('response is closed: ${finalUrl()}');
    }
    final cached = _cached;
    if (cached != null) return cached.asUnmodifiableView();
    if (_streaming) {
      throw StateError('body already streaming: ${finalUrl()}');
    }
    _streaming = true;
    try {
      final out = BytesBuilder(copy: false);
      await for (final chunk in _bodyStream()) {
        out.add(chunk);
      }
      final flat = out.takeBytes();
      _cached = flat;
      return flat.asUnmodifiableView();
    } finally {
      _finish();
    }
  }

  @override
  Stream<List<int>> stream() {
    if (_closed) {
      throw StateError('response is closed: ${finalUrl()}');
    }
    final cached = _cached;
    if (cached != null) {
      if (!isSuccess()) {
        throw HttpException(
          'HTTP ${statusCode()}: ${finalUrl()}',
          uri: Uri.tryParse(finalUrl()),
        );
      }
      return Stream.value(cached.asUnmodifiableView());
    }
    if (_streaming) {
      throw StateError('body already streaming: ${finalUrl()}');
    }
    if (!isSuccess()) {
      // Only a 2xx body can be piped, so an error page is never saved.
      // Drop the body (releasing the pool count) and fail loudly; readings
      // still work only when the body was never piped.
      unawaited(close());
      throw HttpException(
        'HTTP ${statusCode()}: ${finalUrl()}',
        uri: Uri.tryParse(finalUrl()),
      );
    }
    _streaming = true;
    // async* so a downstream failure (a writer that throws mid-run, a pipe
    // that throws, a cancelled subscription) still releases the pool count
    // via the finally: without this the socket leaks.
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
    if (_closed || _done) {
      _releaseOnce();
      return;
    }
    _closed = true;
    try {
      // Drop, don't hang: a stalled body can't block close forever.
      // Drain with the response timeout (returning a small body to the
      // pool for reuse), then detach the socket when the drain stalls.
      try {
        await _resp.drain<void>().timeout(_timeout, onTimeout: () {
          throw TimeoutException('close timed out: $_url', _timeout);
        });
      } catch (_) {
        try {
          final socket = await _resp.detachSocket();
          try {
            socket.destroy();
          } catch (_) {}
        } catch (_) {}
      }
    } catch (_) {
      // Dropping must not throw.
    } finally {
      _finish();
    }
  }

  /// Abandon an error body without draining it: force-close the socket
  /// (the connection is discarded anyway) instead of waiting up to the full
  /// timeout for junk bytes. Used for 5xx/429 retries.
  Future<void> _abandon() async {
    if (_done) {
      _releaseOnce();
      return;
    }
    _closed = true;
    try {
      final socket = await _resp.detachSocket();
      try {
        socket.destroy();
      } catch (_) {}
    } catch (_) {}
    _finish();
  }

  Stream<List<int>> _bodyStream() => _resp.timeout(
        _timeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'body stalled for $_timeout: $_url',
              _timeout,
            ),
          );
        },
      );

  void _finish() {
    _done = true;
    _releaseOnce();
  }

  void _releaseOnce() {
    if (_released) return;
    _released = true;
    _pool.releaseResponse();
  }
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
///
/// Each mirror closes the response after reading: a response reached only
/// through a mirror can never be read later.
extension ResponseFuture on Future<Response> {
  Future<int> statusCode() async {
    final res = await this;
    try {
      return res.statusCode();
    } finally {
      await res.close();
    }
  }

  Future<bool> isSuccess() async {
    final res = await this;
    try {
      return res.isSuccess();
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

  Future<String> finalUrl() async {
    final res = await this;
    try {
      return res.finalUrl();
    } finally {
      await res.close();
    }
  }

  Future<int?> contentLength() async {
    final res = await this;
    try {
      return res.contentLength();
    } finally {
      await res.close();
    }
  }

  Future<String> fileName() async {
    final res = await this;
    try {
      return res.fileName();
    } finally {
      await res.close();
    }
  }
}

/// Retryable send failure, caught inside [_send] only.
final class _Retryable {
  _Retryable(this.cause);

  final Object cause;
}

({List<int> bytes, String? contentType}) _encodeBody(Body? body) {
  final b = body;
  if (b == null) return (bytes: const [], contentType: null);
  if (b is TextBody) {
    return (bytes: utf8.encode(b.text), contentType: 'text/plain; charset=utf-8');
  }
  if (b is BytesBody) return (bytes: b.bytes, contentType: null);
  if (b is FormBody) {
    return (
      bytes: utf8.encode(Uri(queryParameters: b.fields).query),
      contentType: 'application/x-www-form-urlencoded',
    );
  }
  if (b is JsonBody) {
    return (bytes: utf8.encode(jsonEncode(b.value)), contentType: 'application/json');
  }
  throw StateError('streamed body is not in-memory: $b');
}

Future<Response> _send(
  String method,
  String url, {
  Body? body,
  Map<String, String>? headers,
  Duration? timeout,
  int retries = 0,
  bool insecure = false,
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
  final resendable = body is! StreamBody;
  final pool = insecure ? _insecurePool : _securePool;
  var attempt = 0;
  Duration? retryAfter;
  while (true) {
    if (attempt > 0) {
      await Future<void>.delayed(retry.backoff(attempt - 1, retryAfter));
    }
    retryAfter = null;
    try {
      final res = await _attempt(method, first, body, headers, limit, pool);
      if (resendable &&
          (res.statusCode() == 429 || res.statusCode() >= 500) &&
          attempt < retries) {
        retryAfter = retry.parseRetryAfter(res.header('retry-after'));
        // Force-close the socket; don't drain the error body.
        await res._abandon();
        attempt++;
        continue;
      }
      return res;
    } on _Retryable catch (e) {
      if (!resendable || attempt >= retries || !retry.isRetryable(e.cause)) {
        throw e.cause;
      }
      attempt++;
    }
  }
}

/// One send: the request plus manual redirect following. Retryable network
/// failures arrive as [_Retryable]; anything else (including a redirect that
/// cannot resend a streamed body) throws as-is.
Future<Response> _attempt(
  String method,
  Uri first,
  Body? body,
  Map<String, String>? headers,
  Duration limit,
  _ClientPool pool,
) async {
  // Counted by the pool: one retain per attempt, transferred to the
  // delivered Response (which releases on finish), released on failure.
  final client = pool.retain();
  var ok = false;
  try {
    var currentMethod = method;
    var currentUri = first;
    Body? currentBody = body;
    Map<String, String>? currentHeaders = headers;
    for (var hop = 0; ; hop++) {
      HttpClientResponse resp;
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
        // TLS failures surface as HttpException on some paths; retry.dart
        // classifies them as permanent at the _send boundary.
        throw _Retryable(e);
      } on SocketException catch (e) {
        throw _Retryable(e);
      } on HandshakeException catch (e) {
        throw _Retryable(e);
      } on CertificateException catch (e) {
        throw _Retryable(e);
      } on TlsException catch (e) {
        throw _Retryable(e);
      } on IOException catch (e) {
        throw _Retryable(e);
      }
      if (!_isRedirect(resp.statusCode)) {
        ok = true;
        return Response._(resp, pool, limit, currentUri.toString());
      }
      final location = _locationOf(resp);
      if (location == null || location.isEmpty) {
        ok = true;
        return Response._(resp, pool, limit, currentUri.toString());
      }
      if (hop >= Http._maxRedirects) {
        await _detach(resp);
        throw HttpException(
          'too many redirects (>${Http._maxRedirects}): $currentUri',
          uri: currentUri,
        );
      }
      final next = currentUri.resolve(location);
      // Small redirect bodies drain back to the pool for reuse; a stalled
      // drain detaches instead of holding the next hop.
      await _discard(resp, limit);
      final code = resp.statusCode;
      if ((code == 301 || code == 302) && currentMethod == 'POST') {
        currentMethod = 'GET';
        currentBody = null;
        currentHeaders = _withoutContent(currentHeaders);
      } else if (code == 303) {
        if (currentMethod != 'HEAD') {
          currentMethod = 'GET';
          currentBody = null;
          currentHeaders = _withoutContent(currentHeaders);
        }
      } else if (currentBody is StreamBody) {
        // 307/308, or 301/302 keeping the method: resending would need the
        // bytes back, but a streamed body is gone. Failing loudly beats
        // silently downgrading to a GET without a body.
        throw HttpException(
          'redirect $code cannot resend a streamed body: $currentUri',
          uri: currentUri,
        );
      }
      if (currentUri.hasScheme &&
          next.hasScheme &&
          currentUri.origin != next.origin) {
        currentHeaders = _stripSensitiveHeaders(currentHeaders);
      }
      currentUri = next;
    }
  } catch (_) {
    if (!ok) pool.release();
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
/// O(1): the engine already lowercases keys.
String? _locationOf(HttpClientResponse resp) {
  final values = resp.headers['location'];
  if (values == null || values.isEmpty) return null;
  return values.first;
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

/// Send one request without following redirects. On a header timeout the
/// request is aborted (shared client: only this request, never the pool)
/// so a server that never reads the body cannot hang the send.
Future<HttpClientResponse> _singleSend(
  HttpClient client,
  String method,
  Uri uri,
  Body? body,
  Map<String, String>? headers,
  Duration limit,
) async {
  TimeoutException headerTimeout() =>
      TimeoutException('no headers for $limit: $uri', limit);
  HttpClientRequest req;
  try {
    req = await client.openUrl(method, uri).timeout(limit, onTimeout: () {
      throw headerTimeout();
    });
  } on HttpException {
    rethrow;
  }
  req.followRedirects = false;
  String? lengthHeader;
  if (headers != null) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-length') {
        lengthHeader = entry.value;
        continue;
      }
      try {
        req.headers.set(entry.key, entry.value);
      } on HttpException {
        // A restricted header (e.g. `host`): HttpClient owns it.
        rethrow;
      }
    }
  }
  final b = body;
  try {
    if (b is StreamBody) {
      final contentLength = lengthHeader;
      if (contentLength != null) {
        final n = int.tryParse(contentLength.trim());
        if (n == null || n < 0) {
          throw ArgumentError.value(
            contentLength,
            'headers[content-length]',
            'must be a non-negative integer',
          );
        }
        req.contentLength = n;
      } else {
        req.contentLength = -1;
      }
      req.bufferOutput = false;
      try {
        await req
            .addStream(b.reader.stream())
            .timeout(limit, onTimeout: () {
          throw TimeoutException('upload stalled for $limit: $uri', limit);
        });
      } catch (_) {
        try {
          req.abort();
        } catch (_) {}
        rethrow;
      }
      try {
        return await req.close().timeout(limit, onTimeout: () {
          throw headerTimeout();
        });
      } catch (_) {
        try {
          req.abort();
        } catch (_) {}
        rethrow;
      }
    }
    if (b == null) {
      req.contentLength = 0;
      try {
        return await req.close().timeout(limit, onTimeout: () {
          throw headerTimeout();
        });
      } catch (_) {
        try {
          req.abort();
        } catch (_) {}
        rethrow;
      }
    }
    final encoded = _encodeBody(b);
    req.contentLength = encoded.bytes.length;
    final contentType = encoded.contentType;
    if (contentType != null && !_hasHeader(req.headersToMap(), 'content-type')) {
      try {
        req.headers.set('content-type', contentType);
      } catch (_) {}
    }
    req.add(encoded.bytes);
    try {
      return await req.close().timeout(limit, onTimeout: () {
        throw headerTimeout();
      });
    } catch (_) {
      try {
        req.abort();
      } catch (_) {}
      rethrow;
    }
  } on ArgumentError {
    try {
      req.abort();
    } catch (_) {}
    rethrow;
  }
}

/// Drain a redirect body back to the pool; detach when the drain stalls.
Future<void> _discard(HttpClientResponse resp, Duration limit) async {
  try {
    await resp.drain<void>().timeout(limit);
  } catch (_) {
    await _detach(resp);
  }
}

/// Force-close a response's socket without waiting for its body.
Future<void> _detach(HttpClientResponse resp) async {
  try {
    final socket = await resp.detachSocket();
    try {
      socket.destroy();
    } catch (_) {}
  } catch (_) {}
}

extension on HttpClientRequest {
  /// This request's headers as a plain map for [_hasHeader].
  Map<String, String> headersToMap() {
    final out = <String, String>{};
    headers.forEach((name, values) {
      if (values.isNotEmpty) out[name] = values.join(', ');
    });
    return out;
  }
}
