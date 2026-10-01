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
/// A body is given one way, by what it is — [text], [bytes], [form], [json] or `files` — and
/// the same words name it on [UriExtensions.post] and on `follow`. At most one may be set,
/// `form` with `files` being the one pair that means a single body; the matching
/// `content-type` comes with it.
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
  /// even inside `Http.scope(client: chrome)`. [IoClient] renders nothing, and reads it as
  /// *the stored bytes*: it asks for `identity` and decodes nothing, so a `.gz` served with
  /// `content-encoding: gzip` is written as the `.gz` it is, and a resume appends to a part
  /// made of the same bytes.
  static const raw = RequestKey<bool>('raw');

  final String method;
  final Uri url;
  final Headers headers;
  Uint8List bytes;

  /// Whether the client follows redirects itself, up to [maxRedirects]. The scrape engine
  /// turns this off and follows its own.
  bool followRedirects = true;
  int maxRedirects = 20;

  /// Client-specific directives, absent until one is set; see [RequestKey].
  Map<RequestKey<Object>, Object>? _directives;

  /// A body that is never held: `files:`, streamed from disk. Null for every other body.
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

  /// The body, for the client that sends it.
  ///
  /// **A client sends this, not [bytes].** A buffered body is one chunk of [bytes]; a `files:`
  /// body is opened from disk each time it is asked for, and [bytes] is empty for it, because
  /// the whole point of naming a file instead of reading one is that it never has to fit in
  /// memory. Opening it again rather than replaying a stream is also what lets a 307 and a
  /// retry send the same upload a second time.
  Stream<List<int>> open() => _multipart?.open() ?? Stream.value(bytes);

  /// What this request's `content-length` is, whether the body is held or streamed.
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

  /// Sets the directive [key] carries for the client that answers this request.
  ///
  /// `request[waitFor] = '.item'`; read it back with the key, `waitFor(request)`. Throws
  /// [ArgumentError] when [value] is not of the key's type.
  void operator []=(RequestKey<Object> key, Object value) {
    if (!key._accepts(value)) throw ArgumentError.value(value, key.name, 'is not what this key holds');
    (_directives ??= {})[key] = value;
  }

  /// An independent copy: same method, URL, headers, body, options and directives.
  ///
  /// The body buffer is shared rather than duplicated. Every send copies the request it was
  /// handed, so a 50 MB upload was allocated twice on its way out for nothing; what the copy
  /// is for is the headers a client writes on, and those are copied.
  Request copy() => Request(method, url, headers: headers)
    ..bytes = bytes
    .._multipart = _multipart
    ..followRedirects = followRedirects
    ..maxRedirects = maxRedirects
    .._directives = _directives == null ? null : Map.of(_directives!);

  /// Sends this request through the enclosing [Http.scope]'s client, or a fresh one, and
  /// buffers the body: `await Request('POST', url, json: {...}).send()`.
  ///
  /// The verbs on [UriExtensions] and [ClientExtensions] are this with the request built
  /// for you; what comes back is a [Fetch], whose readings throw unless 2xx.
  ///
  /// This request is copied before it goes out, so it comes back untouched and sending it
  /// twice sends it twice — a scope stamps its `cookie` and default headers onto what it
  /// sends, and without the copy the second send would carry the first send's jar and skip
  /// the refresh. [Response.request] is the copy that went on the wire.
  ///
  /// Inside `Http.scope(retries:)`, a body cut off half-way is fetched again like any other
  /// transport failure — for a method that may be sent twice; see [Http.scope].
  Fetch send() => Fetch._(_buffered(this));

  /// The request that follows a [status] redirect to [to] — the chain's policy, written once
  /// for the three places that walk a chain: [IoClient], the scope that walks one to keep the
  /// cookies each hop sets, and the crawl engine that walks its own.
  ///
  /// 303, and 301 or 302 on anything but GET and HEAD, become a GET with no body, which is
  /// what every browser does; 307 and 308 keep both. Credentials do not follow to another
  /// origin — another host, but also `http` after `https`, or another port — as a
  /// browser's would not: a downgrade would put the bearer token on the wire in the clear.
  Request _hop(Uri to, int status) {
    final downgrade = method != 'HEAD' && (status == 303 || ((status == 301 || status == 302) && method != 'GET'));
    final cross = !_sameOrigin(to, url);
    final next = Request(downgrade ? 'GET' : method, to)
      ..followRedirects = followRedirects
      ..maxRedirects = maxRedirects
      .._directives = _directives == null ? null : Map.of(_directives!);
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

/// Puts at most one of [text], [bytes], [form], [json] and [files] on [request]; more than one
/// is an [ArgumentError]. The one place the body words are turned into a body.
///
/// [form] with [files] is the one combination that is not two bodies: they are the fields and
/// the files of the same `multipart/form-data`, which is how a browser sends a form that has
/// a file input on it.
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

/// The `multipart/form-data` a `files:` body is: the fields, then the files, each read off
/// disk a chunk at a time and never held.
///
/// It is made of paths rather than of bytes, which is what lets [Request.open] be called more
/// than once — a 307 that keeps the method, a retry after a reset connection — where a
/// `Stream` handed over once could only be sent once.
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

  /// The length `content-length` announces, which has to be known before a byte goes out.
  ///
  /// The `stat` per file is synchronous on purpose: this is the one moment the length is
  /// needed and there is nothing to overlap it with, and a file that is not there fails here,
  /// naming itself, instead of half-way through an upload the server is already reading.
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

  /// A quoted-string value, with the three characters that would end it early taken out —
  /// which is what a browser does with a filename that has a quote in it.
  static String _quoted(String value) => value.replaceAll('"', '%22').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
}

