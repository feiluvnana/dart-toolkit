import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/traits.dart';
import '../fs/io.dart' as fs;
import '../json/json.dart';

/// What the network said, as text: the base of [ClientException] and
/// [StatusException], so `on HttpException` catches every way a request fails
/// but running out of time (a [TimeoutException]).
class HttpException implements Exception {
  /// What went wrong.
  final String message;

  /// The URL that was asked for, when there is one.
  final Uri? uri;

  const HttpException(this.message, {this.uri});

  @override
  String toString() => uri == null ? 'HttpException: $message' : 'HttpException: $message from $uri';
}

/// The network said no before an answer came: a refused or reset connection,
/// a TLS failure, too many redirects. An [HttpException], as a non-2xx
/// [StatusException] is.
class ClientException extends HttpException {
  /// What the transport threw (a `SocketException`) when this wraps one.
  final Object? cause;

  const ClientException(super.message, {super.uri, this.cause});
}

/// A non-2xx answer: an [HttpException] that keeps the [response], so an
/// API's error body is still there:
///
/// ```dart
/// try {
///   await Http.get(url).json();
/// } on StatusException catch (e) {
///   print(e.response.text());
/// }
/// ```
final class StatusException extends HttpException {
  /// The answer, body read.
  final Resp response;

  StatusException(this.response)
    : super('${response.status} ${response.reason} from ${response.url}', uri: Uri.tryParse(response.url));

  @override
  String toString() => message;
}

/// A streaming HTTP response, itself a [Reader] for zero-allocation piping:
///
/// ```dart
/// await Http.get('https://example.com/huge.iso').pipe(File('huge.iso'));
/// final data = await Http.get('https://api.site.com/users').json();
/// ```
///
/// The body streams: it is never pre-read. Read it once — with [pipe],
/// [bytes], [text], [json] — then [close]. A second reading answers `0`/throws.
/// [text], [bytes] and [json] are strict: a non-2xx throws a [StatusException]
/// holding the error body (r44); check [ok] first when a non-2xx is data.
final class Resp implements Reader, Closer {
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

  /// A response already in hand (error bodies kept by [StatusException]).
  Resp.detached(this.status, this.headers, Uint8List body, this.url, {this.reason = ''})
    : _client = _closedClient,
      _it = StreamIterator(Stream.value(body));

  static io.HttpClient get _closedClient => io.HttpClient()..close(force: true);

  /// Whether the status is 2xx.
  bool get ok => status >= 200 && status < 300;

  /// Whether the status is 4xx.
  bool get isClientError => status >= 400 && status < 500;

  /// Whether the status is 5xx.
  bool get isServerError => status >= 500;

  /// One header, or `null`.
  String? header(String name) => headers[name.toLowerCase()];

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

  /// The body bytes. Strict: a non-2xx throws a [StatusException].
  Future<Uint8List> bytes({Duration? timeout}) async {
    final collected = await _collect(timeout: timeout);
    return Uint8List.fromList(collected);
  }

  /// The body decoded as UTF-8. Strict: a non-2xx throws a [StatusException].
  Future<String> text({Duration? timeout}) async {
    final collected = await _collect(timeout: timeout);
    return utf8.decode(collected, allowMalformed: true);
  }

  /// The body parsed as JSON. Strict: a non-2xx throws a [StatusException].
  Future<dynamic> json({Duration? timeout}) async => Json.parse(await text(timeout: timeout));

  Future<List<int>> _collect({Duration? timeout}) async {
    if (_done && _carry.isEmpty) {
      // Already consumed through read(): the remainder is nothing.
      _throwIfError(const []);
      return const [];
    }
    final collected = await _drain(timeout: timeout);
    _throwIfError(collected);
    return collected;
  }

  /// Collects the remaining body without status checks (retries, error keeps).
  Future<Uint8List> drain({Duration? timeout}) async => Uint8List.fromList(await _drain(timeout: timeout));

