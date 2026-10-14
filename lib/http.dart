/// Minimal HTTP client. Thin facade over SDK `dart:io` `HttpClient`.
///
/// ```dart
/// final user = await Http.get('https://api.example.com/me',
///     headers: {'authorization': token}).json();
/// await (Http.get(url) > Fs.file('page.html'));
/// await Http.put('https://cdn.example.com/d.iso', body: .stream(Fs.file('d.iso')));
/// ```
///
/// Public surface is exactly: [Http], [Response], [Body].
/// - `Http.get/head/delete/options/post/put/patch()` return a [Response].
/// - [Response] supports `status` `ok` `header` `url`
///   `size` `name` (plus [Reader]/[Closeable]).
/// - [Body] is a sealed request body: `.text` `.bytes` `.form` `.json`
///   `.stream`. A [Body.stream] is sent once and never retried.
/// A non-2xx status is still a [Response]; only network failures and
/// timeouts throw. Everything else is private.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core.dart';
export 'core.dart';

import 'src/abort.dart' as abort;
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
  const factory Body.text(String text) = _TextBody;

  /// Raw bytes; no default `content-type`.
  const factory Body.bytes(List<int> bytes) = _BytesBody;

  /// URL-encoded form (`application/x-www-form-urlencoded`).
  const factory Body.form(Map<String, String> fields) = _FormBody;

  /// `jsonEncode(value)` as `application/json`.
  const factory Body.json(Object? value) = _JsonBody;

  /// Streamed from [reader]: sent once, never retried.
  const factory Body.stream(Reader reader) = _StreamBody;
}

final class _TextBody extends Body {
  const _TextBody(this._text) : super._();

  final String _text;
}

final class _BytesBody extends Body {
  const _BytesBody(this._bytes) : super._();

  final List<int> _bytes;
}

final class _FormBody extends Body {
  const _FormBody(this._fields) : super._();

  final Map<String, String> _fields;
}

final class _JsonBody extends Body {
  const _JsonBody(this._value) : super._();

  final Object? _value;
}

/// A streamed body. Sent once, never retried: a 307/308 (or a 301/302 that
/// keeps the method) that would need the bytes back throws [HttpException]
/// naming the limitation instead of silently downgrading.
final class _StreamBody extends Body {
  const _StreamBody(this._reader) : super._();

  final Reader _reader;
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
///   naming the limitation. `url()` is the final URL.
/// - `body` is a [Body] (`.text`/`.bytes`/`.form`/`.json`/`.stream`).
/// - `insecure` accepts a bad certificate for this call only (one broken CDN
///   chain): it uses the shared insecure client, scoped to the request and
///   visible at the call site. It replaces the example's hand-written
///   `_getPageInsecure` (~40 lines of `dart:io`).
/// - `retries` re-sends GET/HEAD/OPTIONS/PUT/DELETE (never POST or PATCH) on network errors, timeouts, 5xx and 429, with
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
  static Closeable hold() {
    _securePool._hold();
    _insecurePool._hold();
    return _Hold._();
  }

  /// Cancel every in-flight request and body read (they fail with an
  /// [HttpException]; retries stop). Use when quitting a UI with downloads running.
  static void abort() {
    _abortEpoch++;
    for (final w in [..._sleepers]) {
      w.timer.cancel();
      w.done.complete();
    }
    _sleepers.clear();
    _securePool._abort();
    _insecurePool._abort();
  }

  /// GET [url] with optional [headers], [timeout], [retries] and [insecure].
  static Future<Response> get(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'GET',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );

  /// HEAD [url] with optional [headers], [timeout], [retries] and [insecure].
  static Future<Response> head(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'HEAD',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );

  /// DELETE [url] with optional [headers], [timeout], [retries] and
  /// [insecure].
  static Future<Response> delete(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'DELETE',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );

  /// OPTIONS [url] with optional [headers], [timeout], [retries] and
  /// [insecure].
  static Future<Response> options(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'OPTIONS',
        url,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );

  /// POST [url] with a [Body] (`body: .json(item)`).
  static Future<Response> post(
    String url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'POST',
        url,
        body: body,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );

  /// PUT [url] with a [Body] (same as [post]).
  static Future<Response> put(
    String url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'PUT',
        url,
        body: body,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );

  /// PATCH [url] with a [Body] (same as [post]).
  static Future<Response> patch(
    String url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int retries = 0,
    bool insecure = false,
    bool check = false,
  }) =>
      _send(
        'PATCH',
        url,
        body: body,
        headers: headers,
        timeout: timeout,
        retries: retries,
        insecure: insecure,
        check: check,
      );
}