final _crlf = utf8.encode('\r\n');

/// The content type an uploaded file announces. Only the extensions an upload actually has;
/// anything else is bytes, which is what a server assumes anyway.
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

/// Whether [a] and [b] are one origin — scheme, host and port — which is what a credential
/// belongs to. `Uri.port` is the scheme's default when none is written, so `:443` and
/// nothing agree.
bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && a.port == b.port && a.host.toLowerCase() == b.host.toLowerCase();

/// What a response that is not the one asked for says about itself: `404 Not Found`.
String _status(int code, String? reason) => reason == null || reason.isEmpty ? '$code' : '$code $reason';

/// What an operation the enclosing [Cancel.scope] stopped throws.
CancelledException _cancelled(CancelToken token) =>
    CancelledException(token.reason?.toString() ?? 'Operation was cancelled.');

/// Whether [error] is one a second attempt might not meet: the connection, not the request.
///
/// A TLS failure is the same on every attempt, and a cancel is not a failure at all.
bool _transient(Object error) =>
    (error is ClientException || error is SocketException || error is HttpException || error is TimeoutException) &&
    !_certain(error);

/// The request that follows [res] in [current]'s chain — [res]'s body drained first, so the
/// hop can have its connection — or `null` when [res] is where the chain ends. [first] is the
/// URL the chain began at, which is the one a caller would recognise in the error.
///
/// Written once for the two clients that walk a chain a response at a time — [IoClient], and
/// the scope that walks one to keep each hop's cookies.
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

  /// This response over another [body]: the same status, headers and URL.
  StreamedResponse _carrying(Stream<List<int>> body) => StreamedResponse(
    body,
    statusCode,
    contentLength: contentLength,
    headers: headers,
    request: request,
    url: url,
    reasonPhrase: reasonPhrase,
  );

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

  @override
  String toString() => 'Response($statusCode${reasonPhrase == null ? '' : ' $reasonPhrase'}, ${bytes.length} bytes)';
}

/// A request on its way: awaited, the [Response] whatever its status; read, the body —
/// and only a 2xx one.
///
/// Every verb returns one. The reading a call site asks for says what it wants, so the
/// status check comes with it, as `run('…').text` implies `quiet`:
///
/// ```dart
/// final score = (await api.post(json: x).json)['score'];   // throws unless 2xx
/// final res = await api.post(json: x);                       // any status; check res.isOk
/// ```
///
/// A reading that meets another status throws [HttpException] naming it and the URL that
/// answered — `HttpException: 404 Not Found, uri = https://…` — which is what a script that
/// lets it reach `Cli.run` wants reported. An error page parses fine and then matches
/// nothing; this is why the readings do not parse it.
///
/// {@category Networking}
final class Fetch implements Future<Response> {
  final Future<Response> _response;

  Fetch._(this._response);

