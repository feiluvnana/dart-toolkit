/// # HTTP Networking (`net.*`)
///
/// A retrying HTTP client over `package:http` whose responses provide DOM
/// querying via [HttpResponse.$] and [HttpResponse.$xpath].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:io' as dart_io;
import 'dart:math';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import '../concurrent/concurrent.dart';
import '../src/fs.dart';
import 'selector.dart';

// ============================================================================
// HTTP NETWORKING (HttpClient / HttpResponse)
// ============================================================================

/// HTTP verbs supported by [HttpClient.send].
enum HttpMethod {
  /// Retrieve a resource.
  get,

  /// Submit a body to a resource.
  post,

  /// Replace a resource.
  put,

  /// Remove a resource.
  delete,

  /// Partially update a resource.
  patch,

  /// Retrieve only the headers of a resource.
  head;

  /// The uppercase wire representation, e.g. `'GET'`.
  String get wire => name.toUpperCase();
}

/// A request body, resolved onto an outgoing [http.Request].
///
/// Sealed so every supported body shape is explicit at the call site rather
/// than inferred from a runtime type test.
sealed class Body {
  const Body();

  /// A `text/plain` style body carrying [text] verbatim.
  const factory Body.text(String text) = TextBody;

  /// A raw byte body.
  const factory Body.bytes(List<int> data) = BytesBody;

  /// A form-encoded body built from [fields].
  const factory Body.form(Map<String, String> fields) = FormBody;

  /// A JSON body; [data] accepts any value `jsonEncode` understands.
  const factory Body.json(Object? data) = JsonBody;

  /// Applies this body to [request].
  void apply(http.Request request);

  /// Returns the body as bytes.
  List<int> bytes();
}

/// A body carrying text verbatim.
final class TextBody extends Body {
  /// The body text.
  final String text;

  /// Creates a text body.
  const TextBody(this.text);

  @override
  void apply(http.Request request) => request.body = text;

  @override
  List<int> bytes() => utf8.encode(text);
}

/// A body carrying raw bytes.
final class BytesBody extends Body {
  /// The body bytes.
  final List<int> data;

  /// Creates a byte body.
  const BytesBody(this.data);

  @override
  void apply(http.Request request) => request.bodyBytes = data;

  @override
  List<int> bytes() => data;
}

/// A form-encoded body.
final class FormBody extends Body {
  /// The form fields.
  final Map<String, String> fields;

  /// Creates a form body.
  const FormBody(this.fields);

  @override
  void apply(http.Request request) => request.bodyFields = fields;

  @override
  List<int> bytes() => utf8.encode(
    fields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&'),
  );
}

/// A JSON body, sent with a `application/json` content type.
final class JsonBody extends Body {
  /// The value to encode.
  final Object? data;

  /// Creates a JSON body.
  const JsonBody(this.data);

  @override
  void apply(http.Request request) {
    request.headers.putIfAbsent('content-type', () => 'application/json');
    request.body = jsonEncode(data);
  }

  @override
  List<int> bytes() => utf8.encode(jsonEncode(data));
}

/// An HTTP response, with helpers for scraping its body.
class HttpResponse {
  static final _charsetParam = RegExp(r'charset=([^;]+)', caseSensitive: false);
  static final _charsetMeta = RegExp(
    r'''<meta[^>]+(?:charset=["']?([a-zA-Z0-9_\-]+)|content=["'][^"']*charset=([a-zA-Z0-9_\-]+))''',
    caseSensitive: false,
  );

  /// The final URL after any redirects.
  final Uri url;

  /// The URL originally asked for, before any redirects.
  final Uri requested;

  /// The HTTP status code.
  final int status;

  /// Response headers, lower-cased by `package:http`.
  final Map<String, String> headers;

  /// The raw response body.
  final List<int> bytes;

  final Encoding? _encodingOverride;

  String? _body;
  Document? _doc;
  Object? _json;
  bool _decoded = false;

  /// Creates a response. Normally produced by [HttpClient.send].
  HttpResponse({
    required this.url,
    Uri? requested,
    required this.status,
    required this.headers,
    required this.bytes,
    Encoding? encoding,
  }) : requested = requested ?? url,
       _encodingOverride = encoding;

