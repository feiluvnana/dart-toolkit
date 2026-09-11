/// # HTTP Networking (`net.*`)
///
/// A client over `package:http` that retries, follows and caches only when a
/// parameter said to — see [Fetcher]. A [Reply] carries the bytes,
/// the text and the headers, and nothing about what the bytes *are*: reading
/// them is [Reply.parse] plus a codec from `format`, because a crawler
/// fetches JSON, sitemaps, archives and images as readily as it fetches
/// pages.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:io' as dart_io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import '../concurrent/concurrent.dart';
import '../io/entry.dart';
import '../src/fs.dart';
import '../src/codec.dart';
import '../src/method.dart';
import '../util/rand.dart';
import '../collection/sequence.dart';
import 'cache.dart';
import 'fetch.dart';

// ============================================================================
// HTTP NETWORKING (Fetcher / Reply)
// ============================================================================

/// An HTTP failure that retrying cannot fix.
///
/// Thrown for a body larger than [Fetcher.cap] and for a redirect chain
/// past its limit: both are settled answers from the server, so
/// [Fetcher.send] rethrows them instead of spending its retry budget
/// re-downloading the same refusal.
final class FatalHttpException extends HttpException {
  /// Creates a non-retryable HTTP exception.
  const FatalHttpException(super.message, {super.uri});
}

/// A request body, resolved onto an outgoing [http.Request].
///
/// Sealed so every supported body shape is explicit at the call site rather
/// than inferred from a runtime type test. **The four shapes are private**:
/// `Body.text`, `Body.bytes`, `Body.form` and `Body.json` are the whole
/// surface, and the classes behind them were four more exported names that
/// nothing could usefully do anything with — a `switch` over them was never
/// the point, because the sealing exists so `apply` can be exhaustive
/// *inside* this library.
sealed class Body {
  const Body();

  /// A `text/plain` style body carrying [text] verbatim.
  const factory Body.text(String text) = _TextBody;

  /// A raw byte body.
  const factory Body.bytes(List<int> data) = _BytesBody;

  /// A form-encoded body built from [fields].
  const factory Body.form(Map<String, String> fields) = _FormBody;

  /// A JSON body; [data] accepts any value `jsonEncode` understands.
  const factory Body.json(Object? data) = _JsonBody;

  /// Restores a body from the map [toJson] produced.
  ///
  /// This is what lets a queued request survive being written to disk and read
  /// back — see `Fetch.fromJson`.
  ///
  /// Throws [FormatException] when [json] names no known body shape.
  factory Body.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    return switch (kind) {
      'text' => _TextBody(json['text'] as String? ?? ''),
      'bytes' => _BytesBody(base64Decode(json['data'] as String? ?? '')),
      'form' => _FormBody({
        for (final entry in (json['fields'] as Map? ?? const {}).entries)
          entry.key.toString(): entry.value.toString(),
      }),
      'json' => _JsonBody(json['data']),
      _ => throw FormatException('Unknown body kind: $kind'),
    };
  }

  /// Applies this body to [request].
  void apply(http.Request request);

  /// Returns the body as bytes.
  List<int> bytes();

  /// Serializes this body to a JSON-compatible map. See [Body.fromJson].
  Map<String, Object?> toJson();
}

/// A body carrying text verbatim.
final class _TextBody extends Body {
  /// The body text.
  final String text;

  /// Creates a text body.
  const _TextBody(this.text);

  @override
  void apply(http.Request request) => request.body = text;

  @override
  List<int> bytes() => utf8.encode(text);

  @override
  Map<String, Object?> toJson() => {'kind': 'text', 'text': text};
}

/// A body carrying raw bytes.
final class _BytesBody extends Body {
  /// The body bytes.
  final List<int> data;

  /// Creates a byte body.
  const _BytesBody(this.data);

  @override
  void apply(http.Request request) => request.bodyBytes = data;

  @override
  List<int> bytes() => data;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'bytes',
    // Base64 so an arbitrary byte body survives a JSON round trip.
    'data': base64Encode(data),
  };
}

/// A form-encoded body.
final class _FormBody extends Body {
  /// The form fields.
  final Map<String, String> fields;

  /// Creates a form body.
  const _FormBody(this.fields);

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

  @override
  Map<String, Object?> toJson() => {'kind': 'form', 'fields': fields};
}

/// A JSON body, sent with a `application/json` content type.
final class _JsonBody extends Body {
  /// The value to encode.
  final Object? data;