  /// The response, or [HttpException] unless its status is 2xx.
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
      // The send retries its own failures; what is left to this loop is the body.
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

/// Bytes the server sent, as text, decided in the order a browser decides it.
///
/// 1. A byte-order mark, which outranks every label: a page saved as UTF-8 with a BOM and
///    served as `charset=iso-8859-1` is UTF-8.
/// 2. The `content-type`'s `charset`.
/// 3. For HTML only — `text/html`, or no type at all — a `<meta>` in the first 2 KiB. The
///    legacy web serves a bare `text/html` and names its charset there. JSON, CSS and
///    JavaScript are not searched for one: a `<meta` inside a JSON string is not a label.
/// 4. UTF-8, with bad bytes replaced.
///
/// UTF-8 and windows-1252 decode in Dart. Any other WHATWG label — Shift_JIS, EUC-KR, GBK,
/// Big5, KOI8-R, UTF-16 — is the native library's, and reads as UTF-8 without it.
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
      // The HTML standard: a page cannot declare itself UTF-16 from inside, since its `<meta>`
      // was just read as ASCII — the label is wrong, and the page is UTF-8.
      if (declared != null && declared.toLowerCase().startsWith('utf-16')) declared = null;
    }
    if (declared == null && _isXml(contentType)) {
      declared = _xmlEncoding.firstMatch(head)?[1];
    }
  }
  return switch (declared?.toLowerCase()) {
    null || 'utf-8' || 'utf8' || 'unicode-1-1-utf-8' => utf8.decode(bytes, allowMalformed: true),
    // The HTML standard decodes `iso-8859-1` as windows-1252, and a page labelled either
    // one almost always means the latter: the bytes Latin-1 leaves as C1 controls are
    // curly quotes and dashes in every page that actually uses them.
    'windows-1252' || 'cp1252' || 'iso-8859-1' || 'latin1' || 'latin-1' || 'us-ascii' || 'ascii' => _windows1252(bytes),
    final label when NativeLib.isAvailable => NativeBridge.decodeText(label, bytes),
    _ => utf8.decode(bytes, allowMalformed: true),
  };
}

/// Whether a `content-type` is one whose charset may be declared inside an HTML document.
bool _isHtml(String? contentType) {
  final type = contentType?.split(';').first.trim().toLowerCase();
  return type == null || type.isEmpty || type == 'text/html' || type == 'application/xhtml+xml';
}

/// Whether a `content-type` is XML or missing, where encoding may be declared in the XML prolog.
bool _isXml(String? contentType) {
  final type = contentType?.split(';').first.trim().toLowerCase();
  return type == null || type.isEmpty || type.endsWith('/xml') || type.endsWith('+xml');
}

/// The first 2 KiB decoded as Latin-1 to inspect for markup encoding declarations.
String _markupHead(Uint8List bytes) =>
    latin1.decode(Uint8List.sublistView(bytes, 0, bytes.length < 2048 ? bytes.length : 2048), allowInvalid: true);