  /// Creates an [HttpResponse] from a [text] string.
  factory HttpResponse.text(
    String text, {
    Uri? url,
    int status = 200,
    Map<String, String>? headers,
    Uri? requested,
  }) => HttpResponse(
    url: url ?? Uri.parse('http://localhost'),
    requested: requested,
    status: status,
    headers: headers ?? const {'content-type': 'text/html; charset=utf-8'},
    bytes: utf8.encode(text),
  );

  /// Whether [status] is in the 2xx range.
  bool get ok => status >= 200 && status < 300;

  /// The MIME type from the `Content-Type` header (e.g. `'text/html'`).
  String? get type {
    final header = _header('content-type');
    if (header == null) return null;
    return header.split(';').first.trim().toLowerCase();
  }

  /// The character set parsed from `Content-Type` or sniffed from HTML meta tags.
  String? get charset {
    final header = _header('content-type');
    if (header != null) {
      final match = _charsetParam.firstMatch(header);
      if (match != null) {
        return match.group(1)!.trim().replaceAll('"', '').replaceAll("'", '');
      }
    }
    // Fall back to sniffing the first 1024 bytes
    final sniffLimit = bytes.length < 1024 ? bytes.length : 1024;
    final snippet = ascii.decode(
      bytes.sublist(0, sniffLimit),
      allowInvalid: true,
    );
    final metaMatch = _charsetMeta.firstMatch(snippet);
    if (metaMatch != null) {
      return (metaMatch.group(1) ?? metaMatch.group(2))?.trim();
    }
    return null;
  }

  /// The encoding used to decode [body].
  Encoding get encoding {
    if (_encodingOverride != null) return _encodingOverride;
    final cs = charset;
    if (cs != null) {
      final enc = Encoding.getByName(cs);
      if (enc != null) return enc;
    }
    return utf8;
  }

  /// The body decoded using [encoding], tolerating malformed bytes when UTF-8. Cached.
  String get body {
    if (_body != null) return _body!;
    final enc = encoding;
    if (enc == utf8) {
      _body = utf8.decode(bytes, allowMalformed: true);
    } else {
      try {
        _body = enc.decode(bytes);
      } catch (_) {
        _body = utf8.decode(bytes, allowMalformed: true);
      }
    }
    return _body!;
  }

  /// The body decoded as JSON. Cached, so repeat reads are free.
  Object? get json {
    if (!_decoded) {
      _json = jsonDecode(body);
      _decoded = true;
    }
    return _json;
  }

  /// The body decoded as JSON, or [fallback] when it is not valid JSON.
  ///
  /// Where [json] throws on a bad body, this hands back [fallback] instead.
  Object? decode([Object? fallback]) {
    try {
      return json;
    } catch (_) {
      return fallback;
    }
  }

  String? _header(String name) {
    final lower = name.toLowerCase();
    final direct = headers[lower];
    if (direct != null) return direct;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// The body parsed as HTML. Cached.
  Document get doc => _doc ??= html_parser.parse(body);

  /// jQuery-style selector accessor for the parsed HTML body.
  QueryResult get $ => doc.$;

  /// XPath selector accessor for the parsed HTML body.
  QueryResult get $xpath => doc.$xpath;

  /// Writes the response body to [path] atomically.
  Future<File> save(String path, {String part = '.part'}) =>
      Fs.save(path, bytes, part: part);

  /// Extracts data declaratively according to [schema].
  ///
  /// Values are either the string shorthand — `'h1'` for text, `'a@href'` for
  /// an attribute, `['li']` for every match, `['.row', {...}]` for a repeated
  /// sub-object — or a [Field], which says the same thing with a static type.
  ///
  /// ```dart
  /// final data = res.extract({
  ///   'title': 'h1',
  ///   'price': '.price',
  ///   'link': 'a@href',
  ///   'tags': ['ul.tags > li'],
  ///   'items': ['.product', {
  ///     'name': '.name',
  ///     'url': 'a@href',
  ///   }],
  /// });
  /// ```
  Map<String, Object?> extract(Map<String, Object?> schema) =>
      _extractFrom(doc.documentElement ?? doc.body, schema);

  /// Reads a single typed [field] from the document.
  ///
  /// Where [extract] hands back `Object?` values, this keeps the field's type:
  ///
  /// ```dart
  /// final String? title = res.pick(Field.text('h1'));
  /// final List<String> tags = res.pick(Field.texts('.tag'));
  /// ```
  T pick<T>(Field<T> field) =>
      field.read(doc.documentElement ?? doc.body ?? Element.tag('html'));

  /// Reads [schema] out of [root]. Shared with the [Field] cases.
  static Map<String, Object?> _extractFrom(
    Element? root,
    Map<String, Object?> schema,
  ) {
    final result = <String, Object?>{};
    if (root == null) return result;
    for (final entry in schema.entries) {
      result[entry.key] = Field.of(entry.value).read(root);
    }
    return result;
  }

  @override
  String toString() => '$status $url (${bytes.length} bytes)';
}

/// One typed value to read out of a parsed page.
///
/// [HttpResponse.extract] accepts these alongside the string shorthand, and
/// [HttpResponse.pick] reads one without losing its type. Sealed, so every
/// extraction shape is a case the compiler knows about rather than a runtime
/// type test on `dynamic`.
///
/// ```dart
/// final title = res.pick(Field.text('h1'));            // String?
/// final links = res.pick(Field.attrs('a', 'href'));    // List<String>
/// ```
sealed class Field<T> {
  const Field();

