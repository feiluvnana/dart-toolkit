part of '../message.dart';

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

/// A directive a [Client] may honour, carried on a [Request] under a typed name: for what HTTP
/// has no word for, such as how a browser renders the page (`Chrome.render`).
///
/// ```dart
/// final request = Request('GET', url)..[Chrome.render] = Render(waitFor: '.results');
/// ```
///
/// A client reads it as `key(request)` and **ignores every key it does not know**, so the same
/// code runs on [IoClient] and on `Chrome`.
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
/// The body is at most one of `text:`, `bytes:`, `form:`, `json:`, `files:` (with `form:`, one
/// `multipart/form-data` body) or `file:`, with its `content-type`; the same words name it on
/// `url.post(…)`. A body is fixed once made: [copy] makes a changed one.
///
/// {@category Networking}
final class Request {
  /// Answer with the resource itself, never a rendering of it: `request[Request.raw] = true`.
  ///
  /// A rendering client (`Chrome`) hands such a request to plain HTTP; [IoClient] asks for
  /// `identity` and decodes nothing. Every download sets it, so a `.gz` is written as the `.gz`
  /// it is and a resume appends the same bytes.
  static const raw = RequestKey<bool>('raw');

  final String method;
  final Uri url;
  final Headers headers;

  /// Whether the client follows redirects itself, up to [redirects].
  bool followRedirects = true;
  int redirects = 20;

  Map<RequestKey<Object>, Object>? _directives;
  _Body _content;

  Request(
    String method,
    this.url, {
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, Object?>? form,
    Object? json,
    Map<String, String>? files,
    String? file,
  }) : method = method.toUpperCase(),
       headers = Headers(headers),
       _content = _Body.none {
    _content = _body(this.headers, text: text, bytes: bytes, form: form, json: json, files: files, file: file);
  }

  /// The body when it is held in memory; empty for none, and for a `files:` or `file:` body,
  /// which is streamed from disk by [open].
  Uint8List get bytes => switch (_content) {
    _Held(:final bytes) => bytes,
    _ => _empty,
  };

  /// The held body as text, UTF-8.
  String get text => utf8.decode(bytes, allowMalformed: true);

  /// The body, for the client that sends it. **A client sends this, not [bytes]**: a `files:` or
  /// `file:` body is opened from disk on each call, so a 307 or a retry can send it again.
  Stream<List<int>> open() => _content.open();

  /// The `content-length`, whether the body is held or streamed: a presigned `PUT` refuses a
  /// chunked one. A streamed body's files are measured once, on first ask.
  int get contentLength => _content.length;

  /// Whether the body is streamed from disk rather than held.
  bool get isStreamed => _content is _FileBody || _content is _Multipart;

  /// Sets a directive: `request[Chrome.render] = Render(…)`, read back as `Chrome.render(request)`.
  /// Throws [ArgumentError] when [value] is not of the key's type.
  void operator []=(RequestKey<Object> key, Object value) {
    if (!key._accepts(value)) throw ArgumentError.value(value, key.name, 'Invalid value, not what this key holds');
    (_directives ??= {})[key] = value;
  }

  /// An independent copy: the same method, URL, headers, body, options and directives, with what
  /// is given replaced. A body given replaces the body; its `content-type` is the new one's.
  Request copy({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, Object?>? form,
    Object? json,
    Map<String, String>? files,
    String? file,
  }) {
    final next = _options(Request(method ?? this.method, url ?? this.url, headers: headers ?? this.headers));
    if (text != null || bytes != null || form != null || json != null || files != null || file != null) {
      next.headers.remove('content-type');
      next._content = _body(next.headers, text: text, bytes: bytes, form: form, json: json, files: files, file: file);
    } else {
      next._content = _content;
    }
    return next;
  }

  /// [to] with this request's redirect options and a copy of its directives.
  Request _options(Request to) => to
    ..followRedirects = followRedirects
    ..redirects = redirects
    .._directives = _directives == null ? null : Map.of(_directives!);

  @override
  String toString() => '$method $url';
}

final _empty = Uint8List(0);

/// What a [Request] carries: nothing, bytes, a file, or a multipart form of fields and files.
sealed class _Body {
  const _Body();

  static final none = _Held(Uint8List(0));

  Stream<List<int>> open();

  int get length;
}

final class _Held extends _Body {
  final Uint8List bytes;

  const _Held(this.bytes);

  @override
  Stream<List<int>> open() => Stream.value(bytes);