  /// Creates a JSON body.
  const _JsonBody(this.data);

  @override
  void apply(http.Request request) {
    request.headers.putIfAbsent('content-type', () => 'application/json');
    request.body = jsonEncode(data);
  }

  @override
  List<int> bytes() => utf8.encode(jsonEncode(data));

  @override
  Map<String, Object?> toJson() => {'kind': 'json', 'data': data};
}

/// An HTTP response: what came back, and the request it came back from.
///
/// **`Page<T>` folded into this in 6.0.0.** Everything `Page` added was
/// either the request it came from — [fetch], and [Fetch.tag], [Fetch.meta]
/// and [Fetch.depth] through it — or a call on an engine. The engine calls
/// are gone: `emit` because a crawl is a `Flow<Reply>` and the caller decides
/// what to do with each reply, `stop` because cancelling that flow stops the
/// crawl, and [follow] because it now *returns* the next request instead of
/// queueing one.
///
/// That last change is the whole migration for a handler:
///
/// ```dart no-compile
/// // before — a closure with a side effect, needing an engine behind it
/// res.parse(format.html).$('a').attrs('href')
///    .collect(.foreach((h) => res.follow(h)));
///
/// // after — a pure function from a reply to the next requests
/// res.parse(format.html).$('a').attrs('href').transform(.map(res.follow))
/// ```
class Reply {
  static final _charsetParam = RegExp(r'charset=([^;]+)', caseSensitive: false);
  static final _charsetMeta = RegExp(
    r'''<meta[^>]+(?:charset=["']?([a-zA-Z0-9_\-]+)|content=["'][^"']*charset=([a-zA-Z0-9_\-]+))''',
    caseSensitive: false,
  );

  /// The final URL after any redirects.
  final Uri url;

  /// The request that produced this reply.
  ///
  /// `res.requested` was a second name for `res.fetch.url` through 5.5.0,
  /// and `Page.tag`, `Page.meta` and `Page.depth` were three more for the
  /// fields beside it.
  final Fetch fetch;

  /// The HTTP status code.
  final int status;

  /// Page headers, lower-cased by `package:http`.
  final Map<String, String> headers;

  /// The raw response body.
  final List<int> bytes;

  /// Whether this response came from an [HttpCache] rather than the network.
  ///
  /// True both for a stored response still inside its `max-age` and for one
  /// the server confirmed with a `304`, so a handler that only wants pages
  /// that actually changed can say `if (res.cached) return;`.
  final bool cached;

  final Encoding? _encodingOverride;

  String? _body;

  // Keyed by codec, and every accessor under `format` is a const instance, so
  // reading a page through `format.html` five times parses it once. This is
  // what the old `_doc` and `_json` caches did, for every format instead of
  // two.
  final Map<Codec<Object?>, Object?> _parsed = {};

  /// Creates a response. Normally produced by [Fetcher.send].
  Reply({
    required this.url,
    Fetch? fetch,
    required this.status,
    required this.headers,
    required this.bytes,
    Encoding? encoding,
    this.cached = false,
  }) : fetch = fetch ?? Fetch(url),
       _encodingOverride = encoding;

  /// Creates a [Reply] from a [text] string.
  ///
  /// The fixture a [Send] hands back, and the reason a crawl's `next` is
  /// testable with no network and no engine:
  ///
  /// ```dart
  /// Future<Reply> fixture(Fetch f) async =>
  ///     Reply.text('<h1>hi</h1>', fetch: f);
  /// ```
  ///
  /// With only [fetch] given, its URL is also the [url]: a fixture that says
  /// where it came from should resolve its own links from there rather than
  /// from `localhost`.
  factory Reply.text(
    String text, {
    Uri? url,
    int status = 200,
    Map<String, String>? headers,
    Fetch? fetch,
  }) => Reply(
    url: url ?? fetch?.url ?? Uri.parse('http://localhost'),
    fetch: fetch,
    status: status,
    headers: headers ?? const {'content-type': 'text/html; charset=utf-8'},
    bytes: utf8.encode(text),
  );