  /// The trimmed text of the first match of [selector], or `null`.
  static TextField text(String selector) => TextField(selector);

  /// Attribute [attribute] on the first match of [selector], or `null`.
  ///
  /// An empty [selector] reads the attribute off the root element itself.
  static AttrField attr(String selector, String attribute) =>
      AttrField(selector, attribute);

  /// The trimmed text of every match of [selector].
  static TextsField texts(String selector) => TextsField(selector);

  /// Attribute [attribute] across every match of [selector] that carries it.
  static AttrsField attrs(String selector, String attribute) =>
      AttrsField(selector, attribute);

  /// A nested object read from the same root.
  static MapField map(Map<String, Object?> schema) => MapField(schema);

  /// One object per match of [selector], each read with [schema].
  static ListField list(String selector, Map<String, Object?> schema) =>
      ListField(selector, schema);

  /// An arbitrary read, for anything the other cases do not cover.
  static CallField<R> fn<R>(R Function(Element element) read) =>
      CallField<R>(read);

  /// Reads this field out of [root].
  T read(Element root);

  /// The [Field] a schema entry describes, expanding the string shorthand.
  ///
  /// `'h1'`, `'a@href'`, `['li']`, `['li@href']`, `['.row', {...}]` and a
  /// nested schema map all have a [Field] equivalent; anything else reads as
  /// `null`.
  static Field<Object?> of(Object? spec) {
    switch (spec) {
      case Field<Object?> field:
        return field;
      case String css:
        final at = css.indexOf('@');
        if (at == -1) return TextField(css);
        return AttrField(
          css.substring(0, at).trim(),
          css.substring(at + 1).trim(),
        );
      case Map<String, Object?> schema:
        return MapField(schema);
      case List<Object?> spec when spec.length == 1:
        final first = spec.first;
        if (first is! String) return const _NullField();
        final at = first.indexOf('@');
        if (at == -1) return TextsField(first);
        return AttrsField(
          first.substring(0, at).trim(),
          first.substring(at + 1).trim(),
        );
      case List<Object?> spec
          when spec.length == 2 &&
              spec[0] is String &&
              spec[1] is Map<String, Object?>:
        return ListField(spec[0]! as String, spec[1]! as Map<String, Object?>);
      default:
        return const _NullField();
    }
  }
}

/// The trimmed text of the first match. See [Field.text].
final class TextField extends Field<String?> {
  /// The CSS selector to read.
  final String selector;

  /// Creates a text field.
  const TextField(this.selector);

  @override
  String? read(Element root) =>
      (selector.isEmpty ? root : root.querySelector(selector))?.text.trim();
}

/// An attribute of the first match. See [Field.attr].
final class AttrField extends Field<String?> {
  /// The CSS selector to read; empty means the root element itself.
  final String selector;

  /// The attribute name, or `text` for the element's text.
  final String attribute;

  /// Creates an attribute field.
  const AttrField(this.selector, this.attribute);