/// windows-1252 is Latin-1 with 27 printable characters where Latin-1 has C1 controls.
const _windows1252High = <int>[
  0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f,
  0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

/// Into a [Uint16List] rather than a `List<int>`: a 5 MB page went from 60 ms to 9.
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
  /// Sends [request] and answers with the response whose body is still arriving.
  ///
  /// The contract an implementation owes its caller: a non-2xx status is a [StreamedResponse],
  /// not a throw; a transport failure is a [ClientException] or a `dart:io` exception;
  /// [StreamedResponse.url] is the URL that *answered*, after whatever redirects were
  /// followed; and a [RequestKey] the implementation does not recognise is ignored.
  ///
  /// The body to send is [Request.open], and its length is [Request.contentLength]; a
  /// `files:` upload is empty in [Request.bytes] and arrives only through those two.
  ///
  /// A client may write on the request it is handed — a scope stamps its default headers
  /// and its `cookie` there — so **sending consumes a request**. Everything in this module
  /// that sends one the caller owns copies it first ([Request.send],
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

/// Discards a response body, releasing the connection instead of holding it until the client
/// reaps an idle one.
///
/// A body up to [_reusable] is read to its end rather than cancelled, because a connection
/// cut off mid-body cannot be reused: five GETs over a three-hop chain were eleven connections
/// and are one. A larger one, or one that takes over a second, is cancelled. The future
/// completes when the connection is free, so a redirect hop that awaits it can take it.
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

/// Whether [request] wants the bytes as the server stores them — [Request.raw], or a `range`,
/// which counts stored bytes. Such a request asks for `identity` and is never decoded: a
/// resumed download once decoded its first half and appended the second raw, and passed the
/// length check as neither the server's file nor its contents.
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

  /// The total-transfer cap, or `null` when the client was built without `connections:`.
  final Semaphore? _permits;

  /// [perHost] is how many connections may be open to one origin at a time; [connections]
  /// caps the total in flight across every host, which `dart:io` has no setting for. A
  /// permit is held until the body is read to the end, cancelled or thrown, so the cap
  /// counts transfers rather than handshakes.
  ///
  /// [connectTimeout] bounds the handshake alone — [Http.scope]'s `timeout:` bounds the
  /// wait for a response, which is a different thing and composes with this one. A
  /// `user-agent` or `connection: close` is a header: `Http.scope(headers: …)`.
  ///
  /// [proxy] sends everything through an HTTP proxy — `http://user:pass@host:8080`, with the
  /// credentials taken from the URL. Without it `dart:io`'s own reading of `http_proxy` and
  /// `no_proxy` still applies.
  ///
  /// A proxy that *rejects* the credentials is `dart:io`'s one rough edge here: it retries the
  /// 407 rather than handing it back, and there is no way to stop it from outside `HttpClient`.
  /// `Http.scope(timeout:)` bounds it, and a proxy that seems to hang is worth suspecting of
  /// having rejected the password rather than of being slow. [insecure] accepts a certificate that does not verify, which
  /// is a self-signed intranet host and should be nothing else.
  ///
  /// [client] takes over an `HttpClient` configured elsewhere — a certificate policy, a
  /// `findProxy` of its own; the settings here are applied on top of it.
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
        // `dart:io` matches proxy credentials by the realm the proxy names, so registering
        // them under the empty one answers only a proxy that uses the empty one — every other
        // proxy 407s, finds nothing to send, and is asked again forever. This supplies them
        // for whatever realm was actually asked for, and once per realm, so a wrong password
        // fails instead of looping.
        final asked = <String>{};
        _client.authenticateProxy = (host, port, scheme, realm) async {
          if (!asked.add('$host:$port/$realm')) return false;
          _client.addProxyCredentials(host, port, realm ?? '', credentials);
          return true;
        };
      }
    }
    // The bodies are decoded here instead, because `dart:io` knows only gzip and this asks
    // for what a browser asks for; see [_Encoding].
    _client.autoUncompress = false;
  }

  /// Honours the enclosing [Cancel.scope]: a cancel aborts the request where it stands —
  /// waiting for headers, or half-way through a body — and what it was doing fails with
  /// [CancelledException], so a stalled server cannot hold a cancelled program open.
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

  /// Walks the redirect chain rather than letting `dart:io` walk it.
  ///
  /// `dart:io` reports the hops it followed but not the headers they carried, and copies
  /// every header — a credential included — onto a hop that may be another site. Owning the
  /// chain is what puts [Request._hop]'s policy behind a plain `url.get()`, the same policy a
  /// crawl already had, and what makes [StreamedResponse.url] the URL that answered rather
  /// than one re-derived from a list of locations afterwards.
  Future<StreamedResponse> _send(Request request, void Function() release) async {
    var current = request;
    for (var hop = 0; ; hop++) {
      final res = await _once(current);
      final next = current.followRedirects ? await _next(current, res, hop, request.url) : null;
      // Only the last hop carries the permit: an intermediate one is drained, and draining a
      // body that carried it would hand it back while the chain was still walking.
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
        // Until the headers are in, aborting is what stops it; after, the body is
        // [_guarded]'s — `dart:io` ignores an abort once there is a response.
        heard = token.onCancel(() => io.abort(_cancelled(token)));
      }
      io
        ..followRedirects = false
        ..contentLength = contentLength;
      io.headers.set('accept-encoding', _literal(request) ? 'identity' : _acceptEncoding);
      request.headers.forEach((k, v) => io.headers.set(k, v));
      // A held body goes out in one write; a streamed one is pumped, so a `files:` upload
      // never exists in memory at either end of the socket.
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
    // One value per name, so a header the server repeated is joined. `set-cookie` is the
    // one that cannot be joined with a comma — its `Expires` holds one — and a newline
    // cannot appear in a header value, so it separates them unambiguously. Chrome's
    // DevTools protocol joins the same header the same way, so [ChromeClient] agrees.
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
      // The length and the encoding on the wire described the bytes before they were decoded;
      // neither describes what the caller is about to read.
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

  /// Hands the permit back when the body ends, however it ends — read to completion, thrown,
  /// or cancelled by a caller that stopped listening.
  ///
  /// Inside a [Cancel.scope] it is also where a cancel lands once the headers are in: the body
  /// fails with [CancelledException] and the connection is let go, so a server that stalls
  /// mid-body cannot hold a cancelled download — or the program — open.
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
