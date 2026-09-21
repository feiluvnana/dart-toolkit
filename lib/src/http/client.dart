part of '../../http.dart';

/// HTTP headers: names are case-insensitive and stored lowercase, one value per name.
///
/// {@category Networking}
final class Headers extends MapBase<String, String> {
  final Map<String, String> _map = {};

  Headers([Map<String, String>? from]) {
    if (from != null) addAll(from);
  }

  @override
  String? operator [](Object? key) => key is String ? _map[key.toLowerCase()] : null;

  @override
  void operator []=(String key, String value) => _map[key.toLowerCase()] = value;

  @override
  void clear() => _map.clear();

  @override
  Iterable<String> get keys => _map.keys;

  @override
  String? remove(Object? key) => key is String ? _map.remove(key.toLowerCase()) : null;

  @override
  bool containsKey(Object? key) => key is String && _map.containsKey(key.toLowerCase());
}

/// A directive a [Client] may honour, carried on a [Request] under a typed name.
///
/// The fields of [Request] describe HTTP and nothing else. A client that is not HTTP — a
/// browser, a proxy with rules of its own — needs to be told things HTTP has no word for,
/// and a key is where they go:
///
/// ```dart
/// const waitFor = RequestKey<String>('wait-for');
///
/// url.scrape<Item>().onRequest((ctx) => ctx.request[waitFor] = '.item');
/// ```
///
/// A client reads it with the key itself — `waitFor(request)` — and **ignores every key it
/// does not know**. That is what makes the same crawl run unchanged on [IoClient], which
/// ignores the wait, and on [BrowserClient], which honours it.
///
/// {@category Networking}
final class RequestKey<T extends Object> {
  /// What this key is called, in messages and in `toString`.
  final String name;

  const RequestKey(this.name);

  /// The value [request] carries under this key, or `null` when it carries none.
  T? call(Request request) => request._directives?[this] as T?;

  bool _accepts(Object? value) => value is T;

  @override
  String toString() => name;
}

/// A request: [method], [url], [headers] and a body of [bytes].
///
/// {@category Networking}
final class Request {
  final String method;
  final Uri url;
  final Headers headers;
  Uint8List bytes;

  /// Whether the client follows redirects itself, up to [maxRedirects]. The scrape engine
  /// turns this off and follows its own.
  bool followRedirects = true;
  int maxRedirects = 5;
  bool persistentConnection = true;

  /// Client-specific directives, absent until one is set; see [RequestKey].
  Map<RequestKey<Object>, Object>? _directives;

  Request(String method, this.url, {Map<String, String>? headers, List<int>? bytes, String? text})
    : method = method.toUpperCase(),
      headers = Headers(headers),
      bytes = bytes != null ? Uint8List.fromList(bytes) : Uint8List(0) {
    if (text != null) this.text = text;
  }

  /// The body as text, UTF-8. Setting it sets a `content-type` of `text/plain` when none is set.
  String get text => utf8.decode(bytes, allowMalformed: true);
  set text(String value) {
    bytes = utf8.encode(value);
    headers.putIfAbsent('content-type', () => 'text/plain; charset=utf-8');
  }

  /// Sets the body to form-encoded [fields] and the `content-type` to match.
  set fields(Map<String, String> fields) {
    bytes = utf8.encode(Uri(queryParameters: fields).query);
    headers['content-type'] = 'application/x-www-form-urlencoded; charset=utf-8';
  }

  /// Sets the directive [key] carries for the client that answers this request.
  ///
  /// `request[waitFor] = '.item'`; read it back with the key, `waitFor(request)`. Throws
  /// [ArgumentError] when [value] is not of the key's type.
  void operator []=(RequestKey<Object> key, Object value) {
    if (!key._accepts(value)) throw ArgumentError.value(value, key.name, 'is not what this key holds');
    (_directives ??= {})[key] = value;
  }

  /// An independent copy: same method, URL, headers, body, options and directives.
  Request copy() => Request(method, url, headers: headers, bytes: bytes)
    ..followRedirects = followRedirects
    ..maxRedirects = maxRedirects
    ..persistentConnection = persistentConnection
    .._directives = _directives == null ? null : Map.of(_directives!);

  @override
  String toString() => '$method $url';
}

/// A response whose body is still arriving; [read] buffers it into a [Response].
///
/// {@category Networking}
final class StreamedResponse {
  final Stream<List<int>> stream;
  final int statusCode;
  final String? reasonPhrase;
  final Headers headers;

  /// `Content-Length`, or `null` when the server did not say or the body is being decoded.
  final int? contentLength;

  /// The request that produced this response.
  final Request? request;

  /// The URL that answered, after any redirects the client followed.
  final Uri? url;

  final bool isRedirect;

  StreamedResponse(
    this.stream,
    this.statusCode, {
    this.contentLength,
    Map<String, String>? headers,
    this.request,
    Uri? url,
    this.reasonPhrase,
    this.isRedirect = false,
  }) : headers = headers is Headers ? headers : Headers(headers),
       url = url ?? request?.url;

  /// Whether the status code is 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// Buffers the body.
  Future<Response> read() async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return Response.bytes(
      builder.takeBytes(),
      statusCode,
      headers: headers,
      request: request,
      url: url,
      reasonPhrase: reasonPhrase,
      isRedirect: isRedirect,
    );
  }
}

/// A response with its body in memory.
///
/// {@category Networking}
final class Response {
  final int statusCode;
  final String? reasonPhrase;
  final Headers headers;
  final Uint8List bytes;

  /// The request that produced this response, when known.
  final Request? request;

  /// The URL that answered, after any redirects the client followed.
  final Uri? url;