  @override
  String? read(Element root) {
    final target = selector.isEmpty ? root : root.querySelector(selector);
    if (target == null) return null;
    return attribute == 'text'
        ? target.text.trim()
        : target.attributes[attribute];
  }
}

/// The trimmed text of every match. See [Field.texts].
final class TextsField extends Field<List<String>> {
  /// The CSS selector to read.
  final String selector;

  /// Creates a repeated text field.
  const TextsField(this.selector);

  @override
  List<String> read(Element root) => [
    for (final el in root.querySelectorAll(selector)) el.text.trim(),
  ];
}

/// An attribute across every match. See [Field.attrs].
final class AttrsField extends Field<List<String>> {
  /// The CSS selector to read; empty means the root element itself.
  final String selector;

  /// The attribute name, or `text` for each element's text.
  final String attribute;

  /// Creates a repeated attribute field.
  const AttrsField(this.selector, this.attribute);

  @override
  List<String> read(Element root) {
    final elements =
        selector.isEmpty ? [root] : root.querySelectorAll(selector);
    if (attribute == 'text') {
      return [for (final el in elements) el.text.trim()];
    }
    return [
      for (final el in elements)
        if (el.attributes[attribute] case final value?) value,
    ];
  }
}

/// A nested object read from the same root. See [Field.map].
final class MapField extends Field<Map<String, Object?>> {
  /// The schema of the nested object.
  final Map<String, Object?> schema;

  /// Creates a nested object field.
  const MapField(this.schema);

  @override
  Map<String, Object?> read(Element root) =>
      HttpResponse._extractFrom(root, schema);
}

/// One object per match. See [Field.list].
final class ListField extends Field<List<Map<String, Object?>>> {
  /// The CSS selector matching each container element.
  final String selector;

  /// The schema applied to every container.
  final Map<String, Object?> schema;

  /// Creates a repeated object field.
  const ListField(this.selector, this.schema);

  @override
  List<Map<String, Object?>> read(Element root) => [
    for (final el in root.querySelectorAll(selector))
      HttpResponse._extractFrom(el, schema),
  ];
}

/// An arbitrary typed read. See [Field.call].
final class CallField<T> extends Field<T> {
  final T Function(Element element) _read;

  /// Creates a field backed by [read].
  const CallField(this._read);

  @override
  T read(Element root) => _read(root);
}

final class _NullField extends Field<Object?> {
  const _NullField();

  @override
  Object? read(Element root) => null;
}

/// Resolves destination paths against an optional base directory.
///
/// Shared by [HttpClient] and every [Downloader], which both accept a `base`
/// folder that relative destinations hang off.
mixin PathResolver {
  /// The base directory prepended to relative destinations, if any.
  String? get base;

  /// Resolves [path] against [base], leaving absolute paths untouched.
  String resolve(String path) {
    final root = base;
    if (root == null || p.isAbsolute(path) || p.isWithin(root, path)) {
      return path;
    }
    return p.join(root, path);
  }
}

/// A retrying HTTP client whose responses can query their own HTML.
///
/// Reachable as `net.http`, a shared instance. Construct one directly when you
/// need your own headers, timeout or base directory — and close it when done.
///
/// ```dart
/// final client = HttpClient(headers: {'Cookie': session});
/// final res = await client.get('https://example.com/page'.url);
/// await client.close();
/// ```
class HttpClient with PathResolver {
  final http.Client _client;
  final bool _ownsClient;

  /// Headers sent with every request, overridable per call.
  final Map<String, String> headers;

  /// Per-request timeout.
  final Duration timeout;

  /// Number of retries after the initial attempt.
  final int retries;

  /// Base delay for retry backoff, multiplied by the attempt number.
  final Duration backoff;

  /// Base directory that relative download destinations resolve against.
  @override
  final String? base;

  /// Default encoding for decoding response bodies.
  final Encoding? encoding;

  /// Whether to retry the unsafe methods too — POST, PUT and PATCH.
  ///
  /// Off by default: replaying one of these can duplicate a side effect the
  /// server already applied.
  final bool unsafe;

  /// Cookie storage, shared across every request this client sends.
  final CookieJar? jar;

  /// Proxy server string (e.g. '127.0.0.1:8888').
  final String? proxy;