  /// Creates a [Reply] carrying raw [data].
  ///
  /// The byte twin of [Reply.text], for a [Send] serving an image, an archive
  /// or anything else a fixture is not text.
  factory Reply.bytes(
    List<int> data, {
    Uri? url,
    int status = 200,
    Map<String, String>? headers,
    Fetch? fetch,
  }) => Reply(
    url: url ?? fetch?.url ?? Uri.parse('http://localhost'),
    fetch: fetch,
    status: status,
    headers: headers ?? const {'content-type': 'application/octet-stream'},
    bytes: data,
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

  /// The body read through [codec].
  ///
  /// The only door from a response to a document, and it names no format:
  /// `net` fetches bytes and is handed something that reads them, which is why
  /// a crawl over an API and a crawl over pages are written the same way.
  ///
  /// ```dart
  /// res.parse(format.html).$('h1').text;
  /// res.parse(format.json).at('data.items');
  /// res.parse(format.yaml).text('version');
  ///
  /// switch (res.type) {
  ///   case 'application/json': res.parse(format.json).at('items');
  ///   default:                 res.parse(format.html).$('.item');
  /// }
  /// ```
  ///
  /// Memoised per codec, so a handler that reads one page five times parses it
  /// once. Nothing here throws: a body that is not the format asked for is the
  /// empty cursor, the same as a missing path.
  T parse<T>(Codec<T> codec) {
    if (_parsed.containsKey(codec)) return _parsed[codec] as T;
    final value = codec.parse(body);
    _parsed[codec] = value;
    return value;
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

  /// The next request, resolved against this reply's URL.
  ///
  /// **Returns a [Fetch]; it does not queue one.** A crawl's `next` is a pure
  /// function from a reply to the requests that follow it, so this composes
  /// with the collection vocabulary and needs no engine behind it:
  ///
  /// ```dart no-compile
  /// res.parse(format.html).$('a').attrs('href').transform(.map(res.follow))
  /// ```
  ///
  /// It tears off cleanly because the href comes first and everything else is
  /// named. A `Referer` naming this page is set for you, [depth] grows by
  /// one, and relative URLs resolve against [url].
  ///
  /// Pass [method] and [body] to follow a form rather than a link — though a
  /// `<form>` on the page is better spelled `form.at(res.url).fetch()`, which
  /// reads the method, the action and the fields off the form itself.
  Fetch follow(
    String url, {
    HttpMethod method = HttpMethod.get,
    Body? body,
    String? tag,
    Iterable<(String, Object?)>? meta,
    Map<String, String>? headers,
    int priority = 0,
    bool dedupe = true,
  }) => Fetch(
    coerce(url, base: this.url),
    method: method,
    body: body,
    headers: {'Referer': this.url.toString(), ...?headers},
    tag: tag,
    meta: meta,
    priority: priority,
    dedupe: dedupe,
    depth: fetch.depth + 1,
  );

  /// Writes the response body to [path] atomically.
  ///
  /// One line over `io.async.bytes.write(path, res.bytes)`, kept because it
  /// is written constantly.
  Future<FileSystemEntry> save(String path, {String part = '.part'}) async =>
      Fs.entryFor((await Fs.save(path, bytes, part: part)).path);

  @override
  String toString() => '$status $url (${bytes.length} bytes)';
}

/// Resolves destination paths against an optional base directory.
///
/// Private since 6.0.0: it was a public mixin so that `Downloader` could
/// share it with [Fetcher], and `Downloader` no longer exists — a transport
/// is a [Send], and a `Send` has nowhere to put a base directory because it
/// does not write files.
mixin _PathResolver {
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

/// An HTTP client that does what it was asked to do.
///
/// Reachable as `net.http`, a shared instance. Construct one directly when you
/// need your own headers, timeout or base directory — and close it when done.
///
/// ```dart
/// final client = Fetcher(headers: {'Cookie': 'session=abc'});
/// final res = await client.send(.get, 'https://example.com/page'.url);
/// await client.close();
/// ```
///
/// It *can* retry, cache, carry cookies, obey a rate limit and pretend to be
/// Chrome, and it does none of them until asked — [retries] is `0`, [cache]
/// and [limiter] and [jar] are `null`, and [headers] is empty. Through 6.0.0
/// the first and the last were on by default, which is how a two-line script
/// against a host dropping TLS handshakes read as *the toolkit is slower than
/// `package:http`*: `package:http` returned the failure, this retried it
/// twice. Opt in, one parameter at a time:
///
/// ```dart
/// final scraper = Fetcher.browser(retries: 3, limiter: concurrent.rate(10, per: 1.s));
/// ```
class Fetcher with _PathResolver {
  final http.Client _client;
  final bool _ownsClient;

  /// Headers sent with every request, overridable per call.
  final Map<String, String> headers;

  /// Per-request timeout.
  final Duration timeout;

  /// Number of retries after the initial attempt, `0` for none.
  ///
  /// **Zero by default**, and every method is treated alike: `retries: 3`
  /// retries a `POST` as readily as a `GET`, because nothing is retried
  /// unless a caller asked for it. An `unsafe` flag gated this through
  /// 6.0.0, when the default was `2` and something had to stop that default
  /// replaying a side effect the server had already applied.
  ///
  /// A retry is the one *bonus* the client used to perform unasked, and it
  /// hid exactly what it was meant to smooth over: a host dropping TLS
  /// handshakes turned into three slow attempts and one late failure, where
  /// `package:http` returned the error at once.
  final int retries;

  /// Base delay for retry backoff, multiplied by the attempt number.
  final Duration backoff;

  /// Redirect hops to follow, `0` for none.
  ///
  /// **Zero by default**, like [retries]: a `3xx` is an answer the server
  /// gave, and handing it back is this client reporting what happened rather
  /// than quietly asking a second question. `res.status` is `302` and
  /// `res.headers['location']` is where it points; `redirects: n` follows up
  /// to `n` hops, and a longer chain throws [FatalHttpException].
  ///
  /// A per-call `redirect: bool` and a `redirects: int = 5` said this in two
  /// types through 6.0.0, and `5` was a number nobody chose.
  final int redirects;

  /// Base directory that relative download destinations resolve against.
  @override
  final String? base;

  /// Default encoding for decoding response bodies.
  final Encoding? encoding;

  /// Cookie storage, shared across every request this client sends.
  final CookieJar? jar;

  /// Proxy server string (e.g. '127.0.0.1:8888').
  final String? proxy;

  /// Responses kept between runs, or `null` to always fetch.
  ///
  /// Only `GET` responses with status 200 are stored, and only when the server
  /// did not say `no-store`. See [HttpCache].
  final HttpCache? cache;

  /// Largest response body accepted, in bytes, or `null` for no limit.
  ///
  /// A crawl that meets an unexpectedly large URL would otherwise hold the
  /// whole body in memory; past the cap the transfer is abandoned and
  /// [HttpException] is thrown instead.
  final int? cap;

  /// How often this client may send, or `null` for as fast as it can.
  ///
  /// The published limit an API enforces — *10 per second*, *5000 per hour* —
  /// which a concurrency bound does not satisfy: four instant requests then
  /// four more is eight in a second. Every attempt takes a token, retries
  /// included, because the server counts those too.
  ///
  /// ```dart
  /// final api = Fetcher(limiter: concurrent.rate(10, per: 1.s));
  /// await concurrent.run(urls, (u) => api.send(.get, u), size: 8);
  /// ```
  ///
  /// Typed [Waiting], so a [Semaphore] paces this client as readily as a
  /// [Limiter] — *at most three of my requests in flight anywhere in this
  /// program* is as reasonable a rule as *ten per second*, and only the
  /// second one compiled through 5.5.0.
  ///
  /// The dependency points this way round on purpose: `concurrent` knows
  /// nothing about responses, so a limiter that read `Retry-After` off one
  /// would tangle the two domains. Retry pacing already honours that header —
  /// see [Fetcher.retries].
  final Waiting? limiter;

  /// Number of files successfully downloaded through this client.
  int count = 0;

  /// Number of requests this client tried again.
  ///
  /// Retrying happens here, below any scheduler, so this is where the number
  /// lives. A crawl reported it as `Stats.retried` through 5.5.0, and only
  /// because the downloader that retried also owned the worker loop; a
  /// [Send] is a function and has nothing to report through.
  int retried = 0;

  /// Creates a client that sends what it was asked to send, and nothing else.
  ///
  /// No headers, no retries, no cache, no cookie jar and no limiter: every
  /// one of those is a parameter, and a parameter no caller filled in stays
  /// switched off. Pass [pool] to share an existing `package:http` connection
  /// pool; the caller keeps ownership and [close] leaves it open.
  ///
  /// A desktop-browser `User-Agent` and an HTML `Accept` header went out with
  /// every request through 6.0.0 — useful against a scraping target, and a
  /// lie told to a JSON API on a caller's behalf. [Fetcher.browser] sends
  /// them now, by name and on request.
  Fetcher({
    http.Client? pool,
    Map<String, String>? headers,
    this.timeout = const Duration(seconds: 30),
    this.retries = 0,
    this.backoff = const Duration(milliseconds: 500),
    this.redirects = 0,
    this.base,
    this.encoding,
    bool session = false,
    CookieJar? jar,
    this.proxy,
    this.cap,
    this.cache,
    this.limiter,
  }) : jar = jar ?? (session ? CookieJar() : null),
       _ownsClient = pool == null,
       _client = pool ?? _createClient(proxy),
       headers = headers ?? const {};

  /// Creates a client that presents itself as a desktop browser.
  ///
  /// The defaults [Fetcher] sent unasked through 6.0.0: a Chrome
  /// `User-Agent` and an HTML `Accept` header, which is what most scraping
  /// targets expect. [headers] is merged over them, so one entry can be
  /// replaced without restating the pair.
  ///
  /// ```dart
  /// final scraper = Fetcher.browser(retries: 3);
  /// ```
  factory Fetcher.browser({
    http.Client? pool,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    int retries = 0,
    Duration backoff = const Duration(milliseconds: 500),
    int redirects = 0,
    String? base,
    Encoding? encoding,
    bool session = false,
    CookieJar? jar,
    String? proxy,
    int? cap,
    HttpCache? cache,
    Waiting? limiter,
  }) => Fetcher(
    pool: pool,
    headers: {..._browserHeaders, ...?headers},
    timeout: timeout,
    retries: retries,
    backoff: backoff,
    redirects: redirects,
    base: base,
    encoding: encoding,
    session: session,
    jar: jar,
    proxy: proxy,
    cap: cap,
    cache: cache,
    limiter: limiter,
  );

  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  };

  static http.Client _createClient(String? proxy) {
    if (proxy == null) return http.Client();
    final inner = dart_io.HttpClient();
    final cleanProxy = proxy.toUpperCase().startsWith('PROXY ')
        ? proxy
        : 'PROXY $proxy';
    inner.findProxy = (uri) => cleanProxy;
    return IOClient(inner);
  }

  /// Sends [method] to [url] and returns the response.
  ///
  /// [retries] overrides the client's own for this call, and is the whole of
  /// the retry decision: `0` sends once, `n` allows `n` more attempts on a
  /// transport error, a 5xx or a 429. A `Retry-After` header is honoured when
  /// present, otherwise the delay is [backoff] multiplied by the attempt
  /// number with jitter. A `retry: bool` stood beside it through 6.0.0 — a
  /// flag deciding whether a number applied, which is the `times:`/`retries:`
  /// pair Rule 5 deleted from `concurrent.retry` wearing a second hat.
  ///
  /// [redirects] overrides the client's the same way, and reads the same:
  /// `0` returns the `3xx` itself, headers and all, and a chain longer than a
  /// positive limit throws [FatalHttpException]. This too was two parameters
  /// — `redirect: false` and `redirects: 0` said one thing in two types, and
  /// the `5` beside them was a limit no caller had asked for.
  ///
  /// Both are `int?`, and the `null` is load-bearing: *no override given,
  /// use the client's*. `Fetcher(retries: 3)` would be unreachable through
  /// [get] and [post] if their parameters defaulted to `0` instead.
  ///
  /// [onretry] is called with the URL and the attempt number just before each
  /// wait, which is how a caller counts retries that happen in here — a crawl
  /// reports them as `stats.retried`.
  ///
  /// [fetch] is the request the reply should report as its own
  /// [Reply.fetch], carrying the `tag`, `meta` and `depth` a crawl put on it.
  /// [call] passes it; a direct `get` has nothing to pass and the reply
  /// describes itself.
  Future<Reply> send(
    HttpMethod method,
    Uri url, {
    Map<String, String>? headers,
    Body? body,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    void Function(Uri url, int attempt)? onretry,
    Fetch? fetch,
  }) async {
    final store = cache;
    CacheEntry? entry;
    if (store != null && method == HttpMethod.get) {
      entry = await store.read(url);
      // Still inside its max-age: the server said not to ask yet, so don't.
      if (entry != null && entry.fresh) return entry.response;
    }

    final merged = {
      ...this.headers,
      // Caller-supplied validators win: an explicit If-None-Match is a
      // question the caller is asking, not one the cache is.
      ...?entry?.validators,
      ...?headers,
    };
    final deadline = timeout ?? this.timeout;
    final effRetries = retries ?? this.retries;
    final effRedirects = redirects ?? this.redirects;
    final allowRetry = effRetries > 0;
    final maxAttempts = allowRetry ? effRetries + 1 : 1;
    var currentUrl = url;
    var currentMethod = method;
    var currentBody = body;
    var redirectCount = 0;

    while (true) {
      for (var attempt = 1; ; attempt++) {
        // Before the request, not around the whole call: a rate is about how
        // often something starts, and a retry is another start.
        await limiter?.take();
        final currentMerged = Map<String, String>.from(merged);
        if (jar != null) {
          final cookieHeader = jar!.header(currentUrl);
          if (cookieHeader != null) {
            currentMerged['Cookie'] = currentMerged.containsKey('Cookie')
                ? '${currentMerged['Cookie']}; $cookieHeader'
                : cookieHeader;
          }
        }
        final request = http.Request(currentMethod.wire, currentUrl)
          ..headers.addAll(currentMerged);
        // Followed here, not by the client: a hop has to re-read the cookie
        // jar and re-apply the method rules below. `maxRedirects` on the
        // request would be dead weight beside that.
        request.followRedirects = false;
        currentBody?.apply(request);
        try {
          final streamed = await _client.send(request).timeout(deadline);
          final response = await _collect(streamed, currentUrl, deadline);
          if (jar != null && response.headers.containsKey('set-cookie')) {
            jar!.add(response.headers['set-cookie']!, uri: currentUrl);
          }
          if (allowRetry &&
              _retryable(response.statusCode) &&
              attempt < maxAttempts) {
            retried++;
            onretry?.call(currentUrl, attempt);
            await Future<void>.delayed(
              _retryAfter(response.headers) ??
                  _backoffWithJitter(backoff * attempt),
            );
            continue;
          }

          if (effRedirects > 0 &&
              _isRedirect(response.statusCode) &&
              response.headers.containsKey('location')) {
            if (redirectCount >= effRedirects) {
              throw FatalHttpException(
                'Redirect limit of $effRedirects exceeded',
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

          if (response.statusCode == 304 && entry != null) {
            // Unchanged. The body never crossed the wire; serve the one held,
            // and restart its clock from what the server just said about
            // freshness.
            final confirmed = _confirm(entry, response.headers);
            if (store != null) await store.write(url, confirmed);
            return confirmed;
          }

          final result = Reply(
            url: currentUrl,
            fetch: fetch ?? Fetch(url, method: method),
            status: response.statusCode,
            headers: response.headers,
            bytes: response.bodyBytes,
            encoding: encoding ?? this.encoding,
          );
          if (store != null && _storable(method, result)) {
            await store.write(url, result);
          }
          return result;
        } catch (error) {
          // A body over the cap, or a redirect loop, is the server's settled
          // answer: replaying it only re-downloads the same refusal.
          if (error is FatalHttpException) rethrow;
          if (!allowRetry || attempt >= maxAttempts) rethrow;
          retried++;
          onretry?.call(currentUrl, attempt);
          await Future<void>.delayed(_backoffWithJitter(backoff * attempt));
        }
      }
    }
  }

  /// Reads [streamed] into a response, refusing bodies larger than [cap].
  ///
  /// [deadline] bounds the whole body transfer, not just the headers, so a
  /// server that dribbles bytes cannot hold a worker open indefinitely.
  Future<http.Response> _collect(
    http.StreamedResponse streamed,
    Uri url,
    Duration deadline,
  ) {
    final limit = cap;

    Future<http.Response> read() async {
      if (limit == null) return http.Response.fromStream(streamed);

      final declared = streamed.contentLength;
      if (declared != null && declared > limit) {
        await streamed.stream.drain<void>();
        throw FatalHttpException(
          'Page of $declared bytes exceeds the cap of $limit',
          uri: url,
        );
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream) {
        builder.add(chunk);
        if (builder.length > limit) {
          throw FatalHttpException('Page exceeds the cap of $limit', uri: url);
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

    return read().timeout(deadline);
  }

  /// Whether [response] is worth keeping between runs.
  ///
  /// A cache of anything but a plain successful `GET` would hand back answers
  /// to questions nobody asked again.
  static bool _storable(HttpMethod method, Reply response) {
    if (method != HttpMethod.get || response.status != 200) return false;
    final control = response.headers['cache-control']?.toLowerCase();
    return control == null || !control.contains('no-store');
  }

  /// [entry]'s response, restamped with the freshness headers a `304` carried.
  static Reply _confirm(CacheEntry entry, Map<String, String> headers) {
    const refreshed = ['cache-control', 'expires', 'date', 'etag'];
    return Reply(
      url: entry.response.url,
      fetch: entry.response.fetch,
      status: entry.response.status,
      headers: {
        ...entry.response.headers,
        for (final name in refreshed)
          if (headers[name] != null) name: headers[name]!,
      },
      bytes: entry.response.bytes,
      cached: true,
    );
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  // The one generator in the library, so `util.rand.seed` makes a retry's
  // timing as repeatable as a crawl's order. Two generators doing this job is
  // one too many.
  static const RandAccessor _rand = RandAccessor();

  static Duration _backoffWithJitter(Duration base) => _rand.jitter(base);

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

  /// Streams [url] to [path], resolved against [base].
  ///
  /// Skips the download when the destination already holds bytes. Set [match]
  /// to also skip on a loosely-named sibling — see [Fs.similar] for why that
  /// is off by default.
  ///
  /// [retries] overrides the client's own, exactly as it does on [send], and
  /// is `0` by default for the same reason. [onprogress] is spelled the way
  /// [send]'s `onretry` and `io.watch`'s `onchange` are; it was `onProgress`
  /// through 6.0.0, the library's one camelCase parameter.
  Future<FileSystemEntry> download(
    Uri url,
    String path, {
    Map<String, String>? headers,
    void Function(int received, int total)? onprogress,
    String part = '.part',
    bool match = false,
    int? retries,
  }) async {
    final dest = resolve(path);
    if (match ? Fs.similar(dest) : Fs.has(dest)) return Fs.entryFor(dest);

    final merged = {...this.headers, ...?headers};
    final effRetries = retries ?? this.retries;
    final maxAttempts = effRetries > 0 ? effRetries + 1 : 1;
    for (var attempt = 1; ; attempt++) {
      try {
        final file = await Fs.download(
          url,
          dest,
          pool: _client,
          headers: merged,
          onprogress: onprogress,
          part: part,
        );
        count++;
        return Fs.entryFor(file.path);
      } catch (_) {
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(backoff * attempt);
      }
    }
  }

  /// Answers [fetch] — **this client, as a [Send]**.
  ///
  /// What makes `Fetcher` the default transport of a crawl without a class
  /// hierarchy in between: `Crawl.using` takes a `Send`, a `Fetcher` is one,
  /// and so is any closure.
  ///
  /// Schemes other than `http` and `https` are answered here rather than on
  /// the wire, which is what lets a crawl be seeded with a `file:` path, a
  /// `data:` document or raw markup: `Fetch(Uri.file(path))`,
  /// `Fetch(coerce(markup))`. `HttpDownloader` did this through 5.5.0 and was
  /// a class for it.
  Future<Reply> call(Fetch fetch) async {
    final uri = fetch.url;
    switch (uri.scheme) {
      case 'http':
      case 'https':
        return send(
          fetch.method,
          uri,
          headers: fetch.headers.isEmpty ? null : fetch.headers,
          body: fetch.body,
          fetch: fetch,
        );
      case 'data':
        return Reply(
          url: uri,
          fetch: fetch,
          status: 200,
          headers: {'content-type': uri.data?.mimeType ?? 'text/html'},
          bytes:
              uri.data?.contentAsBytes() ??
              utf8.encode(uri.data?.contentAsString() ?? ''),
        );
      case 'file':
        final file = dart_io.File(uri.toFilePath());
        if (!await file.exists()) {
          // A path that is not there is a miss, not a page whose body is its
          // own URL: report it the way a 404 from the network would arrive.
          return Reply(
            url: uri,
            fetch: fetch,
            status: 404,
            headers: const {'content-type': 'text/plain'},
            bytes: const [],
          );
        }
        return Reply(
          url: uri,
          fetch: fetch,
          status: 200,
          headers: const {'content-type': 'text/html'},
          bytes: await file.readAsBytes(),
        );
      default:
        final content = uri.scheme == 'string'
            ? Uri.decodeComponent(uri.path)
            : (uri.hasScheme ? uri.toString() : uri.path);
        return Reply(
          url: uri,
          fetch: fetch,
          status: 200,
          headers: const {'content-type': 'text/plain'},
          bytes: utf8.encode(content),
        );
    }
  }

  /// Whether [path], resolved against [base], already holds bytes.
  bool has(String path) => Fs.has(resolve(path));

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
class Morsel {
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

  /// Whether this cookie goes back only to the exact host that set it.
  ///
  /// A `Set-Cookie` carrying no `Domain` attribute is host-only, per RFC 6265
  /// section 5.3: the host it came from is the only one it is sent to. A
  /// cookie that *did* name a domain it is entitled to widens to that
  /// domain's subtree instead, which is what [domain] then holds.
  final bool host;

  /// Creates a cookie.
  ///
  /// Set [host] for a cookie bound to [domain] exactly rather than to it and
  /// everything under it. [Morsel.parse] sets it for a `Set-Cookie` that
  /// named no `Domain` of its own.
  Morsel(
    this.name,
    this.value, {
    this.domain,
    this.path,
    this.expires,
    this.secure = false,
    this.httponly = false,
    this.host = false,
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
  static List<Morsel> _parseAll(String setCookieHeader, {Uri? uri}) => [
    for (final piece in split(setCookieHeader)) Morsel.parse(piece, uri: uri),
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
  /// For a header that may carry several cookies use [CookieJar.add], which
  /// splits the comma-joined form with [split] first.
  factory Morsel.parse(String setCookieHeader, {Uri? uri}) {
    final parts = setCookieHeader.split(';');
    final nameValue = parts.first.split('=');
    final name = nameValue.first.trim();
    final value = nameValue.length > 1
        ? nameValue.sublist(1).join('=').trim()
        : '';
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

    // A Domain the request host does not belong to is ignored, falling back
    // to a host-only cookie — and so is a Set-Cookie that named no Domain at
    // all, which is host-only by definition. See [_acceptDomain].
    final widened = _acceptDomain(domain, uri?.host);
    return Morsel(
      name,
      value,
      domain: widened ?? uri?.host,
      host: widened == null,
      // Max-Age wins over Expires per RFC 6265 section 5.3.
      path: (path != null && path.startsWith('/')) ? path : _defaultPath(uri),
      expires: maxAge != null
          ? DateTime.now().add(Duration(seconds: maxAge))
          : expires,
      secure: secure,
      httponly: httponly,
    );
  }

  /// The `Domain` attribute to honour, or `null` to make the cookie host-only.
  ///
  /// RFC 6265 section 5.3.6: a server may only widen a cookie to a domain the
  /// request host itself belongs to. Without this check a response from
  /// `evil.example.com` could set `Domain=com` and have the cookie sent to
  /// every other `.com` host the client later visits. A domain with no dot in
  /// it — a bare TLD such as `com` — is refused outright, and so is a host
  /// that is only a suffix match without a label boundary (`notexample.com`
  /// against `Domain=example.com`).
  static String? _acceptDomain(String? domain, String? host) {
    if (domain == null || domain.isEmpty) return null;
    final wanted = domain.toLowerCase();
    // A bare TLD, or anything without a label separator, is far too broad.
    if (!wanted.contains('.') || wanted.startsWith('.')) return null;
    if (host == null || host.isEmpty) return null;
    final source = host.toLowerCase();
    if (source == wanted) return wanted;
    if (source.endsWith('.$wanted')) return wanted;
    return null;
  }

  /// Whether this cookie should be sent with a request to [url].
  ///
  /// A [host]-only cookie needs the host to match exactly; one that named a
  /// `Domain` also reaches that domain's subdomains. RFC 6265 section 5.4.
  bool matches(Uri url) {
    if (expires != null && DateTime.now().isAfter(expires!)) return false;
    if (secure && url.scheme != 'https') return false;
    if (domain != null && domain!.isNotEmpty) {
      final target = url.host.toLowerCase();
      final dom = domain!.toLowerCase();
      if (host) {
        if (target != dom) return false;
      } else if (target != dom && !target.endsWith('.$dom')) {
        return false;
      }
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
  final Map<String, Morsel> _cookies = {};

  /// Stores a single [cookie], replacing any with the same name, domain and path.
  void set(Morsel cookie) {
    _cookies['${cookie.domain ?? ""}:${cookie.path ?? ""}:${cookie.name}'] =
        cookie;
  }

  /// Parses and stores every cookie in a `Set-Cookie` header.
  ///
  /// Handles the comma-joined form `package:http` produces for a response that
  /// sent several `Set-Cookie` headers. A cookie with a past expiry deletes the
  /// entry it names, as a server clearing a session does. A `Domain` the
  /// responding host does not belong to is ignored — see [Morsel.parse].
  void add(String headerValue, {Uri? uri}) {
    for (final cookie in Morsel._parseAll(headerValue, uri: uri)) {
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
  Sequence<Morsel> get cookies => _cookies.values.seq;

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
}
