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

  @override
  int get length => _map.length;

  @override
  bool get isEmpty => _map.isEmpty;

  @override
  bool get isNotEmpty => _map.isNotEmpty;
}

/// A directive a [Client] may honour, carried on a [Request] under a typed name — for what
/// HTTP has no word for, such as a browser's wait.
///
/// ```dart
/// const waitFor = RequestKey<String>('wait-for');
///
/// url.scrape<Item>().onRequest((ctx) => ctx.request[waitFor] = '.item');
/// ```
///
/// A client reads it as `waitFor(request)` and **ignores every key it does not know**, so the
/// same crawl runs on [IoClient] and on `ChromeClient`.
///
/// {@category Networking}
final class RequestKey<T extends Object> {
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
/// The body is at most one of [text], [bytes], [form], [json] or `files` (`form` pairs with
/// `files`), with its `content-type`; the same words name it on [UriExtensions.post] and
/// `follow`.
///
/// {@category Networking}
final class Request {
  /// Answer with the resource itself, never a rendering of it: `request[Request.raw] = true`.
  ///
  /// A rendering client (`ChromeClient`) must hand such a request to plain HTTP; [IoClient]
  /// asks for `identity` and decodes nothing. Every download sets it, so a `.gz` is written
  /// as the `.gz` it is and a resume appends the same bytes.
  static const raw = RequestKey<bool>('raw');

  final String method;
  final Uri url;
  final Headers headers;
  Uint8List bytes;

  /// Whether the client follows redirects itself, up to [maxRedirects].
  bool followRedirects = true;
  int maxRedirects = 20;

  Map<RequestKey<Object>, Object>? _directives;

  /// A `files:` body, streamed from disk and never held.
  _Multipart? _multipart;

  Request(
    String method,
    this.url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) : method = method.toUpperCase(),
       headers = Headers(headers),
       bytes = Uint8List(0) {
    _body(this, text: text, bytes: bytes, form: form, json: json, files: files);
  }

  /// The body, for the client that sends it. **A client sends this, not [bytes]**: a `files:`
  /// body leaves [bytes] empty and is opened from disk on each call, so a 307 or a retry can
  /// send it again.
  Stream<List<int>> open() => _multipart?.open() ?? Stream.value(bytes);

  /// The `content-length`, whether the body is held or streamed.
  int get contentLength => _multipart?.length ?? bytes.length;

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

  /// Sets a directive: `request[waitFor] = '.item'`, read back as `waitFor(request)`. Throws
  /// [ArgumentError] when [value] is not of the key's type.
  void operator []=(RequestKey<Object> key, Object value) {
    if (!key._accepts(value)) throw ArgumentError.value(value, key.name, 'is not what this key holds');
    (_directives ??= {})[key] = value;
  }

  /// An independent copy: same method, URL, headers, body, options and directives. The body
  /// buffer is shared — every send copies its request, and only the headers are written on.
  /// Pass parameters to override specific parts of the request.
  Request copy({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, String>? form,
    Object? json,
    Map<String, Path>? files,
  }) {
    final next = _options(Request(method ?? this.method, url ?? this.url, headers: headers ?? this.headers));
    if (text != null || bytes != null || form != null || json != null || files != null) {
      _body(next, text: text, bytes: bytes, form: form, json: json, files: files);
    } else {
      next.bytes = this.bytes;
      next._multipart = _multipart;
    }
    return next;
  }

  /// [to] with this request's redirect options and a copy of its directives.
  Request _options(Request to) => to
    ..followRedirects = followRedirects
    ..maxRedirects = maxRedirects
    .._directives = _directives == null ? null : Map.of(_directives!);

  /// Sends this request through the enclosing [Http.scope]'s client, or a fresh one, and
  /// buffers the body: `await Request('POST', url, json: {...}).send()`.
  ///
  /// The request is copied first, so sending it twice sends it twice; [Response.request] is
  /// the copy that went out. Under `Http.scope(retries:)` a body cut off half-way is fetched
  /// again, for a method that may be sent twice.
  Fetch send() => Fetch._(_buffered(this));