  /// Largest response body accepted, in bytes, or `null` for no limit.
  ///
  /// A crawl that meets an unexpectedly large URL would otherwise hold the
  /// whole body in memory; past the cap the transfer is abandoned and
  /// [HttpException] is thrown instead.
  final int? cap;

  /// Number of files successfully downloaded through this client.
  int count = 0;

  /// Creates a client.
  ///
  /// Pass [pool] to share an existing `package:http` connection pool; the
  /// caller keeps ownership and [close] leaves it open. Without [headers] a desktop browser
  /// User-Agent and HTML `Accept` header are sent, which is what most scraping
  /// targets expect.
  HttpClient({
    http.Client? pool,
    Map<String, String>? headers,
    this.timeout = const Duration(seconds: 30),
    this.retries = 2,
    this.backoff = const Duration(milliseconds: 500),
    this.base,
    this.encoding,
    this.unsafe = false,
    bool session = false,
    CookieJar? jar,
    this.proxy,
    this.cap,
  }) : jar = jar ?? (session ? CookieJar() : null),
       _ownsClient = pool == null,
       _client = pool ?? _createClient(proxy),
       headers =
           headers ??
           const {
             'User-Agent':
                 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                 '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
             'Accept':
                 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
           };

  static http.Client _createClient(String? proxy) {
    if (proxy == null) return http.Client();
    final inner = dart_io.HttpClient();
    final cleanProxy =
        proxy.toUpperCase().startsWith('PROXY ') ? proxy : 'PROXY $proxy';
    inner.findProxy = (uri) => cleanProxy;
    return IOClient(inner);
  }

  /// Sends [method] to [url] and returns the response.
  ///
  /// Retries up to [retries] times on a transport error, a 5xx, or a 429. A
  /// `Retry-After` header is honoured when present, otherwise the delay is
  /// [backoff] multiplied by the attempt number with jitter.
  Future<HttpResponse> send(
    HttpMethod method,
    Uri url, {
    Map<String, String>? headers,
    Body? body,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
    int? retries,
  }) async {
    final merged = {...this.headers, ...?headers};
    final deadline = timeout ?? this.timeout;
    final effRetries = retries ?? this.retries;
    final allowRetry =
        retry ??
        (unsafe || method == HttpMethod.get || method == HttpMethod.head);
    final maxAttempts = (allowRetry && effRetries > 0) ? effRetries + 1 : 1;
    var currentUrl = url;
    var currentMethod = method;
    var currentBody = body;
    var redirectCount = 0;

    while (true) {
      for (var attempt = 1; ; attempt++) {
        final currentMerged = Map<String, String>.from(merged);
        if (jar != null) {
          final cookieHeader = jar!.header(currentUrl);
          if (cookieHeader != null) {
            currentMerged['Cookie'] =
                currentMerged.containsKey('Cookie')
                    ? '${currentMerged['Cookie']}; $cookieHeader'
                    : cookieHeader;
          }
        }
        final request = http.Request(currentMethod.wire, currentUrl)
          ..headers.addAll(currentMerged);
        request.followRedirects = false;
        request.maxRedirects = redirects;
        currentBody?.apply(request);
        try {
          final streamed = await _client.send(request).timeout(deadline);
          final response = await _collect(streamed, currentUrl);
          if (jar != null && response.headers.containsKey('set-cookie')) {
            jar!.add(response.headers['set-cookie']!, uri: currentUrl);
          }
          if (allowRetry &&
              _retryable(response.statusCode) &&
              attempt < maxAttempts) {
            await Future<void>.delayed(
              _retryAfter(response.headers) ??
                  _backoffWithJitter(backoff * attempt),
            );
            continue;
          }

          if (redirect &&
              _isRedirect(response.statusCode) &&
              response.headers.containsKey('location')) {
            if (redirectCount >= redirects) {
              throw HttpException(
                'Redirect limit of $redirects exceeded',
                uri: currentUrl,
              );
            }
            redirectCount++;
            final location = response.headers['location']!;
            final nextUrl = currentUrl.resolve(location);
            if (response.statusCode == 303 ||
                ((response.statusCode == 301 || response.statusCode == 302) &&
                    currentMethod != HttpMethod.get &&
                    currentMethod != HttpMethod.head)) {
              currentMethod = HttpMethod.get;
              currentBody = null;
            }
            currentUrl = nextUrl;
            break;
          }

          return HttpResponse(
            url: currentUrl,
            requested: url,
            status: response.statusCode,
            headers: response.headers,
            bytes: response.bodyBytes,
            encoding: encoding ?? this.encoding,
          );
        } catch (_) {
          if (!allowRetry || attempt >= maxAttempts) rethrow;
          await Future<void>.delayed(_backoffWithJitter(backoff * attempt));
        }
      }
    }
  }