/// Keeps the shared client open ([Http.hold]). Close to release; idempotent.
final class _Hold implements Closeable {
  _Hold._();

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

  void _abort() {
    final c = _client;
    _client = null;
    try {
      c?.close(force: true);
    } catch (_) {}
  }

  void _hold() {
    _holds++;
  }

  void _unhold() {
    _holds--;
    assert(_holds >= 0, 'client pool hold over-released');
    if (_active == 0 && _holds == 0) Timer.run(_maybeClose);
  }

  void _maybeClose() {
    if (_active != 0 || _holds != 0) return;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}

/// Bumped by [Http.abort]; a send that started before it never retries.
var _abortEpoch = 0;

/// Pending retry backoffs, woken early by [Http.abort] so they cannot keep the VM alive.
final _sleepers = <({Timer timer, Completer<void> done})>{};

Future<void> _sleep(Duration d, abort.AbortSignal? signal) {
  final done = Completer<void>();
  late final ({Timer timer, Completer<void> done}) w;
  w = (
    timer: Timer(d, () {
      _sleepers.remove(w);
      done.complete();
    }),
    done: done,
  );
  _sleepers.add(w);
  signal?.future.then((_) {
    w.timer.cancel();
    _sleepers.remove(w);
    if (!done.isCompleted) done.complete();
  });
  return done.future;
}

final _securePool = _ClientPool(insecure: false);
final _insecurePool = _ClientPool(insecure: true);

/// An HTTP response: a [Reader] of the body, streamed from the socket.
///
/// - A non-2xx status is still a [Response]. [ok] tests 200–299. The
///   readings ([text], [bytes]) work on any status, but only a 2xx body can
///   be piped: [stream] (and so `>`/`to`) throws [HttpException] naming
///   the status and URL otherwise.
/// - [text] decodes with the charset in `content-type`, then
///   `<meta charset>`, then UTF-8 (WHATWG CJK decoders included). Unknown
///   charsets fall back to UTF-8; bad bytes become `�`.
/// - [close] drops an unread body. A body read or piped to the end releases
///   the connection by itself (back to the pool). The `Future<Response>`
///   mirrors (`Http.get(u).status()`) close the response after reading:
///   a response reached only through a mirror can never be read later. (This
///   keeps the code; VISION §4.2 still says mirrors leave the body readable
///   and needs the fix, not the code.)
final class Response with Reader implements Closeable {
  Response._(this._resp, this._pool, this._timeout, this._url, {this._head = false});

  final HttpClientResponse _resp;
  final _ClientPool _pool;
  final Duration _timeout;

  /// The final URL, after redirects.
  final String _url;

  /// A HEAD response: no body follows, whatever `content-length` says.
  final bool _head;

  Uint8List? _cached;
  Future<Uint8List>? _reading;
  var _streaming = false;
  var _closed = false;
  var _done = false;
  var _released = false;

  /// HTTP status code (e.g. 200, 404). Sync from when the headers arrive.
  int status() => _resp.statusCode;

  /// Whether the status is 2xx.
  bool ok() {
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
  /// URL's last segment, else `'download'`. Shared with scrape/chrome via
  /// `src/origin.dart`.
  String name() => names.fileName(
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
      throw StateError('response is closed: ${names.redact(url())}');
    }
    final cached = _cached;
    if (cached != null) return cached.asUnmodifiableView();
    // A second read while the first runs shares it.
    final reading = _reading;
    if (reading != null) return (await reading).asUnmodifiableView();
    if (_streaming) {
      throw StateError('body already streaming: ${names.redact(url())}');
    }
    _streaming = true;
    return (await (_reading = _readAll())).asUnmodifiableView();
  }

  Future<Uint8List> _readAll() async {
    try {
      final out = BytesBuilder(copy: false);
      await for (final chunk in _bodyStream()) {
        out.add(chunk);
      }
      return _cached = out.takeBytes();
    } finally {
      _reading = null;
      _finish();
    }
  }