  @override
  int get length => bytes.length;
}

final class _FileBody extends _Body {
  final String path;
  int? _length;

  _FileBody(this.path);

  @override
  Stream<List<int>> open() => File(path).openRead();

  /// Measured once: a missing file fails here, naming itself, rather than half-way through.
  @override
  int get length => _length ??= File(path).lengthSync();
}

/// A `files:` body: the fields, then the files streamed off disk. Paths rather than a `Stream`,
/// so [Request.open] can be called again for a 307 or a retry.
final class _Multipart extends _Body {
  final Map<String, Object?> fields;

  /// Each field's file, by path.
  final Map<String, String> files;
  final String boundary;

  _Multipart(this.fields, this.files)
    : boundary = 'dartToolkit${base64UrlEncode([for (var i = 0; i < 12; i++) _random.nextInt(256)])}';

  String get contentType => 'multipart/form-data; boundary=$boundary';

  /// Each part's header, and the file whose bytes follow it.
  late final List<(Uint8List, String?)> _parts = [
    for (final MapEntry(:key, :value) in _fields(fields).entries)
      for (final v in value is List<String> ? value : [value])
        (utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${_quoted(key)}"\r\n\r\n$v\r\n'), null),
    for (final MapEntry(:key, :value) in files.entries)
      (
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="${_quoted(key)}"; filename="${_quoted(_baseName(value))}"\r\n'
          'Content-Type: ${_mime(_baseName(value))}\r\n\r\n',
        ),
        value,
      ),
  ];

  late final Uint8List _tail = utf8.encode('--$boundary--\r\n');

  /// Measured once, synchronously on purpose: nothing overlaps it, and a missing file fails
  /// here, naming itself, rather than half-way through the upload.
  @override
  late final int length = _parts.fold(_tail.length, (n, part) {
    final (head, file) = part;
    return n + head.length + (file == null ? 0 : File(file).lengthSync() + 2);
  });

  @override
  Stream<List<int>> open() async* {
    for (final (head, file) in _parts) {
      yield head;
      if (file != null) {
        yield* File(file).openRead();
        yield _crlf;
      }
    }
    yield _tail;
  }

  /// A quoted-string value, escaped as a browser escapes a filename.
  static String _quoted(String value) => value.replaceAll('"', '%22').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
}