  /// Reads [streamed] into a response, refusing bodies larger than [cap].
  Future<http.Response> _collect(
    http.StreamedResponse streamed,
    Uri url,
  ) async {
    final limit = cap;
    if (limit == null) return http.Response.fromStream(streamed);

    final declared = streamed.contentLength;
    if (declared != null && declared > limit) {
      await streamed.stream.drain<void>();
      throw HttpException(
        'Response of $declared bytes exceeds the cap of $limit',
        uri: url,
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw HttpException('Response exceeds the cap of $limit', uri: url);
      }
    }
    return http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static final Random _rng = Random();

  static Duration _backoffWithJitter(Duration base) {
    final jitterMs = (base.inMilliseconds * 0.25 * _rng.nextDouble()).toInt();
    return base + Duration(milliseconds: jitterMs);
  }

  static bool _retryable(int status) => status >= 500 || status == 429;

  /// Parses a `Retry-After` header, in either delta-seconds or HTTP-date form.
  static Duration? _retryAfter(Map<String, String> headers) {
    final value = headers['retry-after'];
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds);
    try {
      final when = HttpDate.parse(value).difference(DateTime.now());
      return when > Duration.zero ? when : Duration.zero;
    } catch (_) {
      // A server that sends an unparseable Retry-After should not crash the
      // retry it asked for; fall back to the client's own backoff.
      return null;
    }
  }

  /// Sends a `GET` to [url].
  Future<HttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
  }) => send(
    HttpMethod.get,
    url,
    headers: headers,
    timeout: timeout,
    redirect: redirect,
    redirects: redirects,
    retry: retry,
    encoding: encoding,
  );

  /// Sends a `POST` to [url].
  Future<HttpResponse> post(
    Uri url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
  }) => send(
    HttpMethod.post,
    url,
    body: body,
    headers: headers,
    timeout: timeout,
    redirect: redirect,
    redirects: redirects,
    retry: retry,
    encoding: encoding,
  );

  /// Sends a `PUT` to [url].
  Future<HttpResponse> put(
    Uri url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
  }) => send(
    HttpMethod.put,
    url,
    body: body,
    headers: headers,
    timeout: timeout,
    redirect: redirect,
    redirects: redirects,
    retry: retry,
    encoding: encoding,
  );

  /// Sends a `DELETE` to [url].
  Future<HttpResponse> delete(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
  }) => send(
    HttpMethod.delete,
    url,
    headers: headers,
    timeout: timeout,
    redirect: redirect,
    redirects: redirects,
    retry: retry,
    encoding: encoding,
  );

  /// Sends a `PATCH` to [url].
  Future<HttpResponse> patch(
    Uri url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
  }) => send(
    HttpMethod.patch,
    url,
    body: body,
    headers: headers,
    timeout: timeout,
    redirect: redirect,
    redirects: redirects,
    retry: retry,
    encoding: encoding,
  );

  /// Sends a `HEAD` to [url].
  Future<HttpResponse> head(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
    bool redirect = true,
    int redirects = 5,
    bool? retry,
    Encoding? encoding,
  }) => send(
    HttpMethod.head,
    url,
    headers: headers,
    timeout: timeout,
    redirect: redirect,
    redirects: redirects,
    retry: retry,
    encoding: encoding,
  );

  /// Streams [url] to [path], resolved against [base].
  ///
  /// Skips the download when the destination already holds bytes. Set [match]
  /// to also skip on a loosely-named sibling — see [Fs.similar] for why that
  /// is off by default. Retries on failure like [send] does.
  Future<File> download(
    Uri url,
    String path, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = false,
  }) async {
    final dest = resolve(path);
    if (Fs.has(dest, match: match)) return File(dest);

    final merged = {...this.headers, ...?headers};
    final maxAttempts = retries > 0 ? retries + 1 : 1;
    for (var attempt = 1; ; attempt++) {
      try {
        final file = await Fs.download(
          url,
          dest,
          pool: _client,
          headers: merged,
          onProgress: onProgress,
          part: part,
        );
        count++;
        return file;
      } catch (_) {
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(backoff * attempt);
      }
    }
  }

  /// Whether [path], resolved against [base], already holds bytes.
  bool has(String path, {bool match = false}) =>
      Fs.has(resolve(path), match: match);

  /// Downloads every entry of [tasks], mapping destination path to source URL.
  ///
  /// Runs [size] downloads concurrently. Any failure propagates once the
  /// in-flight downloads settle — see [Pool.run].
  Future<void> sync(
    Map<String, Uri> tasks, {
    int size = 4,
    bool match = false,
  }) async {
    await Pool<MapEntry<String, Uri>>(size: size).run(
      tasks.entries,
      (task) => download(task.value, task.key, match: match),
    );
  }

  /// Closes the underlying connection pool, if this client owns it.
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}

