/// # Networking
///
/// HTTP requests and downloads ([get], [post], [download], [send]), the
/// frontier that crawls ([crawl], [Crawler]) — and the other direction, a
/// server that listens ([serve], [serveOnce]).
///
/// ```dart
/// final res = await Http.get('https://api.github.com/users/octocat');
/// if (res.ok) print(res.json['name']);
///
/// await Http.download('https://example.com/big.zip', into: 'out/big.zip');
/// ```
///
/// **Nothing here parses anything.** A crawler fetches JSON, sitemaps,
/// archives and images as readily as it fetches pages, so a [Response] carries
/// the bytes, the text and the headers, and reading them is [Response.parse]
/// plus a codec from `format`:
///
/// ```dart
/// res.parse(.html).$('h1').text;
/// res.parse(.json).at('data.items');
/// res.text.parse(.robots).allowed(url);
/// res.text.parse(.sitemap);
/// ```
///
/// ## The three seams
///
/// The library is built on seams rather than on classes of its own:
///
/// | Seam | Is |
/// | :--- | :--- |
/// | transport | [Send], a `typedef` |
/// | document | `DocumentFormat`, through [Response.parse] |
/// | results | a native `Stream<Response>` and the collection extensions |
///
/// URLs are always [Uri] values, matching `package:http`; the [UrlString.url]
/// extension keeps call sites short, and every function here also accepts a
/// plain [String].
/// {@category Networking}
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as pkg_http;

import '../io/path.dart';
import '../src/method.dart';
import 'crawl.dart';
import 'fetch.dart';
import 'http.dart';
import 'serve.dart';
import 'serve.dart' as serve_impl;

export '../src/method.dart';
export 'cache.dart';
export 'crawl.dart';
export 'fetch.dart' hide coerce;
export 'form.dart';
export 'http.dart';
export 'serve.dart' hide onceOn, serveOn;

// ============================================================================
// HTTP (Http)
// ============================================================================

Fetcher _shared = Fetcher();