  final bool isRedirect;

  String? _text;
  JsonDocument? _json;

  /// A response with a text [body]: `Response('ok', 200)`.
  Response(
    String body,
    int statusCode, {
    Map<String, String>? headers,
    Request? request,
    Uri? url,
    String? reasonPhrase,
    bool isRedirect = false,
  }) : this.bytes(
         utf8.encode(body),
         statusCode,
         headers: headers,
         request: request,
         url: url,
         reasonPhrase: reasonPhrase,
         isRedirect: isRedirect,
       );

  Response.bytes(
    List<int> bytes,
    this.statusCode, {
    Map<String, String>? headers,
    this.request,
    Uri? url,
    this.reasonPhrase,
    this.isRedirect = false,
  }) : bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
       headers = headers is Headers ? headers : Headers(headers),
       url = url ?? request?.url;

  /// Whether the status code is 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// The body decoded once, by the `charset` of `content-type`; UTF-8 when it names none.
  String get text => _text ??= _decode(bytes, headers['content-type']);

  /// The body parsed as JSON, once per response instance.
  JsonDocument get json => _json ??= JsonDocument.parse(text);

  /// Runs [action] on a copy of this response inside a background [Isolate].
  ///
  /// Copies the body, status, headers and URL — not the client. Extract data in [action];
  /// returning a parsed document copies it all back and buys nothing.
  Future<R> isolate<R>(FutureOr<R> Function(Response res) action) {
    final bytes = this.bytes;
    final code = statusCode;
    final hdrs = Map<String, String>.of(headers);
    final method = request?.method ?? 'GET';
    final reqUrl = url;
    return (() {
      final copy = Response.bytes(
        bytes,
        code,
        headers: hdrs,
        request: reqUrl != null ? Request(method, reqUrl) : null,
        url: reqUrl,
      );
      return action(copy);
    }).isolate();
  }

  @override
  String toString() => 'Response($statusCode${reasonPhrase == null ? '' : ' $reasonPhrase'}, ${bytes.length} bytes)';
}

final _charset = RegExp(r'charset=["\x27]?([^;"\x27\s]+)', caseSensitive: false);

String _decode(Uint8List bytes, String? contentType) {
  final charset = _charset.firstMatch(contentType ?? '')?[1];
  return switch (charset?.toLowerCase()) {
    'iso-8859-1' || 'latin1' || 'latin-1' || 'us-ascii' || 'ascii' => latin1.decode(bytes),
    _ => utf8.decode(bytes, allowMalformed: true),
  };
}

/// Something a request can be sent through: the real client, a session's wrapper, a mock.
///
/// {@category Networking}
abstract interface class Client {
  /// Sends [request] and answers with the response whose body is still arriving.
  ///
  /// The contract an implementation owes its caller: a non-2xx status is a [StreamedResponse],
  /// not a throw; a transport failure is a [ClientException] or a `dart:io` exception;
  /// [StreamedResponse.url] is the URL that *answered*, after whatever redirects were
  /// followed; and a [RequestKey] the implementation does not recognise is ignored.
  Future<StreamedResponse> send(Request request);

  /// Releases connections; the client cannot be used afterwards.
  ///
  /// [Http.session] awaits this, so an implementation that shuts down over a socket — a
  /// browser, a pool — may return a future and be sure it is waited for.
  FutureOr<void> close();
}

/// Reads and discards a response body, releasing the connection instead of holding it
/// until the client reaps an idle one.
void _drain(StreamedResponse response) =>
    unawaited(response.stream.listen(null, cancelOnError: true).cancel().catchError((_) {}));

/// A transport-level failure: the connection closed early, too many redirects, a body over a
/// cap. Socket and TLS failures come through as `dart:io`'s own exceptions.
///
/// {@category Networking}
final class ClientException implements Exception {
  final String message;
  final Uri? uri;

  const ClientException(this.message, [this.uri]);

  @override
  String toString() => uri == null ? message : '$message ($uri)';
}

/// The client over `dart:io`'s [HttpClient]: keep-alive, gzip, proxies from the environment.
///
/// {@category Networking}
final class IoClient implements Client {
  final HttpClient _client;

  IoClient([HttpClient? client]) : _client = client ?? HttpClient();

  @override
  Future<StreamedResponse> send(Request request) async {
    final HttpClientResponse response;
    try {
      final io = await _client.openUrl(request.method, request.url);
      io
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..contentLength = request.bytes.length;
      request.headers.forEach((k, v) => io.headers.set(k, v));
      if (request.bytes.isNotEmpty) io.add(request.bytes);
      response = await io.close();
    } on HttpException catch (e) {
      throw ClientException(e.message, request.url);
    }
    final headers = Headers();
    response.headers.forEach((name, values) => headers[name] = values.join(', '));
    if (response.contentLength == -1 && headers.containsKey('content-encoding')) {
      // dart:io decoded the body; the length and encoding on the wire no longer describe it.
      headers
        ..remove('content-length')
        ..remove('content-encoding');
    }
    var url = request.url;
    for (final hop in response.redirects) {
      url = url.resolveUri(hop.location);
    }
    return StreamedResponse(
      response.handleError(
        (Object e) => throw ClientException(e is HttpException ? e.message : '$e', request.url),
        test: (e) => e is HttpException,
      ),
      response.statusCode,
      contentLength: response.contentLength == -1 ? null : response.contentLength,
      headers: headers,
      request: request,
      url: url,
      reasonPhrase: response.reasonPhrase,
      isRedirect: response.isRedirect,
    );
  }

  @override
  void close() => _client.close(force: true);
}