/// At most one body, with its `content-type` put on [headers] unless they name one; two is an
/// [ArgumentError]. [form] with [files] is one `multipart/form-data` body: a browser form with a
/// file input.
_Body _body(
  Headers headers, {
  String? text,
  List<int>? bytes,
  Map<String, Object?>? form,
  Object? json,
  Map<String, String>? files,
  String? file,
}) {
  final given = [
    if (text != null) 'text',
    if (bytes != null) 'bytes',
    if (form != null && files == null) 'form',
    if (files != null) 'files',
    if (json != null) 'json',
    if (file != null) 'file',
  ];
  if (given.length > 1) throw ArgumentError('Invalid body: pass at most one, but ${given.join(', ')} were all given');
  if (text != null) {
    headers.putIfAbsent('content-type', () => 'text/plain; charset=utf-8');
    return _Held(utf8.encode(text));
  }
  if (bytes != null) return _Held(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  if (json != null) {
    headers.putIfAbsent('content-type', () => 'application/json; charset=utf-8');
    return _Held(utf8.encode(jsonEncode(json)));
  }
  if (file != null) {
    headers.putIfAbsent('content-type', () => _mime(_baseName(file)));
    return _FileBody(file);
  }
  if (files != null) {
    final body = _Multipart(form ?? const {}, files);
    headers['content-type'] = body.contentType;
    return body;
  }
  if (form != null) {
    headers['content-type'] = 'application/x-www-form-urlencoded; charset=utf-8';
    return _Held(utf8.encode(Uri(queryParameters: _fields(form)).query));
  }
  return _Body.none;
}

/// [form]'s fields as strings: `null` dropped, an [Iterable] one value per element.
Map<String, Object> _fields(Map<String, Object?> form) => {
  for (final MapEntry(:key, :value) in form.entries)
    if (value != null) key: value is Iterable ? [for (final x in value) '$x'] : '$value',
};

final _crlf = utf8.encode('\r\n');

/// For a multipart boundary no body can guess.
final _random = Random.secure();

/// [path]'s last segment, on either separator.
String _baseName(String path) => path.substring(path.lastIndexOf(_separator) + 1);
final _separator = RegExp(r'[/\\]');

/// The content type a file named [name] announces; anything unlisted is bytes.
String _mime(String name) => switch (name.substring(name.lastIndexOf('.') + 1).toLowerCase()) {
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

/// One `<target>; params` of a `Link` header (RFC 8288), and the `rel` among its params.
final _linkValue = RegExp(r'<([^>]*)>([^<]*)');
final _linkRel = RegExp(r'''(?:^|;)\s*rel\s*=\s*(?:"([^"]*)"|([^\s;,]+))''', caseSensitive: false);

/// `404 Not Found`, or `429 Too Many Requests (Retry-After 2 s)`.
String _status(int code, String? reason, [Headers? headers]) {
  var msg = reason == null || reason.isEmpty ? '$code' : '$code $reason';
  if (code == 429 || code == 503) {
    final after = headers?['retry-after']?.trim();
    if (after != null && after.isNotEmpty) {
      msg = '$msg (Retry-After ${int.tryParse(after) != null ? '$after s' : after})';
    }
  }
  return msg;
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

  /// The body in memory, as a [Response].
  Future<Response> read() async => Response.bytes(
    await _collect(stream, contentLength),
    statusCode,
    headers: headers,
    request: request,
    url: url,
    reasonPhrase: reasonPhrase,
  );
}

/// [stream]'s bytes in one buffer, at most [cap] of them: past it the rest is cut when [cut],
/// else [over] is thrown. With [expected] (a `Content-Length`) the buffer is allocated once and
/// each chunk copied straight in, rather than every chunk held and then copied together: half
/// the peak memory. It starts at no more than 64 MiB, so a lying header cannot force a huge
/// allocation, and doubles past that. [onChunk] hears the bytes so far after each chunk.
Future<Uint8List> _collect(
  Stream<List<int>> stream,
  int? expected, {
  int? cap,
  bool cut = false,
  Object Function()? over,
  void Function(int received)? onChunk,
}) async {
  if (expected == null || expected <= 0) {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (cap != null && builder.length + chunk.length > cap) {
        if (!cut) throw over!();
        builder.add(chunk.sublist(0, cap - builder.length));
        break;
      }
      builder.add(chunk);
      onChunk?.call(builder.length);
    }
    return builder.takeBytes();
  }
  final limit = cap ?? 0x7fffffffffffffff;
  var buffer = Uint8List(min(min(expected, limit), _preallocated));
  var length = 0;
  await for (final chunk in stream) {
    var take = chunk.length;
    if (length + take > limit) {
      if (!cut) throw over!();
      take = limit - length;
    }
    if (length + take > buffer.length) {
      // Toward the size claimed, which the bytes so far back, but at most 4× what has come.
      final needed = length + take;
      final claim = expected > needed ? expected : buffer.length * 2;
      final grown = Uint8List(min(max(needed, min(claim, needed * 4)), limit));
      grown.setRange(0, length, buffer);
      buffer = grown;
    }
    buffer.setRange(length, length + take, chunk);
    length += take;
    onChunk?.call(length);
    if (take < chunk.length) break;
  }
  // A short body leaves room: a view keeps it all, so a much shorter one is copied out.
  if (length == buffer.length) return buffer;
  return length < buffer.length ~/ 2
      ? Uint8List.fromList(Uint8List.sublistView(buffer, 0, length))
      : Uint8List.sublistView(buffer, 0, length);
}

/// The most a `Content-Length` is believed before bytes arrive to back it.
const _preallocated = 64 << 20;

/// A response with its body in memory.
///
/// Readings on a response in hand are lenient: `res.json`, `res.html`, `res.text` read the body
/// whatever the status. `await url.get()` is where the status is checked.
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

  /// The body decoded once: by a byte-order mark, else the `charset` of `content-type`, else for
  /// HTML or XML a `<meta charset>` or XML prolog, else UTF-8.
  String get text => _text ??= _decode(bytes, headers['content-type']);

  /// The `Link` header by `rel`, resolved against [url]: an API's pages are
  /// `res.rels['next']`, `null` on the last one.
  ///
  /// ```dart
  /// for (Uri? page = api; page != null; ) {
  ///   final res = await page.get();
  ///   items.addAll(res.json.list);
  ///   page = res.rels['next'];
  /// }
  /// ```
  Map<String, Uri> get rels {
    final header = headers['link'];
    if (header == null) return const {};
    final out = <String, Uri>{};
    for (final m in _linkValue.allMatches(header)) {
      final target = Uri.tryParse(m[1]!.trim());
      final rels = _linkRel.firstMatch(m[2]!);
      if (target == null || rels == null) continue;
      for (final rel in (rels[1] ?? rels[2]!).toLowerCase().split(' ')) {
        if (rel.isNotEmpty) out.putIfAbsent(rel, () => url?.resolveUri(target) ?? target);
      }
    }
    return out;
  }

  /// The cookies this response's `Set-Cookie` headers set, read leniently as a browser reads
  /// them: a value keeps its quotes, commas and spaces; a line with no name is skipped.
  List<HttpCookie> get cookies {
    final header = headers['set-cookie'];
    if (header == null || header.isEmpty) return const [];
    final from = url ?? request?.url ?? Uri();
    return [for (final line in header.split('\n')) ?_setCookie(line, from)];
  }

  /// The file name the server gives this: `Content-Disposition`'s `filename*`, then its
  /// `filename`, then the last segment of the URL that answered, made one file name safe on
  /// every OS; `''` when none names one. A download `into:` a folder names its file so.
  String get name => _serverName(headers, url);

  @override
  String toString() => 'Response($statusCode${reasonPhrase == null ? '' : ' $reasonPhrase'}, ${bytes.length} bytes)';
}