  /// The request that follows a [status] redirect to [to], for [IoClient], the scope and the
  /// crawl alike.
  ///
  /// 303, and 301/302 on anything but GET and HEAD, become a bodiless GET, as in a browser;
  /// 307 and 308 keep both. Credentials do not follow to another origin — host, scheme or
  /// port — so an https→http hop cannot leak a bearer token.
  Request _hop(Uri to, int status) {
    final downgrade = method != 'HEAD' && (status == 303 || ((status == 301 || status == 302) && method != 'GET'));
    final cross = !_sameOrigin(to, url);
    final next = _options(Request(downgrade ? 'GET' : method, to));
    for (final MapEntry(:key, :value) in headers.entries) {
      if (downgrade && (key == 'content-type' || key == 'content-length')) continue;
      if (cross && _credential.contains(key)) continue;
      next.headers[key] = value;
    }
    if (!downgrade) {
      next
        ..bytes = bytes
        .._multipart = _multipart;
    }
    return next;
  }

  @override
  String toString() => '$method $url';
}

/// Puts at most one body on [request], else an [ArgumentError]. [form] with [files] is one
/// `multipart/form-data` body: a browser form with a file input.
void _body(
  Request request, {
  String? text,
  List<int>? bytes,
  Map<String, String>? form,
  Object? json,
  Map<String, Path>? files,
}) {
  final given = [
    if (text != null) 'text',
    if (bytes != null) 'bytes',
    if (form != null && files == null) 'form',
    if (files != null) 'files',
    if (json != null) 'json',
  ];
  if (given.length > 1) throw ArgumentError('Pass at most one body: ${given.join(', ')} were all given.');
  if (text != null) request.text = text;
  if (bytes != null) request.bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (json != null) request.json = json;
  if (files != null) {
    final body = _Multipart(form ?? const {}, files);
    request
      .._multipart = body
      ..headers['content-type'] = body.contentType;
  } else if (form != null) {
    request.form = form;
  }
}

/// A `files:` body: the fields, then the files streamed off disk. Paths rather than a
/// `Stream`, so [Request.open] can be called again for a 307 or a retry.
final class _Multipart {
  final Map<String, String> fields;
  final Map<String, Path> files;
  final String boundary;

  _Multipart(this.fields, this.files) : boundary = 'dartToolkit${Secure.token(12)}';

  String get contentType => 'multipart/form-data; boundary=$boundary';

  /// Each part's header, and the file whose bytes follow it.
  late final List<(Uint8List, Path?)> _parts = [
    for (final MapEntry(:key, :value) in fields.entries)
      (utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${_quoted(key)}"\r\n\r\n$value\r\n'), null),
    for (final MapEntry(:key, :value) in files.entries)
      (
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="${_quoted(key)}"; filename="${_quoted(value.name)}"\r\n'
          'Content-Type: ${_mime(value.ext)}\r\n\r\n',
        ),
        value,
      ),
  ];

  late final Uint8List _tail = utf8.encode('--$boundary--\r\n');

  /// Synchronous `stat`s on purpose: nothing overlaps them, and a missing file fails here,
  /// naming itself, rather than half-way through the upload.
  late final int length = _parts.fold(_tail.length, (n, part) {
    final (head, file) = part;
    return n + head.length + (file == null ? 0 : file.asFile.lengthSync() + 2);
  });

  Stream<List<int>> open() async* {
    for (final (head, file) in _parts) {
      yield head;
      if (file != null) {
        yield* file.asFile.openRead();
        yield _crlf;
      }
    }
    yield _tail;
  }