// ============================================================================
// COOKIE & COOKIE JAR
// ============================================================================

/// Represents an HTTP cookie.
class Cookie {
  /// Name of the cookie.
  final String name;

  /// Value of the cookie.
  final String value;

  /// Domain the cookie belongs to.
  final String? domain;

  /// Path prefix the cookie belongs to.
  final String? path;

  /// Expiry timestamp, or `null` for session cookies.
  final DateTime? expires;

  /// Whether transmission is restricted to HTTPS.
  final bool secure;

  /// Whether access is restricted to HTTP (no scripts).
  final bool httponly;

  /// Creates a cookie.
  Cookie(
    this.name,
    this.value, {
    this.domain,
    this.path,
    this.expires,
    this.secure = false,
    this.httponly = false,
  });

  /// Splits a `Set-Cookie` header value into one entry per cookie.
  ///
  /// `package:http` folds repeated `Set-Cookie` headers into a single
  /// comma-joined string, and an `Expires` date contains a comma of its own, so
  /// a comma only starts a new cookie when an `=` follows it before the next
  /// attribute separator.
  static List<String> split(String setCookieHeader) {
    final parts = <String>[];
    var start = 0;
    for (var i = 0; i < setCookieHeader.length; i++) {
      if (setCookieHeader[i] != ',') continue;
      var j = i + 1;
      while (j < setCookieHeader.length && setCookieHeader[j] == ' ') {
        j++;
      }
      var sawName = false;
      while (j < setCookieHeader.length) {
        final ch = setCookieHeader[j];
        if (ch == '=') {
          sawName = true;
          break;
        }
        if (ch == ';' || ch == ',') break;
        j++;
      }
      if (!sawName) continue;
      final piece = setCookieHeader.substring(start, i).trim();
      if (piece.isNotEmpty) parts.add(piece);
      start = i + 1;
    }
    final last = setCookieHeader.substring(start).trim();
    if (last.isNotEmpty) parts.add(last);
    return parts;
  }

  /// Parses every cookie in a possibly comma-joined `Set-Cookie` header.
  static List<Cookie> _parseAll(String setCookieHeader, {Uri? uri}) => [
    for (final piece in split(setCookieHeader)) Cookie.parse(piece, uri: uri),
  ];

  /// The RFC 6265 default-path for a cookie set from [uri]: the
  /// directory of the request path, so a cookie set at `/login` is still sent
  /// to `/dashboard`.
  static String _defaultPath(Uri? uri) {
    final path = uri?.path ?? '';
    if (path.isEmpty || !path.startsWith('/')) return '/';
    final lastSlash = path.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : path.substring(0, lastSlash);
  }

