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
/// ignores the wait, and on [ChromeClient], which honours it.
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

/// A request: [method], [url], [headers] and a body.
///
/// A body is given one way, by what it is — [text], [bytes], [form] or [json] — and the
/// same four words name it on [UriExtensions.post] and on `follow`. At most one may be
/// set; the matching `content-type` comes with it.
///
/// {@category Networking}
final class Request {
  /// Answer with the resource itself, never a rendering of it: `request[Request.raw] = true`.
  ///
  /// The one directive that is not a client's own. A client that renders — [ChromeClient],
  /// and any other written later — must hand this request to plain HTTP instead, because
  /// what the caller wants is the bytes the server sent. A PDF put through a tab comes back
  /// as the DOM Chrome built to display it, which is not the PDF.
  ///
  /// Every download sets it, so `path.download(url)` writes the file and not the viewer
  /// even inside `Http.scope(client: chrome)`. [IoClient] renders nothing and ignores it.
  static const raw = RequestKey<bool>('raw');

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

  Request(
    String method,
    this.url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
  }) : method = method.toUpperCase(),
       headers = Headers(headers),
       bytes = Uint8List(0) {
    _body(this, text: text, bytes: bytes, form: form, json: json);
  }

  /// The body as text, UTF-8. Setting it sets a `content-type` of `text/plain` when none is set.
  String get text => utf8.decode(bytes, allowMalformed: true);
  set text(String value) {
    bytes = utf8.encode(value);
    headers.putIfAbsent('content-type', () => 'text/plain; charset=utf-8');
  }

  /// Sets the body to form-encoded [form] and the `content-type` to match.
  set form(Map<String, String> form) {
    bytes = utf8.encode(Uri(queryParameters: form).query);
    headers['content-type'] = 'application/x-www-form-urlencoded; charset=utf-8';
  }

  /// Sets the body to [json] encoded, and the `content-type` to `application/json`.
  set json(Object? json) {
    bytes = utf8.encode(jsonEncode(json));
    headers.putIfAbsent('content-type', () => 'application/json; charset=utf-8');
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

/// Puts at most one of [text], [bytes], [form] and [json] on [request]; more than one is
/// an [ArgumentError]. The one place the four body words are turned into a body.
void _body(Request request, {String? text, List<int>? bytes, Map<String, String>? form, Object? json}) {
  final given = [
    if (text != null) 'text',
    if (bytes != null) 'bytes',
    if (form != null) 'form',
    if (json != null) 'json',
  ];
  if (given.length > 1) throw ArgumentError('Pass at most one body: ${given.join(', ')} were all given.');
  if (text != null) request.text = text;
  if (bytes != null) request.bytes = Uint8List.fromList(bytes);
  if (form != null) request.form = form;
  if (json != null) request.json = json;
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

final _charset = RegExp(r'charset=["\x27]?([^;"\x27\s>]+)', caseSensitive: false);

/// A `charset` declared inside a `<meta>`, in either spelling; both carry `charset=`.
final _metaCharset = RegExp(r'''<meta[^>]+charset\s*=\s*["']?([\w-]+)''', caseSensitive: false);

/// Bytes the server sent, as text.
///
/// The `content-type` names the encoding when it can; a page that serves `text/html` with
/// no charset and declares one in a `<meta>` instead is the common shape on the legacy web,
/// so the head of the document is read to find out how to read the document — which is
/// what a browser does. An encoding named here decodes; anything else is read as UTF-8
/// with its bad bytes replaced, as before.
String _decode(Uint8List bytes, String? contentType) {
  final declared = _charset.firstMatch(contentType ?? '')?[1] ?? _declaredInMarkup(bytes);
  return switch (declared?.toLowerCase()) {
    // The HTML standard decodes `iso-8859-1` as windows-1252, and a page labelled either
    // one almost always means the latter: the bytes Latin-1 leaves as C1 controls are
    // curly quotes and dashes in every page that actually uses them.
    'windows-1252' || 'cp1252' || 'iso-8859-1' || 'latin1' || 'latin-1' => _windows1252(bytes),
    'us-ascii' || 'ascii' => latin1.decode(bytes),
    _ => utf8.decode(bytes, allowMalformed: true),
  };
}

/// The charset a document declares in its own first bytes, or `null`.
String? _declaredInMarkup(Uint8List bytes) {
  final head = latin1.decode(
    Uint8List.sublistView(bytes, 0, bytes.length < 2048 ? bytes.length : 2048),
    allowInvalid: true,
  );
  return _metaCharset.firstMatch(head)?[1];
}

/// windows-1252 is Latin-1 with 27 printable characters where Latin-1 has C1 controls.
const _windows1252High = <int>[
  0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f,
  0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

String _windows1252(Uint8List bytes) => String.fromCharCodes([
  for (final b in bytes)
    if (b >= 0x80 && b <= 0x9f) _windows1252High[b - 0x80] else b,
]);

/// Something a request can be sent through: the real client, a scope's wrapper, a mock.
///
/// {@category Networking}
abstract interface class Client {
  /// Sends [request] and answers with the response whose body is still arriving.
  ///
  /// The contract an implementation owes its caller: a non-2xx status is a [StreamedResponse],
  /// not a throw; a transport failure is a [ClientException] or a `dart:io` exception;
  /// [StreamedResponse.url] is the URL that *answered*, after whatever redirects were
  /// followed; and a [RequestKey] the implementation does not recognise is ignored.
  ///
  /// A client may write on the request it is handed — a scope stamps its default headers
  /// and its `cookie` there — so **sending consumes a request**. Everything in this module
  /// that sends one the caller owns copies it first ([UriExtensions.send],
  /// [ClientExtensions.get] and its siblings, the crawl engine); a caller reaching `send`
  /// directly and meaning to reuse the request copies it with [Request.copy].
  Future<StreamedResponse> send(Request request);

  /// Releases connections; the client cannot be used afterwards.
  ///
  /// Always a future, so every caller awaits one thing. A client that shuts down over a
  /// socket — a browser, a pool — needs the wait; one that closes synchronously returns an
  /// already-completed future and costs its caller nothing. The seam absorbs the difference
  /// rather than making each call site branch on it.
  Future<void> close();
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

  /// The total-transfer cap, or `null` when the client was built without `connections:`.
  final Semaphore? _permits;

  /// [perHost] is how many connections may be open to one origin at a time; [connections]
  /// caps the total in flight across every host, which `dart:io` has no setting for. A
  /// permit is held until the body is read to the end, cancelled or thrown, so the cap
  /// counts transfers rather than handshakes.
  ///
  /// [keepAlive] is how long an idle connection is kept for the next request, and
  /// [connectTimeout] bounds the handshake alone — [Http.scope]'s `timeout:` bounds the
  /// wait for a response, which is a different thing and composes with this one.
  /// [userAgent] is sent when a request does not name its own.
  ///
  /// [client] takes over an `HttpClient` configured elsewhere — a proxy, a certificate
  /// policy; the settings here are applied on top of it.
  IoClient({
    int? connections,
    int? perHost,
    Duration? keepAlive,
    Duration? connectTimeout,
    String? userAgent,
    HttpClient? client,
  }) : _client = client ?? HttpClient(),
       _permits = connections == null ? null : Semaphore(connections) {
    if (perHost != null) _client.maxConnectionsPerHost = perHost;
    if (keepAlive != null) _client.idleTimeout = keepAlive;
    if (connectTimeout != null) _client.connectionTimeout = connectTimeout;
    if (userAgent != null) _client.userAgent = userAgent;
  }

  @override
  Future<StreamedResponse> send(Request request) async {
    final permit = await _permits?.acquire();
    var released = false;
    void release() {
      if (released) return;
      released = true;
      permit?.release();
    }

    try {
      return await _send(request, release);
    } catch (_) {
      release();
      rethrow;
    }
  }

  Future<StreamedResponse> _send(Request request, void Function() release) async {
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
    // One value per name, so a header the server repeated is joined. `set-cookie` is the
    // one that cannot be joined with a comma — its `Expires` holds one — and a newline
    // cannot appear in a header value, so it separates them unambiguously. Chrome's
    // DevTools protocol joins the same header the same way, so [ChromeClient] agrees.
    response.headers.forEach((name, values) => headers[name] = values.join(name == 'set-cookie' ? '\n' : ', '));
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
      _releasing(
        response.handleError(
          (Object e) => throw ClientException(e is HttpException ? e.message : '$e', request.url),
          test: (e) => e is HttpException,
        ),
        release,
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
  Future<void> close() async => _client.close(force: true);

  /// Hands the permit back when the body ends, however it ends — read to completion, thrown,
  /// or cancelled by a caller that stopped listening.
  static Stream<List<int>> _releasing(Stream<List<int>> body, void Function() release) async* {
    try {
      yield* body;
    } finally {
      release();
    }
  }
}