  /// A quoted-string value, escaped as a browser escapes a filename.
  static String _quoted(String value) => value.replaceAll('"', '%22').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
}

final _crlf = utf8.encode('\r\n');

/// The content type an uploaded file announces; anything unlisted is bytes.
String _mime(String ext) => switch (ext.toLowerCase()) {
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'svg' => 'image/svg+xml',
  'pdf' => 'application/pdf',
  'txt' || 'md' => 'text/plain; charset=utf-8',
  'csv' => 'text/csv; charset=utf-8',
  'json' => 'application/json',
  'xml' => 'application/xml',
  'html' || 'htm' => 'text/html; charset=utf-8',
  'zip' => 'application/zip',
  'gz' => 'application/gzip',
  'mp4' => 'video/mp4',
  'mp3' => 'audio/mpeg',
  'wav' => 'audio/wav',
  _ => 'application/octet-stream',
};

/// Credentials a redirect to another origin does not carry.
const _credential = {'authorization', 'cookie', 'proxy-authorization'};

/// Whether [a] and [b] are one origin: scheme, host and port (`:443` and none agree).
bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && a.port == b.port && a.host.toLowerCase() == b.host.toLowerCase();

/// `404 Not Found`.
String _status(int code, String? reason) => reason == null || reason.isEmpty ? '$code' : '$code $reason';

CancelledException _cancelled(CancelToken token) =>
    CancelledException(token.reason?.toString() ?? 'Operation was cancelled.');

/// Whether a second attempt might not meet [error]: the connection, not TLS or a cancel.
bool _transient(Object error) =>
    (error is ClientException || error is SocketException || error is HttpException || error is TimeoutException) &&
    !_certain(error);

/// The request after [res] in [current]'s chain, with [res] drained so the hop can reuse its
/// connection, or `null` where the chain ends. [first] names the chain in the error.
Future<Request?> _next(Request current, StreamedResponse res, int hop, Uri first) async {
  final status = res.statusCode;
  if (status != 301 && status != 302 && status != 303 && status != 307 && status != 308) return null;
  final location = res.headers['location']?.trim();
  final to = location == null || location.isEmpty ? null : Uri.tryParse(location);
  if (to == null) return null;
  await _drain(res);
  if (hop >= current.maxRedirects) throw ClientException('More than ${current.maxRedirects} redirects', first);
  return current._hop(current.url.resolveUri(to).removeFragment(), status);
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

  StreamedResponse(
    this.stream,
    this.statusCode, {
    this.contentLength,
    Map<String, String>? headers,
    this.request,
    Uri? url,
    this.reasonPhrase,
  }) : headers = headers is Headers ? headers : Headers(headers),
       url = url ?? request?.url;

  /// Whether the status code is 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// Whether this is a redirect the client did not follow: a 3xx with a `location`.
  bool get isRedirect => statusCode ~/ 100 == 3 && headers.containsKey('location');

  StreamedResponse _carrying(Stream<List<int>> body) => StreamedResponse(
    body,
    statusCode,
    contentLength: contentLength,
    headers: headers,
    request: request,
    url: url,
    reasonPhrase: reasonPhrase,
  );

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

  String? _text;
  JsonDocument? _json;
  HtmlDocument? _html;
  XmlDocument? _xml;

  /// A response with a text [body]: `Response('ok', 200)`.
  Response(
    String body,
    int statusCode, {
    Map<String, String>? headers,
    Request? request,
    Uri? url,
    String? reasonPhrase,
  }) : this.bytes(
         utf8.encode(body),
         statusCode,
         headers: headers,
         request: request,
         url: url,
         reasonPhrase: reasonPhrase,
       );

  Response.bytes(
    List<int> bytes,
    this.statusCode, {
    Map<String, String>? headers,
    this.request,
    Uri? url,
    this.reasonPhrase,
  }) : bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
       headers = headers is Headers ? headers : Headers(headers),
       url = url ?? request?.url;

  /// Whether the status code is 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// Whether this is a redirect the client did not follow: a 3xx with a `location`.
  bool get isRedirect => statusCode ~/ 100 == 3 && headers.containsKey('location');

  /// The body decoded once, by the `charset` of `content-type`; UTF-8 when it names none.
  String get text => _text ??= _decode(bytes, headers['content-type']);

  /// The body parsed as JSON, once per response instance.
  JsonDocument get json => _json ??= JsonDocument.parse(text);

  /// Cookies set by this response in its `Set-Cookie` headers.
  List<Cookie> get cookies {
    final header = headers['set-cookie'];
    if (header == null || header.isEmpty) return const [];
    final out = <Cookie>[];
    for (final line in header.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        out.add(Cookie.fromSetCookieValue(trimmed));
      } catch (_) {}
    }
    return out;
  }