/// One-off HTTP requests, through a shared pooled client.
///
/// ```dart
/// final res = await Http.get('https://api.test/users'.url);
/// if (res.ok) print(res.json.at('data.name').text());
///
/// await Http.post(url, body: .json({'q': 'widgets'}));
/// await Http.download(url, into: Path('out') / 'catalogue.zip');
/// ```
///
/// **Why a type and not seven top-level functions.** `get`, `post`, `put`,
/// `patch`, `delete` and `head` are also what `package:http` exports, and a
/// scraping script imports both. Through 8.1.0 this package's README had to
/// instruct its readers to write an eight-name `hide` clause. One type is
/// worth more than the four characters it costs, and `Http.` is also the
/// thing an editor can complete.
///
/// A request that needs a session — cookies, base headers, a connection kept
/// warm — is a [Fetcher], which carries the same six verbs as instance
/// methods.
abstract final class Http {
  /// The client every member here sends through.
  ///
  /// [using] swaps it for one async scope; [use] replaces it for the process.
  static Fetcher get client => Zone.current[#_netClient] as Fetcher? ?? _shared;

  /// Sends a GET request to [url].
  static Future<Response> get(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => client.get(
    _url(url),
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a POST request to [url].
  ///
  /// [body] is a [Body], which is a sealed type with one factory per shape,
  /// so a leading dot is the whole spelling:
  ///
  /// ```dart
  /// await Http.post(url, body: .json({'q': 'widgets'}));
  /// await Http.post(url, body: .form({'user': 'ada'}));
  /// await Http.post(url, body: .text('raw'));
  /// ```
  ///
  /// It was `Object?` through 8.1.0, which read a `Map` as JSON and a
  /// `Map<String, String>` as a form — so adding one integer field to a
  /// request silently changed its content type. Naming the shape cannot do
  /// that, and it is shorter to write.
  static Future<Response> post(
    Object url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => client.post(
    _url(url),
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a PUT request to [url].
  static Future<Response> put(
    Object url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => client.put(
    _url(url),
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a PATCH request to [url].
  static Future<Response> patch(
    Object url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => client.patch(
    _url(url),
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a DELETE request to [url].
  static Future<Response> delete(
    Object url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => client.delete(
    _url(url),
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Sends a HEAD request to [url].
  static Future<Response> head(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Fetch? fetch,
  }) => client.head(
    _url(url),
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    fetch: fetch,
  );

  /// Sends a request with an arbitrary [method] to [url].
  ///
  /// ```dart
  /// await Http.send(.patch, url, body: .json(data));
  /// ```
  static Future<Response> send(
    HttpMethod method,
    Object url, {
    Body? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) => client.send(
    method,
    _url(url),
    body: body,
    headers: headers,
    timeout: timeout,
    redirects: redirects,
    retries: retries,
    encoding: encoding,
    fetch: fetch,
  );

  /// Downloads [url] to [into], atomically.
  ///
  /// ```dart
  /// await Http.download(url, into: Path('out') / 'catalogue.zip');
  /// ```
  ///
  /// Streams to a `.part` file and renames it into place, so the destination
  /// holds a whole file or nothing at all. [onProgress] is called with the
  /// bytes so far and the total, which is `-1` when the server did not say.
  static Future<Path> download(
    Object url, {
    required String into,
    void Function(int received, int total)? onProgress,
    Map<String, String>? headers,
    int? retries,
  }) async => Path(
    (await client.download(
      _url(url),
      into,
      onprogress: onProgress,
      headers: headers,
      retries: retries,
    )).path,
  );

  /// Runs [action] with [client] as the [Http.client] every call inside sees.
  ///
  /// Scoped to the async Zone [action] runs in, so a test or one stage of a
  /// pipeline can swap the client without touching the process-wide default.
  /// [client] is a [Fetcher] or a `package:http` `Client`.
  ///
  /// ```dart
  /// await Http.using(mockClient, () async {
  ///   final res = await Http.get('https://example.test'.url);
  /// });
  /// ```
  static Future<R> using<R>(
    Object client,
    FutureOr<R> Function() action,
  ) async {
    final fetcher = switch (client) {
      Fetcher fetcher => fetcher,
      pkg_http.Client raw => Fetcher(client: raw),
      _ => throw ArgumentError(
        'Expected Fetcher or http.Client, got ${client.runtimeType}',
      ),
    };
    return runZoned(action, zoneValues: {#_netClient: fetcher});
  }

  /// Replaces the process-wide default [client].
  ///
  /// Closes the client being replaced unless [close] is false. Prefer [using]
  /// where a scoped swap will do.
  static Future<void> use(Fetcher client, {bool close = true}) async {
    final previous = _shared;
    _shared = client;
    if (close && !identical(previous, client)) await previous.close();
  }

  /// One loosely-typed `url` argument as a [Uri].
  static Uri _url(Object url) => url is Uri ? url : coerce(url.toString());
}

// ============================================================================
// CRAWLING & SERVING
// ============================================================================

/// Starts a crawl from [seeds], emitting a `Stream<Response>`.
///
/// A seed is a [String], a [Uri] or a [Fetch] — anything else is an
/// [ArgumentError], rather than being silently `toString()`ed into a URL that
/// cannot be fetched. [next] is given each response and returns the requests
/// to follow, in the same three shapes; returning nothing ends that branch.
///
/// Every knob is a named argument, so an editor shows all of them with their
/// types and defaults, and none of them can change after the stream exists.
///
/// ```dart
/// final pages = crawl(['https://shop.test/catalogue'], next: (res) => res.$$('a.product').map((a) => res.follow(a.attr('href')!)), concurrency: 8, politeness: .perHost(250.ms), scope: .sameHost, limit: 50);
///
/// await for (final res in pages) {
///   print(res.url);
/// }
/// ```
Crawler crawl(
  Iterable<Object> seeds, {
  Iterable<Object> Function(Response res)? next,
  int concurrency = 4,
  Politeness politeness = Politeness.none,
  Scope scope = Scope.anywhere,
  RobotsPolicy robots = RobotsPolicy.ignore,
  int? depth,
  int? limit,
  Iterable<Pattern> allow = const [],
  Iterable<Pattern> deny = const [],
  Iterable<String> accept = const [],
  bool dedupe = true,
  String? resume,
  Duration resumeEvery = const Duration(seconds: 5),
  Send? send,
}) => Crawler(
  seeds.map(_toFetch),
  next: next == null ? null : (Response res) => next(res).map(_toFetch),
  concurrency: concurrency,
  politeness: politeness,
  scope: scope,
  robots: robots,
  depth: depth,
  limit: limit,
  allow: allow,
  deny: deny,
  accept: accept,
  dedupe: dedupe,
  resume: resume,
  resumeEvery: resumeEvery,
  send: send,
);

/// One crawl seed or follow-up, as a [Fetch].
///
/// Throws [ArgumentError] for anything that is not a [Fetch], [Uri] or
/// [String]: a crawl that quietly turned an arbitrary object into a URL string
/// would fail much later, at the socket, with nothing pointing back here.
Fetch _toFetch(Object target) => switch (target) {
  Fetch fetch => fetch,
  Uri url => Fetch(url),
  String text => Fetch(coerce(text)),
  _ => throw ArgumentError.value(
    target,
    'seed',
    'Expected a String, Uri or Fetch',
  ),
};

/// Binds [port] and answers incoming HTTP requests with [handler].
Future<Server> serve(
  int port,
  FutureOr<Served> Function(Asked req) handler, {
  String host = 'localhost',
}) => serve_impl.serveOn(port, handler, host: host);

/// Serves [port] until [handler] returns a non-null value, then replies and closes.
Future<R?> serveOnce<R extends Object>(
  int port,
  FutureOr<R?> Function(Asked req) handler, {
  String host = 'localhost',
  Served reply = const Served.text('Done. You can close this tab.'),
  Duration? timeout,
}) => serve_impl.onceOn(
  port,
  handler,
  host: host,
  reply: reply,
  timeout: timeout,
);
