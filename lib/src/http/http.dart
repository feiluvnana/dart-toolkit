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
/// The body streams: it is never pre-read. Read it once, then [close]. Every
/// body chunk waits at most [timeout]; a stall is a [TimeoutException].
final class Response implements Source, Reader {
  /// The status code, e.g. `200`.
  final int status;

  /// Response headers by lower-cased name, every value kept (`set-cookie` can repeat).
  /// Unmodifiable; [header] gives the first value.
  final Map<String, List<String>> headers;

  /// The final URL after redirects.
  final String url;

  /// The reason phrase, e.g. `Not Found` (it's in a failed reading's message).
  final String _reason;

  final StreamIterator<Uint8List> _it;
  final Duration _timeout;
  // The current chunk and how much of it is consumed: chunks pass through by
  // reference, never copied into a carry list.
  Uint8List _carry = Uint8List(0);
  int _off = 0;
  bool _done = false;
  bool _readerTaken = false;

  Response._(this.status, this.headers, this.url, this._reason, Stream<Uint8List> body, this._timeout)
    : _it = StreamIterator(body) {
    textCodecs[this] = TextCodec(
      (bytes) => _decodeBody(bytes, header('content-type')),
      () => _streamsText(header('content-type')),
    );
    // An unread body still releases its subscription on GC (never the shared
    // client: it outlives every response).
    _releaser.attach(this, _it, detach: this);
  }

  /// Releases an unread response's body subscription when nothing else does.
  static final _releaser = Finalizer<StreamIterator<Uint8List>>((it) {
    unawaited(() async {
      try {
        await it.cancel();
      } catch (_) {
        // Best effort: the response was never read.
      }
    }());
  });

  /// Whether the status is 2xx.
  bool get ok => status >= 200 && status < 300;

  /// One header, or `null`.
  String? header(String name) => headers[name.toLowerCase()]?.firstOrNull;

  /// The body's length from `content-length`, or null without one — and null
  /// when a `content-encoding` is set (dart:io gunzips, so the length is the
  /// compressed one, not the body's).
  @override
  int? get lengthHint {
    if (header('content-encoding') != null) return null;
    return int.tryParse(header('content-length') ?? '');
  }

  /// Fills [buf] with the next body bytes and answers how many were written.
  /// `0` means the body ended. Each chunk waits at most the timeout; a stall
  /// throws a [TimeoutException] unwrapped.
  @override
  Future<int> read(Uint8List buf) async {
    if (_done) return 0;
    while (_off >= _carry.length) {
      final hasNext = await _it.moveNext().timeout(_timeout);
      if (!hasNext) {
        _done = true;
        await _release();
        return 0;
      }
      _carry = _it.current;
      _off = 0;
      if (_carry.isEmpty) continue;
    }
    final n = math.min(buf.length, _carry.length - _off);
    buf.setRange(0, n, _carry, _off);
    _off += n;
    return n;
  }

  /// This response's body, strictly: a non-2xx closes the response and throws an
  /// [HttpException] carrying its status. A second call throws
  /// a [StateError] (the body reads once).
  @override
  Future<Reader> reader({int from = 0}) async {
    if (from != 0) {
      throw ArgumentError.value(from, 'from', 'Only 0: a sent response cannot seek');
    }
    if (_readerTaken) throw StateError('body already read');
    _readerTaken = true;
    return _bodyReader();
  }

  /// The strict body reader: a non-2xx closes the response and throws an
  /// [HttpException] carrying its status.
  Future<Reader> _bodyReader() async {
    if (!ok) {
      await close();
      throw HttpException('$status $_reason', uri: Uri.tryParse(url), status: status);
    }
    return this;
  }

  Future<void> _release() async {
    _releaser.detach(this);
    try {
      await _it.cancel();
    } catch (_) {
      // Already done: nothing to cancel. (The shared client is never closed
      // per response: it lives for the isolate, idle 15 s.)
    }
  }

  /// Cancels the body stream and releases the connection.
  @override
  Future<void> close() async {
    _done = true;
    _carry = Uint8List(0);
    _off = 0;
    await _release();
  }
}

/// A request that is sent on first use: `await` gives the [Response]; a reading or `pipe` reads
/// the body. Sending late lets `pipe(file, resume: true)` add a `Range` header.
final class Request implements Future<Response>, Source {
  Request._(this._method, this._url, this._headers, this._timeout, this._retry, this._body) {
    textCodecs[this] = TextCodec(
      (bytes) => _decodeBody(bytes, _response?.header('content-type')),
      () => _streamsText(_response?.header('content-type')),
    );
  }

  final String _method;
  final String _url;
  final Map<String, String>? _headers;
  final Duration? _timeout;
  final int? _retry;
  final _Body? _body;
  Future<Response>? _sent;
  int _from = 0;
  bool _readerTaken = false;
  Response? _response;