  @override
  String toString() => 'Response($statusCode${reasonPhrase == null ? '' : ' $reasonPhrase'}, ${bytes.length} bytes)';
}

/// A request on its way: awaited, the [Response] whatever its status; read, the body — and
/// only a 2xx one, else an [HttpException] naming the status and URL.
///
/// ```dart
/// final score = (await api.post(json: x).json)['score'];   // throws unless 2xx
/// final res = await api.post(json: x);                       // any status; check res.isOk
/// ```
///
/// {@category Networking}
final class Fetch implements Future<Response> {
  final Future<Response> _response;

  Fetch._(this._response);

  Future<Response> get _ok => _response.then(
    (res) => res.isOk ? res : throw HttpException(_status(res.statusCode, res.reasonPhrase), uri: res.url),
  );

  /// The body parsed as JSON; see [Response.json].
  Future<JsonDocument> get json => _ok.then((res) => res.json);

  /// The body decoded as text; see [Response.text].
  Future<String> get text => _ok.then((res) => res.text);

  /// The body parsed as HTML.
  Future<HtmlDocument> get html => _ok.then((res) => res.html);

  /// The body parsed as XML.
  Future<XmlDocument> get xml => _ok.then((res) => res.xml);

  /// The body as it arrived.
  Future<Uint8List> get bytes => _ok.then((res) => res.bytes);

  @override
  Future<R> then<R>(FutureOr<R> Function(Response value) onValue, {Function? onError}) =>
      _response.then(onValue, onError: onError);

  @override
  Future<Response> catchError(Function onError, {bool Function(Object error)? test}) =>
      _response.catchError(onError, test: test);

  @override
  Future<Response> whenComplete(FutureOr<void> Function() action) => _response.whenComplete(action);

  @override
  Future<Response> timeout(Duration timeLimit, {FutureOr<Response> Function()? onTimeout}) =>
      _response.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Stream<Response> asStream() => _response.asStream();
}

/// [Request.send]: [request] through the scope's client or a fresh one, its body buffered.
Future<Response> _buffered(Request request) async {
  final lease = _clientFor();
  final budget = _replays(request);
  try {
    for (var attempt = 0; ; attempt++) {
      // The send retries its own failures; this loop retries the body.
      final res = await lease.client.send(request.copy());
      try {
        return await res.read();
      } catch (e) {
        if (attempt >= budget || !_transient(e) || Cancel.isCancelled) rethrow;
        await (200 * (attempt + 1)).ms.delay();
      }
    }
  } finally {
    lease.close();
  }
}

final _charset = RegExp(r'charset=["\x27]?([^;"\x27\s>]+)', caseSensitive: false);

/// A `charset` declared inside a `<meta>`, in either spelling; both carry `charset=`.
final _metaCharset = RegExp(r'''<meta[^>]+charset\s*=\s*["']?([\w-]+)''', caseSensitive: false);

/// An `encoding` declared in an XML prolog `<?xml ... encoding="..."?>`.
final _xmlEncoding = RegExp(r'''<\?xml\b[^>]*\bencoding\s*=\s*["']([\w-]+)["']''', caseSensitive: false);