  Future<List<int>> _drain({Duration? timeout}) async {
    Future<List<int>> collect() async {
      final out = <int>[..._carry];
      _carry.clear();
      final chunk = Uint8List(64 * 1024);
      while (true) {
        final n = await read(chunk);
        if (n <= 0) break;
        out.addAll(chunk.sublist(0, n));
      }
      return out;
    }

    return timeout == null ? collect() : collect().timeout(timeout);
  }

  void _throwIfError(List<int> collected) {
    if (!ok) {
      throw StatusException(Resp.detached(status, headers, Uint8List.fromList(collected), url, reason: reason));
    }
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

/// A tiny HTTP/1.1 client on `dart:io`: `Http.get`, [post], [put], [delete], [head].
///
/// ```dart
/// final res = await Http.get('https://api.example.com/data');
/// if (res.ok) print(await res.json());
/// await Http.get('https://example.com/huge.iso').pipe(File('huge.iso'));
/// ```
///
/// Every request is retried twice on 5xx or network errors ([retry]), with
/// 30 s per response by default ([timeout]). A [body] that is a [Reader]
/// (e.g. a `File`) streams with chunked encoding — never materialised; a
/// `Map` body is form-encoded, `json:` is sent as JSON.
abstract final class Http {
  /// The default per-response timeout.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// The default retry count on 5xx or network errors.
  static const int defaultRetries = 2;

  /// Sends a GET to [url].
  static Future<Resp> get(String url, {Map<String, String>? headers, Duration? timeout, int? retry}) =>
      _withRetry('GET', url, headers: headers, timeout: timeout, retry: retry);

  /// Sends a HEAD to [url].
  static Future<Resp> head(String url, {Map<String, String>? headers, Duration? timeout, int? retry}) =>
      _withRetry('HEAD', url, headers: headers, timeout: timeout, retry: retry);

  /// Sends a POST; [json] is serialised and sent as JSON, [body] is sent as
  /// form fields (a `Map`), verbatim (a `String`/bytes), or streamed (a
  /// [Reader], e.g. a `File`).
  static Future<Resp> post(
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => _withRetry('POST', url, json: json, body: body, headers: headers, timeout: timeout, retry: retry);

  /// Sends a PUT.
  static Future<Resp> put(
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => _withRetry('PUT', url, json: json, body: body, headers: headers, timeout: timeout, retry: retry);

  /// Sends a PATCH.
  static Future<Resp> patch(
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => _withRetry('PATCH', url, json: json, body: body, headers: headers, timeout: timeout, retry: retry);

  /// Sends a DELETE.
  static Future<Resp> delete(
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) => _withRetry('DELETE', url, json: json, body: body, headers: headers, timeout: timeout, retry: retry);

  /// Streams [url] into the [Writer] [dst] (e.g. a `File`), returning the bytes copied.
  ///
  /// A non-2xx throws a [StatusException] and writes nothing. With [resume]
  /// and a `File` destination, an interrupted download continues: the
  /// existing size is asked for with `Range`, a `206` is appended, a `200`
  /// restarts from the beginning.
  static Future<int> download(
    String url,
    Writer dst, {
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
    bool resume = false,
  }) async {
    if (resume && dst is fs.File) return _downloadResume(url, dst, headers: headers, timeout: timeout, retry: retry);
    final resp = await _withRetry('GET', url, headers: headers, timeout: timeout, retry: retry);
    try {
      if (!resp.ok) {
        final body = await resp.drain(timeout: timeout ?? defaultTimeout);
        throw StatusException(Resp.detached(resp.status, resp.headers, body, resp.url, reason: resp.reason));
      }
      var total = 0;
      final chunk = Uint8List(64 * 1024);
      while (true) {
        final n = await resp.read(chunk);
        if (n <= 0) break;
        await dst.write(Uint8List.sublistView(chunk, 0, n));
        total += n;
      }
      await dst.flush();
      return total;
    } finally {
      await resp.close();
    }
  }

  static Future<int> _downloadResume(
    String url,
    fs.File dst, {
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) async {
    var existing = 0;
    try {
      if (await dst.exists) existing = await dst.size;
    } catch (_) {
      existing = 0; // A missing file starts from the beginning.
    }
    final reqHeaders = <String, String>{...?headers};
    if (existing > 0) reqHeaders.putIfAbsent('range', () => 'bytes=$existing-');
    final resp = await _withRetry('GET', url, headers: reqHeaders, timeout: timeout, retry: retry);
    try {
      if (resp.status == 206) {
        final sink = dst.writer(append: true);
        try {
          var total = 0;
          final chunk = Uint8List(64 * 1024);
          while (true) {
            final n = await resp.read(chunk);
            if (n <= 0) break;
            await sink.write(Uint8List.sublistView(chunk, 0, n));
            total += n;
          }
          await sink.flush();
          return existing + total;
        } finally {
          await sink.close();
        }
      }
      if (!resp.ok) {
        final body = await resp.drain(timeout: timeout ?? defaultTimeout);
        throw StatusException(Resp.detached(resp.status, resp.headers, body, resp.url, reason: resp.reason));
      }
      // The server ignored the range: restart from the beginning.
      final sink = dst.writer();
      try {
        var total = 0;
        final chunk = Uint8List(64 * 1024);
        while (true) {
          final n = await resp.read(chunk);
          if (n <= 0) break;
          await sink.write(Uint8List.sublistView(chunk, 0, n));
          total += n;
        }
        await sink.flush();
        return total;
      } finally {
        await sink.close();
      }
    } finally {
      await resp.close();
    }
  }

  static Future<Resp> _withRetry(
    String method,
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? retry,
  }) async {
    final attempts = (retry ?? defaultRetries) + 1;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final resp = await _send(
          method,
          url,
          json: json,
          body: body,
          headers: headers,
          timeout: timeout ?? defaultTimeout,
        );
        if (resp.status >= 500 && attempt < attempts) {
          final body = await resp.drain(timeout: timeout ?? defaultTimeout);
          lastError = StatusException(Resp.detached(resp.status, resp.headers, body, resp.url, reason: resp.reason));
          await resp.close();
          continue;
        }
        return resp;
      } on StatusException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt >= attempts) break;
        if (!_retryable(e)) break;
      }
    }
    if (lastError is StatusException) throw lastError;
    throw ClientException('Request failed: $lastError', uri: Uri.tryParse(url), cause: lastError);
  }

  static bool _retryable(Object e) =>
      e is io.SocketException || e is io.HttpException || e is TimeoutException || e is ClientException;

  static Future<Resp> _send(
    String method,
    String url, {
    Object? json,
    Object? body,
    Map<String, String>? headers,
    required Duration timeout,
  }) async {
    final client = io.HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url)).timeout(timeout);
      headers?.forEach(request.headers.set);
      if (json != null) {
        request.headers.contentType = io.ContentType.json;
        final payload = Json.dump(json);
        request.write(payload);
      } else if (body != null) {
        await _writeBody(request, body);
      }
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

  /// Writes [body] into [request]: a `Map` is form-encoded (never
  /// stringified), `json:` is JSON, a [Reader] streams chunked.
  static Future<void> _writeBody(io.HttpClientRequest request, Object body) async {
    if (body is Reader) {
      if (body is fs.File) {
        try {
          request.contentLength = await body.size;
        } catch (_) {
          request.contentLength = -1;
        }
      } else {
        request.contentLength = -1;
      }
      final chunk = Uint8List(64 * 1024);
      while (true) {
        final n = await body.read(chunk);
        if (n <= 0) break;
        request.add(chunk.sublist(0, n));
      }
      return;
    }
    if (body is Map) {
      request.headers.contentType = io.ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(
        body.entries
            .map((e) => '${Uri.encodeQueryComponent('${e.key}')}=${Uri.encodeQueryComponent('${e.value}')}')
            .join('&'),
      );
      return;
    }
    if (body is String) {
      request.write(body);
      return;
    }
    if (body is Uint8List) {
      request.add(body);
      return;
    }
    if (body is List<int>) {
      request.add(body);
      return;
    }
    throw ArgumentError.value(body, 'body', 'Must be a Map, String, List<int>, Uint8List or Reader');
  }
}