/// A non-2xx answer: an [HttpException] that keeps the [response], so an API's error body is
/// still there: `on StatusException catch (e) { e.response.json['error'] }`. Prints as
/// `404 Not Found from https://…`.
///
/// {@category Networking}
final class StatusException extends HttpException {
  /// The answer, body read (the start of it, for a large one).
  final Response response;

  StatusException(this.response)
    : super(_status(response.statusCode, response.reasonPhrase, response.headers), uri: response.url);

  @override
  String toString() => uri == null ? message : '$message from $uri';
}

/// The decoder of every charset past UTF-8 and windows-1252, which `http` installs (the native
/// library's): `null` reads as UTF-8, and so does a label it answers `null` for. A hook, so the
/// format libraries that read a [Response] do not compile the native bridge.
String? Function(String label, Uint8List bytes)? _charsets;

final _charset = RegExp(r'charset=["\x27]?([^;"\x27\s>]+)', caseSensitive: false);

/// A `charset` declared inside a `<meta>`, in either spelling; both carry `charset=`.
final _metaCharset = RegExp(r'''<meta[^>]+charset\s*=\s*["']?([\w-]+)''', caseSensitive: false);

/// An `encoding` declared in an XML prolog `<?xml ... encoding="..."?>`.
final _xmlEncoding = RegExp(r'''<\?xml\b[^>]*\bencoding\s*=\s*["']([\w-]+)["']''', caseSensitive: false);