/// Bytes as text, decided as a browser does: a BOM; the `content-type` charset; for HTML or
/// XML (or no type) a `<meta>` or prolog in the first 2 KiB — never in JSON, where `<meta` is
/// just a string; else UTF-8. Labels beyond UTF-8 and windows-1252 are the native library's,
/// and read as UTF-8 without it.
String _decode(Uint8List bytes, String? contentType) {
  if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
    return utf8.decode(Uint8List.sublistView(bytes, 3), allowMalformed: true);
  }
  if (bytes.length >= 2 && (bytes[0] == 0xfe && bytes[1] == 0xff || bytes[0] == 0xff && bytes[1] == 0xfe)) {
    final label = bytes[0] == 0xfe ? 'utf-16be' : 'utf-16le';
    if (NativeLib.isAvailable) return NativeBridge.decodeText(label, Uint8List.sublistView(bytes, 2));
  }
  var declared = _charset.firstMatch(contentType ?? '')?[1];
  if (declared == null && (_isHtml(contentType) || _isXml(contentType))) {
    final head = _markupHead(bytes);
    if (_isHtml(contentType)) {
      declared = _metaCharset.firstMatch(head)?[1];
      // A `<meta>` just read as ASCII cannot mean UTF-16 (HTML standard).
      if (declared != null && declared.toLowerCase().startsWith('utf-16')) declared = null;
    }
    if (declared == null && _isXml(contentType)) {
      declared = _xmlEncoding.firstMatch(head)?[1];
    }
  }
  return switch (declared?.toLowerCase()) {
    null || 'utf-8' || 'utf8' || 'unicode-1-1-utf-8' => utf8.decode(bytes, allowMalformed: true),
    // The HTML standard reads `iso-8859-1` as windows-1252: its C1 bytes are curly quotes.
    'windows-1252' || 'cp1252' || 'iso-8859-1' || 'latin1' || 'latin-1' || 'us-ascii' || 'ascii' => _windows1252(bytes),
    final label when NativeLib.isAvailable => NativeBridge.decodeText(label, bytes),
    _ => utf8.decode(bytes, allowMalformed: true),
  };
}

/// HTML or missing: a `<meta>` may declare the charset.
bool _isHtml(String? contentType) => switch (_mediaType(contentType)) {
  null || '' || 'text/html' || 'application/xhtml+xml' => true,
  _ => false,
};

/// XML or missing: the prolog may declare the encoding.
bool _isXml(String? contentType) => switch (_mediaType(contentType)) {
  null || '' => true,
  final type => type.endsWith('/xml') || type.endsWith('+xml'),
};

String? _mediaType(String? contentType) => contentType?.split(';').first.trim().toLowerCase();

String _markupHead(Uint8List bytes) =>
    latin1.decode(Uint8List.sublistView(bytes, 0, bytes.length < 2048 ? bytes.length : 2048), allowInvalid: true);

/// windows-1252 is Latin-1 with 27 printable characters where Latin-1 has C1 controls.
const _windows1252High = <int>[
  0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f,
  0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

/// Into a [Uint16List]: a 5 MB page is 9 ms, 60 as a `List<int>`.
String _windows1252(Uint8List bytes) {
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    units[i] = b >= 0x80 && b <= 0x9f ? _windows1252High[b - 0x80] : b;
  }
  return String.fromCharCodes(units);
}

/// Something a request can be sent through: the real client, a scope's wrapper, a mock.
///
/// {@category Networking}
abstract interface class Client {
  /// Sends [request]; the body is still arriving.
  ///
  /// The contract: a non-2xx is a [StreamedResponse], not a throw; a transport failure is a
  /// [ClientException] or a `dart:io` exception; [StreamedResponse.url] is the URL that
  /// *answered*; an unknown [RequestKey] is ignored. Send [Request.open], of length
  /// [Request.contentLength] — a `files:` upload is not in [Request.bytes].
  ///
  /// **Sending consumes a request**: a client may write on it (a scope stamps headers and
  /// `cookie`), so a caller reusing one sends a [Request.copy].
  Future<StreamedResponse> send(Request request);