  @override
  Stream<List<int>> stream() {
    if (_closed) {
      throw StateError('response is closed: ${names.redact(url())}');
    }
    final cached = _cached;
    if (cached != null) {
      if (!ok()) {
        throw HttpException(
          'HTTP ${status()}: ${names.redact(url())}',
          uri: Uri.tryParse(names.redact(url())),
        );
      }
      return Stream.value(cached.asUnmodifiableView());
    }
    if (_streaming) {
      throw StateError('body already streaming: ${names.redact(url())}');
    }
    if (!ok()) {
      // Only a 2xx body can be piped, so an error page is never saved.
      // Drop the body (releasing the pool count) and fail loudly; readings
      // still work only when the body was never piped.
      unawaited(close());
      throw HttpException(
        'HTTP ${status()}: ${names.redact(url())}',
        uri: Uri.tryParse(names.redact(url())),
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
    // HEAD, 204 and 304 carry no body whatever content-length says, so the
    // connection goes straight back to the pool.
    final empty = _head || status() == 204 || status() == 304;
    final len = empty ? 0 : size();
    if (len == null || len > 64 * 1024) return _abandon();
    _closed = true;
    try {
      // Small known-length bodies drain back to the pool for reuse. The
      // drain gets a short budget, not the request timeout: the caller is
      // done, so a slow body detaches the socket instead of waiting.
      try {
        await _resp.drain<void>().timeout(_drainBudget);
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

  /// The first 200 characters of the body, whitespace collapsed, then the
  /// body is abandoned. Empty when unreadable.
  Future<String> _snippet() async {
    final out = BytesBuilder(copy: false);
    try {
      if (!_streaming && !_closed && !_done) {
        _streaming = true;
        await for (final chunk in _bodyStream()) {
          out.add(chunk);
          if (out.length >= 1024) break;
        }
      }
    } catch (_) {}
    await _abandon();
    final text = charset.Charset.decode(out.takeBytes(),
        contentType: header('content-type'));
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 200 ? '${flat.substring(0, 200)}...' : flat;
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
              'body stalled for $_timeout: ${names.redact(_url)}',
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
    _pool.release();
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

/// Retryable send failure, caught inside [_send] only.
final class _Retryable {
  _Retryable(this.cause);

  final Object cause;
}

({List<int> bytes, String? contentType}) _encodeBody(Body? body) {
  final b = body;
  if (b == null) return (bytes: const [], contentType: null);
  return switch (b) {
    _TextBody() => (bytes: utf8.encode(b._text), contentType: 'text/plain; charset=utf-8'),
    _BytesBody() => (bytes: b._bytes, contentType: null),
    _FormBody() => (
        bytes: utf8.encode(Uri(queryParameters: b._fields).query),
        contentType: 'application/x-www-form-urlencoded',
      ),
    _JsonBody() => (bytes: utf8.encode(jsonEncode(b._value)), contentType: 'application/json'),
    _StreamBody() => throw StateError('streamed body is not in-memory: $b'),
  };
}

/// Verbs a retry may re-send: POST and PATCH could repeat an effect the server already committed.
const _idempotent = {'GET', 'HEAD', 'OPTIONS', 'PUT', 'DELETE'};

Future<Response> _send(
  String method,
  String url, {
  Body? body,
  Map<String, String>? headers,
  Duration? timeout,
  int retries = 0,
  bool insecure = false,
  bool check = false,
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
  final resendable = body is! _StreamBody && _idempotent.contains(method);
  final pool = insecure ? _insecurePool : _securePool;
  var attempt = 0;
  final epoch = _abortEpoch;
  final signal = abort.currentAbort();
  bool aborted() => epoch != _abortEpoch || (signal?.aborted ?? false);
  Duration? retryAfter;
  while (true) {
    if (attempt > 0) {
      await _sleep(retry.backoff(attempt - 1, retryAfter), signal);
      if (aborted()) throw const HttpException('aborted');
    }
    retryAfter = null;
    try {
      final res = await _attempt(method, first, body, headers, limit, pool);
      if (resendable &&
          (res.status() == 429 || res.status() >= 500) &&
          attempt < retries) {
        retryAfter = retry.parseRetryAfter(res.header('retry-after'));
        // Force-close the socket; don't drain the error body.
        await res._abandon();
        attempt++;
        continue;
      }
      if (check && !res.ok()) {
        final snippet = await res._snippet();
        throw HttpException(
          'HTTP ${res.status()} $method ${names.redact(res.url())}${snippet.isEmpty ? '' : ': $snippet'}',
          uri: Uri.tryParse(names.redact(res.url())),
        );
      }
      return res;
    } on _Retryable catch (e) {
      if (aborted() ||
          !resendable ||
          attempt >= retries ||
          !retry.isRetryable(e.cause)) {
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
      final head = currentMethod == 'HEAD';
      if (!_isRedirect(resp.statusCode)) {
        ok = true;
        return Response._(resp, pool, limit, currentUri.toString(), head: head);
      }
      final location = _locationOf(resp);
      if (location == null || location.isEmpty) {
        ok = true;
        return Response._(resp, pool, limit, currentUri.toString(), head: head);
      }
      if (hop >= Http._maxRedirects) {
        await _detach(resp);
        throw HttpException(
          'too many redirects (>${Http._maxRedirects}): ${names.redact(currentUri)}',
          uri: Uri.parse(names.redact(currentUri)),
        );
      }
      // Small redirect bodies drain back to the pool for reuse; a stalled
      // drain detaches instead of holding the next hop.
      await _discard(resp);
      final parsed = Uri.tryParse(location);
      final next = parsed == null ? null : currentUri.resolveUri(parsed);
      if (next == null || (next.scheme != 'http' && next.scheme != 'https') || next.host.isEmpty) {
        throw HttpException('redirect to an unsupported URL "${names.redact(location)}": ${names.redact(currentUri)}',
            uri: Uri.parse(names.redact(currentUri)));
      }
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
      } else if (currentBody is _StreamBody) {
        // 307/308, or 301/302 keeping the method: resending would need the
        // bytes back, but a streamed body is gone. Failing loudly beats
        // silently downgrading to a GET without a body.
        throw HttpException(
          'redirect $code cannot resend a streamed body: ${names.redact(currentUri)}',
          uri: Uri.parse(names.redact(currentUri)),
        );
      }
      if (currentUri.scheme != next.scheme ||
          currentUri.host != next.host ||
          currentUri.port != next.port) {
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

/// Headers a cross-origin hop must not carry: the standard credentials and
/// any custom one named like a secret (`X-Api-Key`, `Private-Token`, …).
Map<String, String>? _stripSensitiveHeaders(Map<String, String>? headers) {
  if (headers == null) return null;
  final out = Map<String, String>.of(headers);
  out.removeWhere((key, _) => names.isSecretHeader(key));
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
      TimeoutException('no headers for $limit: ${names.redact(uri)}', limit);
  final req = await client.openUrl(method, uri).timeout(limit, onTimeout: () {
    throw headerTimeout();
  });
  req.followRedirects = false;
  // A scoped abort (a cancelled crawl) fails this request and its body.
  final signal = abort.currentAbort();
  if (signal != null) {
    if (signal.aborted) {
      req.abort(const HttpException('aborted'));
      throw const HttpException('aborted');
    }
    signal.future.then((_) => req.abort(const HttpException('aborted')));
  }
  String? lengthHeader;
  if (headers != null) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-length') {
        lengthHeader = entry.value;
        continue;
      }
      req.headers.set(entry.key, entry.value);
    }
  }
  final b = body;
  try {
    if (b is _StreamBody) {
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
        await _upload(req, b._reader.stream(), limit, uri);
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
    try {
      await _upload(req, _slices(encoded.bytes), limit, uri);
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

/// Send [body] on [req], failing only when no chunk moves for [limit]: a
/// long upload that keeps moving never times out, a server that stops
/// reading does (backpressure stops the pulls, so the watchdog fires).
Future<void> _upload(HttpClientRequest req, Stream<List<int>> body, Duration limit, Uri uri) async {
  final stalled = Completer<void>();
  Timer? watchdog;
  void arm() {
    watchdog?.cancel();
    watchdog = Timer(limit, () {
      if (!stalled.isCompleted) stalled.completeError(TimeoutException('upload stalled for $limit: ${names.redact(uri)}', limit));
    });
  }

  arm();
  final sending = req.addStream(body.map((chunk) {
    arm();
    return chunk;
  }));
  sending.ignore();
  try {
    await Future.any([sending, stalled.future]);
  } finally {
    watchdog?.cancel();
  }
}

/// [bytes] as 64 KiB views, so an in-memory upload is watched per chunk too.
Stream<List<int>> _slices(List<int> bytes) async* {
  const size = 64 * 1024;
  for (var i = 0; i < bytes.length; i += size) {
    final end = i + size > bytes.length ? bytes.length : i + size;
    yield bytes is Uint8List ? Uint8List.sublistView(bytes, i, end) : bytes.sublist(i, end);
  }
}

/// How long a body nobody reads may take to drain back to the pool before
/// its socket is detached instead.
const _drainBudget = Duration(milliseconds: 200);

/// Drain a redirect body back to the pool; detach when the drain stalls.
Future<void> _discard(HttpClientResponse resp) async {
  try {
    await resp.drain<void>().timeout(_drainBudget);
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