/// Bytes as text, decided as a browser does: a BOM; the `content-type` charset; for HTML or
/// XML (or no type) a `<meta>` or prolog in the first 2 KiB, never in JSON, where `<meta` is
/// just a string; else UTF-8. Labels beyond UTF-8 and windows-1252 are [_charsets]', and read
/// as UTF-8 without it.
String _decode(Uint8List bytes, String? contentType) {
  if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
    return utf8.decode(Uint8List.sublistView(bytes, 3), allowMalformed: true);
  }
  if (bytes.length >= 2 && (bytes[0] == 0xfe && bytes[1] == 0xff || bytes[0] == 0xff && bytes[1] == 0xfe)) {
    final label = bytes[0] == 0xfe ? 'utf-16be' : 'utf-16le';
    if (_charsets?.call(label, Uint8List.sublistView(bytes, 2)) case final text?) return text;
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
    final label => _charsets?.call(label, bytes) ?? utf8.decode(bytes, allowMalformed: true),
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

/// The network said no before an answer came: a refused or reset connection, a TLS failure, a
/// SOCKS proxy's refusal, too many redirects, a body over a cap, a closed browser. An
/// [HttpException], as a non-2xx [StatusException] is, so `on HttpException` catches every way a
/// request fails but running out of time (a `TimeoutException`).
///
/// {@category Networking}
class ClientException extends HttpException {
  /// What the transport threw (a `SocketException`, a TLS `HandshakeException`) when this wraps
  /// one.
  final Object? cause;

  const ClientException(super.message, [Uri? uri, this.cause]) : super(uri: uri);

  @override
  String toString() {
    final head = uri == null ? message : '$message ($uri)';
    // A cause the message already quotes adds nothing; one it does not is the root to look at.
    return cause == null || '$cause'.contains(message) ? head : '$head\n  caused by: $cause';
  }
}

/// A cookie as a browser keeps it: what a `Set-Cookie` sets ([Response.cookies]), a `CookieJar`
/// holds and `chrome.cookies()` hands over. The value is kept as sent (quotes, commas, spaces
/// and JSON included) where `dart:io`'s `Cookie` refuses them.
///
/// {@category Networking}
final class HttpCookie {
  final String name;
  final String value;

  /// The host it was set by, or the `Domain` it named, lowercase and without a leading dot; a
  /// leading dot given here means [hostOnly] is `false`.
  final String domain;
  final String path;

  /// When it lapses; `null` for a session cookie.
  final DateTime? expires;

  /// Whether it goes over https only.
  final bool secure;

  /// Whether only [domain] itself matches, not its subdomains: it named no `Domain`.
  final bool hostOnly;

  /// Whether a page's scripts may not read it; kept for handing back to a browser.
  final bool httpOnly;

  /// A cookie for [domain]; an empty one is an [ArgumentError], since it would go nowhere.
  HttpCookie(
    this.name,
    this.value, {
    required String domain,
    this.path = '/',
    this.expires,
    this.secure = false,
    bool hostOnly = true,
    this.httpOnly = false,
  }) : domain = (domain.startsWith('.') ? domain.substring(1) : domain).toLowerCase(),
       hostOnly = hostOnly && !domain.startsWith('.') {
    if (this.domain.isEmpty) throw ArgumentError.value(domain, 'domain', 'Invalid cookie domain, expected a host');
  }

  @override
  String toString() => '$name=$value';
}

/// One `Set-Cookie` line from [from], read as RFC 6265 §5.2 does: the value is everything after
/// the first `=` up to the first `;`, whatever it holds; `null` without a name. With [strict], a
/// browser's refusals too: a `Secure` cookie over http, a `Domain` that is not this host or a
/// parent of it.
HttpCookie? _setCookie(String line, Uri from, {bool strict = false}) {
  final parts = line.split(';');
  final pair = parts.first;
  final eq = pair.indexOf('=');
  if (eq <= 0 || pair.substring(0, eq).trim().isEmpty) return null;
  final host = from.host.toLowerCase();
  if (host.isEmpty) return null;

  String? domain;
  var path = '';
  DateTime? expires;
  int? maxAge;
  var secure = false;
  var httpOnly = false;
  for (final attribute in parts.skip(1)) {
    final split = attribute.indexOf('=');
    final key = (split == -1 ? attribute : attribute.substring(0, split)).trim().toLowerCase();
    final value = split == -1 ? '' : attribute.substring(split + 1).trim();
    switch (key) {
      case 'domain':
        // An empty one is dropped and the cookie stays host-only (RFC 6265 §5.2.3).
        final lower = value.toLowerCase();
        final named = lower.startsWith('.') ? lower.substring(1) : lower;
        if (named.isNotEmpty) domain = named;
      case 'path':
        path = value;
      case 'expires':
        // Unparseable: the cookie stays for the browser session, as a browser keeps it.
        expires = _httpDate(value) ?? expires;
      case 'max-age':
        maxAge = int.tryParse(value);
      case 'secure':
        secure = true;
      case 'httponly':
        httpOnly = true;
    }
  }
  if (strict) {
    // A `Secure` cookie over plain http is refused (RFC 6265bis): anyone on the path could
    // have set it.
    if (secure && from.scheme != 'https') return null;
    // A domain may widen to a parent of the host, never another site or a bare suffix; an IP
    // must match exactly.
    final isIp = InternetAddress.tryParse(host) != null;
    if (domain != null &&
        (isIp ? host != domain : !(host == domain || (host.endsWith('.$domain') && domain.contains('.'))))) {
      return null;
    }
  }
  // Max-Age wins over Expires; one too large for a `Duration` is forever.
  if (maxAge != null) {
    expires = maxAge > 0x7fffffff ? DateTime.utc(9999) : DateTime.now().add(Duration(seconds: maxAge));
  }
  return HttpCookie(
    pair.substring(0, eq).trim(),
    pair.substring(eq + 1).trim(),
    domain: domain ?? host,
    path: path.startsWith('/') ? path : _defaultPath(from),
    expires: expires,
    secure: secure,
    hostOnly: domain == null,
    httpOnly: httpOnly,
  );
}

/// Where a cookie without a `Path` lives: the request path's directory.
String _defaultPath(Uri url) {
  final path = url.path;
  if (!path.startsWith('/')) return '/';
  final slash = path.lastIndexOf('/');
  return slash < 1 ? '/' : path.substring(0, slash);
}

/// An `Expires` or `Retry-After` date read as a browser does (RFC 6265 §5.1.1), or `null`.
///
/// Not `HttpDate.parse`, which refuses what servers send (PHP's `Wed, 21-Oct-2026 07:28:00
/// GMT`, a logout's `01-Jan-1970`): this reads tokens in any order, every form at once.
DateTime? _httpDate(String text) {
  int? hour, minute, second, day, month, year;
  for (final token in text.split(_dateDelimiters)) {
    if (token.isEmpty) continue;
    if (_dateTime.matchAsPrefix(token) case final m? when hour == null) {
      hour = int.parse(m[1]!);
      minute = int.parse(m[2]!);
      second = int.parse(m[3]!);
    } else if (_dateDay.matchAsPrefix(token) case final m? when day == null) {
      day = int.parse(m[1]!);
    } else if (month == null && token.length >= 3 && _months.contains(token.substring(0, 3).toLowerCase())) {
      month = _months.indexOf(token.substring(0, 3).toLowerCase()) + 1;
    } else if (_dateYear.matchAsPrefix(token) case final m? when year == null) {
      year = int.parse(m[1]!);
    }
  }
  if (hour == null || minute == null || second == null || day == null || month == null || year == null) return null;
  if (year >= 70 && year <= 99) year += 1900;
  if (year >= 0 && year <= 69) year += 2000;
  if (day < 1 || day > 31 || year < 1601 || hour > 23 || minute > 59 || second > 59) return null;
  final date = DateTime.utc(year, month, day, hour, minute, second);
  // `DateTime` rolls 31 February over into March; a browser refuses it.
  return date.day == day ? date : null;
}

/// RFC 6265's delimiters: tab, space, and punctuation but `:`.
final _dateDelimiters = RegExp(r'[\x09\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+');
final _dateTime = RegExp(r'(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D|$)');
final _dateDay = RegExp(r'(\d{1,2})(?:\D|$)');
final _dateYear = RegExp(r'(\d{2,4})(?:\D|$)');
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// [Response.name]'s reading of [headers] and [url].
String _serverName(Headers headers, Uri? url) {
  final disposition = headers['content-disposition'];
  if (disposition != null) {
    String? named;
    if (_extendedFilename.firstMatch(disposition) case final m?) named = _extended(m[1]!, m[2]!.trim());
    if (named == null) {
      if (_filename.firstMatch(disposition) case final m?) {
        named = m[1] != null ? m[1]!.replaceAllMapped(_quoted, (Match q) => q[1]!) : m[2]!.trim();
      }
    }
    // A name is a name, never a path: `../x` and `C:\x` keep only their last part.
    final name = _safeName((named ?? '').split(_separator).last);
    if (name.isNotEmpty) return name;
  }
  return url == null ? '' : _safeName(url.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => ''));
}