  /// Releases connections; the client cannot be used afterwards.
  Future<void> close();
}

/// Discards a response body and frees its connection; completes when it is free.
///
/// Up to [_reusable] is read to the end, since a connection cut mid-body cannot be reused; a
/// larger body, or one slower than a second, is cancelled.
Future<void> _drain(StreamedResponse response) {
  final StreamSubscription<List<int>> sub;
  try {
    sub = response.stream.listen(null, cancelOnError: true);
  } on StateError {
    return Future.value(); // already read, or already being drained
  }
  final done = Completer<void>();
  void settle([Object? _]) {
    if (!done.isCompleted) done.complete();
  }

  void cut() {
    settle();
    unawaited(sub.cancel().catchError((_) {}));
  }

  var seen = 0;
  final patience = Timer(const Duration(seconds: 1), cut);
  sub
    ..onData((chunk) {
      if ((seen += chunk.length) > _reusable) cut();
    })
    ..onDone(settle)
    ..onError(settle);
  if ((response.contentLength ?? 0) > _reusable) cut();
  return done.future.whenComplete(patience.cancel);
}

/// The most of an unwanted body [_drain] reads to keep its connection.
const _reusable = 64 * 1024;

/// Whether [request] wants the stored bytes — [Request.raw], or a `range`, which counts them —
/// so it asks for `identity` and is never decoded.
bool _literal(Request request) => Request.raw(request) == true || request.headers.containsKey('range');

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

  final Semaphore? _permits;

  /// [perHost] caps connections to one origin; [connections] caps transfers across all
  /// hosts, each held until its body ends. [connectTimeout] bounds the handshake alone
  /// (`Http.scope(timeout:)` bounds the response).
  ///
  /// [proxy] is `http://user:pass@host:8080`; without it `http_proxy`/`no_proxy` apply. A
  /// proxy that seems to hang may have rejected the password: `dart:io` retries a 407 forever,
  /// bounded only by `Http.scope(timeout:)`. [insecure] accepts any certificate — for a
  /// self-signed intranet host only. [client] is an `HttpClient` configured elsewhere, with
  /// these settings applied on top.
  IoClient({
    int? connections,
    int? perHost,
    Duration? connectTimeout,
    Uri? proxy,
    bool insecure = false,
    HttpClient? client,
  }) : _client = client ?? HttpClient(),
       _permits = connections == null ? null : Semaphore(connections) {
    if (perHost != null) _client.maxConnectionsPerHost = perHost;
    if (connectTimeout != null) _client.connectionTimeout = connectTimeout;
    if (insecure) _client.badCertificateCallback = (_, _, _) => true;
    if (proxy != null) {
      _client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
      if (proxy.userInfo.isNotEmpty) {
        final colon = proxy.userInfo.indexOf(':');
        final user = colon == -1 ? proxy.userInfo : proxy.userInfo.substring(0, colon);
        final password = colon == -1 ? '' : proxy.userInfo.substring(colon + 1);
        final credentials = HttpClientBasicCredentials(user, password);
        _client.addProxyCredentials(proxy.host, proxy.port, '', credentials);
        // `dart:io` matches proxy credentials by realm; supply them for whichever realm is
        // asked, once, so a wrong password fails instead of looping.
        final asked = <String>{};
        _client.authenticateProxy = (host, port, scheme, realm) async {
          if (!asked.add('$host:$port/$realm')) return false;
          _client.addProxyCredentials(host, port, realm ?? '', credentials);
          return true;
        };
      }
    }
    // Decoded here instead: `dart:io` knows only gzip; see [_Encoding].
    _client.autoUncompress = false;
  }

  /// Honours the enclosing [Cancel.scope]: a cancel aborts the request — waiting for headers
  /// or mid-body — with [CancelledException].
  @override
  Future<StreamedResponse> send(Request request) async {
    Cancel.throwIfCancelled();
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

  /// Walks the redirect chain itself: `dart:io` copies every header, credentials included,
  /// onto a hop to another site. This puts [Request._hop]'s policy behind `url.get()`.
  Future<StreamedResponse> _send(Request request, void Function() release) async {
    var current = request;
    for (var hop = 0; ; hop++) {
      final res = await _once(current);
      final next = current.followRedirects ? await _next(current, res, hop, request.url) : null;
      // Only the last hop carries the permit; draining an earlier one must not release it.
      if (next == null) return res._carrying(_guarded(res.stream, release, Cancel.token));
      current = next;
    }
  }

  Future<StreamedResponse> _once(Request request) async {
    final HttpClientResponse response;
    final token = Cancel.token;
    void Function()? heard;
    final contentLength = request.contentLength;
    final io = await _client.openUrl(request.method, request.url);
    try {
      if (token != null) {
        if (token.isCancelled) {
          io.abort(_cancelled(token));
          throw _cancelled(token);
        }
        // Until the headers; after, [_guarded] stops the body (`dart:io` ignores the abort).
        heard = token.onCancel(() => io.abort(_cancelled(token)));
      }
      io
        ..followRedirects = false
        ..contentLength = contentLength;
      io.headers.set('accept-encoding', _literal(request) ? 'identity' : _acceptEncoding);
      request.headers.forEach((k, v) => io.headers.set(k, v));
      // A held body is one write; a `files:` one is pumped, never in memory.
      if (request._multipart != null) {
        await io.addStream(request.open());
      } else if (request.bytes.isNotEmpty) {
        io.add(request.bytes);
      }
      response = await io.close();
    } on HttpException catch (e) {
      io.abort(e);
      throw ClientException(e.message, request.url);
    } catch (e) {
      io.abort(e);
      rethrow;
    } finally {
      heard?.call();
    }
    final headers = Headers();
    // One value per name. `set-cookie` joins with a newline, not a comma (its `Expires` holds
    // one) — as Chrome's DevTools protocol does, so `ChromeClient` agrees.
    response.headers.forEach((name, values) => headers[name] = values.join(name == 'set-cookie' ? '\n' : ', '));
    Stream<List<int>> body = response.handleError(
      (Object e) => throw ClientException(e is HttpException ? e.message : '$e', request.url),
      test: (e) => e is HttpException,
    );
    var length = response.contentLength == -1 ? null : response.contentLength;
    final encoding = _hasBody(response.statusCode, request.method) && !_literal(request)
        ? _Encoding.of(headers['content-encoding'])
        : null;
    if (encoding != null) {
      // Both described the bytes on the wire, not what the caller reads.
      body = _inflated(body, encoding, request.url);
      length = null;
      headers
        ..remove('content-length')
        ..remove('content-encoding');
    }
    return StreamedResponse(
      body,
      response.statusCode,
      contentLength: length,
      headers: headers,
      request: request,
      url: request.url,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  Future<void> close() async => _client.close(force: true);

  /// [body], releasing the permit however it ends, and failing with [CancelledException] when
  /// [token] is cancelled mid-body, so a stalled server cannot hold the program open.
  static Stream<List<int>> _guarded(Stream<List<int>> body, void Function() release, CancelToken? token) {
    StreamSubscription<List<int>>? source;
    void Function()? unheard;
    var ended = false;
    void end() {
      if (ended) return;
      ended = true;
      unheard?.call();
      release();
    }

    late final StreamController<List<int>> out;
    out = StreamController<List<int>>(
      sync: true,
      onListen: () {
        source = body.listen(
          out.add,
          onError: out.addError,
          onDone: () {
            end();
            out.close();
          },
        );
        if (token == null) return;
        unheard = token.onCancel(() {
          final cut = source;
          source = null;
          end();
          unawaited(cut?.cancel().catchError((Object _) {}));
          out
            ..addError(_cancelled(token))
            ..close();
        });
      },
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () {
        end();
        return source?.cancel();
      },
    );
    return out.stream;
  }
}