  Future<Response> get _resp => _sent ??= Http._withRetry(
    _method,
    _url,
    headers: {...?_headers, if (_from > 0) 'range': 'bytes=$_from-'},
    timeout: _timeout,
    retry: _retry,
    body: _body,
  );

  /// The body's length from the response's `content-length` once sent,
  /// else null — and null when a `content-encoding` is set (the length is
  /// the compressed one, not the body's).
  @override
  int? get lengthHint {
    return _response?.lengthHint;
  }

  @override
  Future<Reader> reader({int from = 0}) async {
    if (_readerTaken) throw StateError('body already read');
    _readerTaken = true;
    if (_sent != null && from != _from) throw StateError('Request already sent');
    _from = from;
    final resp = await _resp;
    _response = resp;
    if (from > 0 && resp.status == 416) {
      // The file is already complete when the server's total is what we hold:
      // no byte is copied. Anything else is a failed resume.
      await resp.close();
      if (_rangeTotal(resp.header('content-range')) == from) return _EmptyReader();
      throw HttpException('Server cannot resume from $from', uri: Uri.parse(_url), status: 416);
    }
    if (from > 0 && resp.status == 200) {
      // The server ignored Range: restart. pipe() sees `from` bytes too many; signal it.
      await resp.close();
      throw HttpException('Server does not support resume', uri: Uri.parse(_url), status: 200);
    }
    if (from > 0 && resp.status == 206 && _rangeStart(resp.header('content-range')) != from) {
      // The server resumed from somewhere else: refuse rather than interleave.
      await resp.close();
      throw HttpException('Server resumed from the wrong offset', uri: Uri.parse(_url), status: 206);
    }
    return resp._bodyReader();
  }

  @override
  Stream<Response> asStream() => _resp.asStream();
  @override
  Future<Response> catchError(Function onError, {bool Function(Object error)? test}) =>
      _resp.catchError(onError, test: test);
  @override
  Future<R> then<R>(FutureOr<R> Function(Response value) onValue, {Function? onError}) =>
      _resp.then(onValue, onError: onError);
  @override
  Future<Response> timeout(Duration timeLimit, {FutureOr<Response> Function()? onTimeout}) =>
      _resp.timeout(timeLimit, onTimeout: onTimeout);
  @override
  Future<Response> whenComplete(FutureOr<void> Function() action) => _resp.whenComplete(action);
}

/// A [Reader] with no bytes: a resumed download already complete.
final class _EmptyReader implements Reader {
  @override
  Future<int> read(Uint8List buf) async => 0;

  @override
  Future<void> close() async {}
}

/// Whether a body with these response headers streams as UTF-8 text: a
/// declared UTF-8/ASCII charset, or no charset on a non-HTML body. HTML
/// without a declared charset may hide a legacy `<meta charset>`, so it
/// decodes whole instead.
bool _streamsText(String? contentType) {
  final label = _declaredCharset(contentType)?.toLowerCase();
  if (label == null) return !(contentType?.toLowerCase().contains('html') ?? false);
  return label == 'utf-8' || label == 'utf8' || label == 'unicode-1-1-utf-8' || label == 'us-ascii' || label == 'ascii';
}