/// A `filename*` value (RFC 5987): its percent-escapes are bytes in [charset], UTF-8 or
/// ISO-8859-1; `null` for another charset or a broken escape.
String? _extended(String charset, String encoded) {
  final bytes = <int>[];
  for (var i = 0; i < encoded.length; i++) {
    final c = encoded.codeUnitAt(i);
    if (c == 0x25) {
      if (i + 2 >= encoded.length) return null;
      final byte = int.tryParse(encoded.substring(i + 1, i + 3), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
      i += 2;
    } else {
      bytes.add(c);
    }
  }
  return switch (charset.toLowerCase()) {
    'utf-8' || '' => utf8.decode(bytes, allowMalformed: true),
    'iso-8859-1' || 'latin1' => latin1.decode(bytes, allowInvalid: true),
    _ => null,
  };
}

final _extendedFilename = RegExp(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", caseSensitive: false);
final _filename = RegExp(r'filename\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;]+))', caseSensitive: false);
final _quoted = RegExp(r'\\(.)');

/// [raw], a name a server chose, as one path segment that stays where it is put on any OS: a
/// separator, `:`, a control or bidi character becomes `_`, a Windows device name gains a `_`,
/// trailing dots and spaces go, and it is cut to 255 UTF-8 bytes keeping its extension. `..` is
/// `''`.
String _safeName(String raw) {
  final out = StringBuffer();
  for (final c in raw.runes) {
    final unsafe =
        c < 0x20 ||
        (c >= 0x7f && c < 0xa0) ||
        (c >= 0x200e && c <= 0x200f) ||
        (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2066 && c <= 0x2069) ||
        _unsafeChars.contains(c);
    unsafe ? out.write('_') : out.writeCharCode(c);
  }
  // Windows drops trailing dots and spaces, so `a.` would be `a`, and `..` is the parent.
  var name = out.toString().trim().replaceFirst(_trailingDots, '');
  if (name.isEmpty) return '';
  if (_deviceName.hasMatch(name)) name = '_$name';
  if (utf8.encode(name).length <= 255) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
  final stem = (ext.isEmpty ? name : name.substring(0, dot)).runes.toList();
  final room = 255 - utf8.encode(ext).length;
  var bytes = 0;
  var keep = 0;
  while (keep < stem.length) {
    final size = utf8.encode(String.fromCharCode(stem[keep])).length;
    if (bytes + size > room) break;
    bytes += size;
    keep++;
  }
  return '${String.fromCharCodes(stem.take(keep))}$ext';
}

/// `/ \ : * ? " < > |`: a separator, a drive or NTFS stream, or a character Windows refuses.
final _unsafeChars = {for (final c in r'/\:*?"<>|'.codeUnits) c};
final _trailingDots = RegExp(r'[. ]+$');
final _deviceName = RegExp(r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\.|$)', caseSensitive: false);

/// Not API: what `http`, `scrape` and `chrome` need from the message types.
abstract final class MessageInternals {
  static StreamedResponse carrying(StreamedResponse res, Stream<List<int>> body) => res._carrying(body);
  static Future<Uint8List> collect(
    Stream<List<int>> stream,
    int? expected, {
    int? cap,
    bool cut = false,
    Object Function()? over,
    void Function(int received)? onChunk,
  }) => _collect(stream, expected, cap: cap, cut: cut, over: over, onChunk: onChunk);

  /// [to] carrying [from]'s redirect options, directives and, when [body], its body.
  static Request options(Request from, Request to, {bool body = false}) {
    from._options(to);
    if (body) to._content = from._content;
    return to;
  }

  static HttpCookie? setCookie(String line, Uri from) => _setCookie(line, from, strict: true);
  static set charsets(String? Function(String label, Uint8List bytes) decode) => _charsets = decode;
  static DateTime? httpDate(String text) => _httpDate(text);
  static String safeName(String raw) => _safeName(raw);

  /// The file name the server gives an answer with [headers] from [url]; see [Response.name].
  static String serverName(Headers headers, Uri? url) => _serverName(headers, url);

  /// What makes [request]'s body itself, for a crawl's visited check: its bytes, or for a file
  /// or a multipart form its fields and each file's path and size.
  static List<int> identity(Request request) => switch (request._content) {
    _Held(:final bytes) => bytes,
    final _FileBody body => utf8.encode('@${File(body.path).absolute.path}#${body.length}'),
    final _Multipart body => utf8.encode(
      [
        for (final MapEntry(:key, :value) in body.fields.entries) '$key=$value',
        for (final MapEntry(:key, :value) in body.files.entries)
          '$key@${File(value).absolute.path}#${File(value).lengthSync()}',
      ].join('\n'),
    ),
  };

  /// [request]'s body as JSON-ready values, for a crawl's store; [thaw] reads it back.
  static Map<String, Object?> freeze(Request request) => switch (request._content) {
    _Held(:final bytes) when bytes.isEmpty => const {},
    _Held(:final bytes) => {'bytes': base64.encode(bytes)},
    final _FileBody body => {'file': body.path},
    final _Multipart body => {'form': body.fields, 'files': body.files},
  };

  /// The request [freeze] froze.
  static Request thaw(String method, Uri url, Map<String, String>? headers, Map<String, Object?> body) {
    final files = (body['files'] as Map?)?.cast<String, String>();
    return Request(
      method,
      url,
      headers: headers,
      bytes: body['bytes'] == null ? null : base64.decode(body['bytes']! as String),
      form: files == null ? null : (body['form'] as Map?)?.cast<String, Object?>() ?? const {},
      files: files,
      file: body['file'] as String?,
    );
  }
}