  /// Parses a single `Set-Cookie` header value.
  ///
  /// For a header that may carry several cookies use [parseAll].
  factory Cookie.parse(String setCookieHeader, {Uri? uri}) {
    final parts = setCookieHeader.split(';');
    final nameValue = parts.first.split('=');
    final name = nameValue.first.trim();
    final value =
        nameValue.length > 1 ? nameValue.sublist(1).join('=').trim() : '';
    String? domain;
    String? path;
    DateTime? expires;
    int? maxAge;
    var secure = false;
    var httponly = false;

    for (final part in parts.skip(1)) {
      final kv = part.split('=');
      final k = kv.first.trim().toLowerCase();
      final v = kv.length > 1 ? kv.sublist(1).join('=').trim() : '';
      switch (k) {
        case 'domain':
          domain = v.startsWith('.') ? v.substring(1) : v;
        case 'path':
          path = v;
        case 'expires':
          try {
            expires = HttpDate.parse(v);
          } catch (_) {}
        case 'max-age':
          maxAge = int.tryParse(v);
        case 'secure':
          secure = true;
        case 'httponly':
          httponly = true;
      }
    }

    return Cookie(
      name,
      value,
      domain: domain ?? uri?.host,
      // Max-Age wins over Expires per RFC 6265 section 5.3.
      path: (path != null && path.startsWith('/')) ? path : _defaultPath(uri),
      expires:
          maxAge != null
              ? DateTime.now().add(Duration(seconds: maxAge))
              : expires,
      secure: secure,
      httponly: httponly,
    );
  }

  /// Whether this cookie should be sent with a request to [url].
  bool matches(Uri url) {
    if (expires != null && DateTime.now().isAfter(expires!)) return false;
    if (secure && url.scheme != 'https') return false;
    if (domain != null && domain!.isNotEmpty) {
      final host = url.host.toLowerCase();
      final dom = domain!.toLowerCase();
      if (host != dom && !host.endsWith('.$dom')) return false;
    }
    return _pathMatches(url.path.isEmpty ? '/' : url.path);
  }

  /// RFC 6265 section 5.1.4 path-match.
  bool _pathMatches(String requestPath) {
    final cookiePath = (path == null || path!.isEmpty) ? '/' : path!;
    if (requestPath == cookiePath) return true;
    if (!requestPath.startsWith(cookiePath)) return false;
    return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
  }

  @override
  String toString() => '$name=$value';
}

/// In-memory storage for cookies with domain and path matching.
class CookieJar {
  final Map<String, Cookie> _cookies = {};

  /// Stores a single [cookie], replacing any with the same name, domain and path.
  void set(Cookie cookie) {
    _cookies['${cookie.domain ?? ""}:${cookie.path ?? ""}:${cookie.name}'] =
        cookie;
  }

  /// Parses and stores every cookie in a `Set-Cookie` header.
  ///
  /// Handles the comma-joined form `package:http` produces for a response that
  /// sent several `Set-Cookie` headers. A cookie with an empty value or a past
  /// expiry deletes the entry it names, as a server clearing a session does.
  void add(String headerValue, {Uri? uri}) {
    for (final cookie in Cookie._parseAll(headerValue, uri: uri)) {
      if (cookie.name.isEmpty) continue;
      final expires = cookie.expires;
      if (expires != null && DateTime.now().isAfter(expires)) {
        _cookies.remove(
          '${cookie.domain ?? ""}:${cookie.path ?? ""}:${cookie.name}',
        );
        continue;
      }
      set(cookie);
    }
  }

  /// Builds a `Cookie` header string for [url], or `null` if none match.
  ///
  /// Longer paths sort first, as RFC 6265 section 5.4 requires.
  String? header(Uri url) {
    final matching = _cookies.values.where((c) => c.matches(url)).toList();
    if (matching.isEmpty) return null;
    matching.sort(
      (a, b) => (b.path?.length ?? 0).compareTo(a.path?.length ?? 0),
    );
    return matching.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// All stored cookies.
  List<Cookie> get cookies => _cookies.values.toList();

  /// The value of the stored cookie named [name], or `null`.
  String? operator [](String name) {
    for (final cookie in _cookies.values) {
      if (cookie.name == name) return cookie.value;
    }
    return null;
  }

  /// Removes all stored cookies.
  void clear() => _cookies.clear();

  /// Removes every cookie whose expiry has passed.
  void sweep() {
    final now = DateTime.now();
    _cookies.removeWhere(
      (_, c) => c.expires != null && now.isAfter(c.expires!),
    );
  }

  /// The number of stored cookies.
  int get length => _cookies.length;
}