/// The start byte of a `Content-Range: bytes N-M/T`, or null without one.
int? _rangeStart(String? value) {
  if (value == null) return null;
  final m = RegExp(r'bytes (\d+)-\d+/').firstMatch(value);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// The total of a `Content-Range: bytes */N`, or null without one.
int? _rangeTotal(String? value) {
  if (value == null) return null;
  final m = RegExp(r'bytes \*/(\d+)').firstMatch(value);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// One `HttpClient` per isolate: creating one per request means no
/// keep-alive (every request handshakes). Idle sockets linger 15 s.
abstract final class _SharedClient {
  static io.HttpClient? _client;

  static io.HttpClient get current {
    final hit = _client;
    if (hit != null) return hit;
    final fresh = io.HttpClient()..idleTimeout = const Duration(seconds: 15);
    return _client = fresh;
  }
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
/// ask for the rest with `Range`. Idempotent requests (and re-readable bodies)
/// are retried twice on 5xx or network errors ([retry]), backing off
/// `250 ms × 2^attempt` and honouring `Retry-After`; anything else retries
/// only with an explicit [retry]. Every body chunk waits 30 s by default
/// ([timeout]).
abstract final class Http {
  static const Duration _timeout = Duration(seconds: 30);
  static const int _retries = 2;

  /// A GET of [url], sent on first use: `await` gives the [Response], a reading
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

  static Future<Response> _withRetry(
    String method,
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
    _Body? body,
  }) async {
    // N6: only idempotent requests retry — GET/HEAD/PUT/DELETE, or a body that
    // can be re-read (a File). Anything else retries only with an explicit
    // retry:, and a consumed stream body never retries (its bytes are gone).
    final idempotent = method == 'GET' || method == 'HEAD' || method == 'PUT' || method == 'DELETE';
    final rereadableBody = body is _SourceBody && body.source is fs.File;
    final resendable = body == null || body is _JsonBody || body is _FormBody || rereadableBody;
    final retryableCall = resendable && (idempotent || rereadableBody || retry != null);
    final attempts = (retry ?? _retries) + 1;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final resp = await _send(method, url, headers: headers, timeout: timeout ?? _timeout, body: body);
        if (resp.status >= 500 && attempt < attempts && retryableCall) {
          lastError = HttpException('${resp.status} ${resp._reason}', uri: Uri.tryParse(url), status: resp.status);
          final wait = _retryDelay(attempt, resp.header('retry-after'));
          await resp.close();
          await Future<void>.delayed(wait);
          continue;
        }
        return resp;
      } on HttpException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt >= attempts) break;
        if (!_retryable(e)) break;
        if (!retryableCall) break;
        await Future<void>.delayed(_retryDelay(attempt, null));
      }
    }
    if (lastError is HttpException) throw lastError;
    // A timeout stays a timeout, never an HttpException.
    if (lastError is TimeoutException) throw lastError;
    throw HttpException('Request failed: $lastError', uri: Uri.tryParse(url), cause: lastError);
  }

  static bool _retryable(Object e) => e is io.SocketException || e is io.HttpException || e is TimeoutException;

  /// How long before retry number [attempt] (1-based): `250 ms × 2^attempt`
  /// with jitter, honouring a `Retry-After` (seconds or HTTP date, capped at
  /// 30 s) when the server gave one.
  static Duration _retryDelay(int attempt, String? retryAfter) {
    final backoff = Duration(milliseconds: 250 * (1 << (attempt - 1)) + math.Random().nextInt(100));
    if (retryAfter == null) return backoff;
    final secs = _retryAfterSecs(retryAfter);
    if (secs == null) return backoff;
    final instructed = Duration(seconds: secs > 30 ? 30 : secs);
    return instructed > backoff ? instructed : backoff;
  }

  /// [value] as seconds to wait: a number, or an HTTP date's distance from
  /// now (past dates wait nothing); null when it is neither.
  static int? _retryAfterSecs(String value) {
    final secs = int.tryParse(value.trim());
    if (secs != null) return secs < 0 ? 0 : secs;
    try {
      final wait = io.HttpDate.parse(value.trim()).difference(DateTime.now().toUtc()).inSeconds;
      return wait < 0 ? 0 : wait;
    } catch (_) {
      // Not a date either: fall back to the backoff.
      return null;
    }
  }

  static Future<Response> _send(
    String method,
    String url, {
    Map<String, String>? headers,
    required Duration timeout,
    _Body? body,
  }) async {
    // One client per isolate, kept alive 15 s: sequential requests share the
    // socket instead of handshaking each time.
    final client = _SharedClient.current;
    final request = await client.openUrl(method, Uri.parse(url)).timeout(timeout);
    headers?.forEach(request.headers.set);
    if (body != null) await _writeBody(request, body);
    final response = await request.close().timeout(timeout);
    final respHeaders = <String, List<String>>{};
    response.headers.forEach((name, values) => respHeaders[name.toLowerCase()] = List.unmodifiable(values));
    // Each redirect hop resolves against the previous URL, so the final one
    // is absolute even when a hop said `/final?q=1`.
    var current = Uri.parse(url);
    for (final hop in response.redirects) {
      current = current.resolveUri(hop.location);
    }
    final resp = Response._(
      response.statusCode,
      Map.unmodifiable(respHeaders),
      current.toString(),
      response.reasonPhrase,
      response.map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
      timeout,
    );
    // A non-2xx body never reads (readings are strict): settle it now, so an
    // awaited-but-unread response holds no socket — small bodies drain back
    // into the pool, big or stalled ones are destroyed instead.
    if (!resp.ok) {
      await _settleErrorBody(response, timeout);
      await resp.close();
    }
    return resp;
  }

  /// Settles a non-2xx body the caller will never read: drains it (up to
  /// 1 MiB) so its connection pools, else detaches and destroys the socket.
  /// A stall detaches too, bounded by [timeout] — never a hang.
  static Future<void> _settleErrorBody(io.HttpClientResponse response, Duration timeout) async {
    const cap = 1024 * 1024;
    try {
      await (() async {
        var total = 0;
        await for (final chunk in response) {
          total += chunk.length;
          if (total > cap) {
            try {
              (await response.detachSocket()).destroy();
            } catch (_) {
              // Already gone: nothing to destroy.
            }
            return;
          }
        }
      })().timeout(timeout);
    } on TimeoutException {
      try {
        (await response.detachSocket()).destroy();
      } catch (_) {
        // Already gone: nothing to destroy.
      }
    } catch (_) {
      // The body broke mid-way: nothing left to pool.
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
