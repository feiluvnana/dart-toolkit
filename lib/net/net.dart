/// # Networking
///
/// HTTP requests and downloads ([get], [post], [download], [send]), the
/// frontier that crawls ([crawl], [Crawler]) — and the other direction, a
/// server that listens ([serve], [serveOnce]).
///
/// ```dart
/// final res = await get('https://api.github.com/users/octocat');
/// if (res.ok) print(res.json['name']);
///
/// await download('https://example.com/big.zip', 'out/big.zip');
/// ```
///
/// **Nothing here parses anything.** A crawler fetches JSON, sitemaps,
/// archives and images as readily as it fetches pages, so a [Response] carries
/// the bytes, the text and the headers, and reading them is [Response.parse]
/// plus a codec from `format`:
///
/// ```dart
/// res.parse(DocumentFormat.html).$('h1').text;
/// res.parse(DocumentFormat.json).at('data.items');
/// parseRobots(res.text).allowed(url);
/// parseSitemap(res.text);
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
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as pkg_http;

import '../io/entry.dart';
import '../src/method.dart';
import 'crawl.dart';
import 'fetch.dart';
import 'http.dart';
import 'serve.dart';
import 'serve.dart' as serve_impl;

export '../src/method.dart';
export 'cache.dart';
export 'crawl.dart';
export 'fetch.dart';
export 'form.dart';
export 'http.dart';
export 'serve.dart' hide onceOn, serveOn;

// ============================================================================
// TOP-LEVEL HTTP, CRAWLER & SERVER HELPERS
// ============================================================================

Fetcher _shared = Fetcher();

/// The shared HTTP client.
Fetcher get httpClient => Zone.current[#_netClient] as Fetcher? ?? _shared;

/// Sends a GET request to [url].
Future<Response> get(
  Object url, {
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Encoding? encoding,
  Fetch? fetch,
}) => httpClient.get(
  url is Uri ? url : coerce(url.toString()),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  encoding: encoding,
  fetch: fetch,
);

/// Reads a loosely-typed [body] argument as a [Body].
///
/// A `Map` or `List` is **always JSON**. It used to be form-encoded when its
/// static type happened to be `Map<String, String>` and JSON otherwise, so
/// adding one integer field to a request silently changed its content type.
/// Form encoding is [Body.form], asked for by name.
Body? _coerceBody(Object? body) => switch (body) {
  null => null,
  Body value => value,
  String text => Body.text(text),
  List<int> bytes => Body.bytes(bytes),
  Map<dynamic, dynamic>() || List<dynamic>() => Body.json(body),
  _ => Body.text(body.toString()),
};

/// Sends a POST request to [url].
Future<Response> post(
  Object url, {
  Object? body,
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Encoding? encoding,
  Fetch? fetch,
}) => httpClient.post(
  url is Uri ? url : coerce(url.toString()),
  body: _coerceBody(body),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  encoding: encoding,
  fetch: fetch,
);

/// Sends a PUT request to [url].
Future<Response> put(
  Object url, {
  Object? body,
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Encoding? encoding,
  Fetch? fetch,
}) => httpClient.put(
  url is Uri ? url : coerce(url.toString()),
  body: _coerceBody(body),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  encoding: encoding,
  fetch: fetch,
);

/// Sends a DELETE request to [url].
Future<Response> delete(
  Object url, {
  Object? body,
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Encoding? encoding,
  Fetch? fetch,
}) => httpClient.delete(
  url is Uri ? url : coerce(url.toString()),
  body: _coerceBody(body),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  encoding: encoding,
  fetch: fetch,
);

/// Sends a PATCH request to [url].
Future<Response> patch(
  Object url, {
  Object? body,
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Encoding? encoding,
  Fetch? fetch,
}) => httpClient.patch(
  url is Uri ? url : coerce(url.toString()),
  body: _coerceBody(body),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  encoding: encoding,
  fetch: fetch,
);

/// Sends a HEAD request to [url].
Future<Response> head(
  Object url, {
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Fetch? fetch,
}) => httpClient.head(
  url is Uri ? url : coerce(url.toString()),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  fetch: fetch,
);

/// Downloads [url] to [path] atomically.
Future<FileSystemEntry> download(
  Object url,
  String path, {
  void Function(int received, int total)? onProgress,
  Map<String, String>? headers,
  int? retries,
}) => httpClient.download(
  url is Uri ? url : coerce(url.toString()),
  path,
  onprogress: onProgress,
  headers: headers,
  retries: retries,
);

/// Starts a crawl from [seeds], emitting a `Stream<Response>`.
///
/// A seed is a [String], a [Uri] or a [Fetch] — anything else is an
/// [ArgumentError], rather than being silently `toString()`ed into a URL that
/// cannot be fetched. [next] is given each response and returns the requests
/// to follow, in the same three shapes; returning nothing ends that branch.
///
/// ```dart
/// final pages = crawl(
///   ['https://shop.test/catalogue'],
///   (res) => res.$$('a.product').map((a) => res.follow(a.attr('href')!)),
/// )..sameHost();
///
/// await for (final res in pages) {
///   print(res.url);
/// }
/// ```
Crawler crawl(
  Iterable<Object> seeds, [
  Iterable<Object> Function(Response res)? next,
]) => Crawler(
  seeds.map(_toFetch),
  next == null ? null : (Response res) => next(res).map(_toFetch),
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

/// Sends an HTTP request with arbitrary [method] to [url].
Future<Response> send(
  HttpMethod method,
  Object url, {
  Object? body,
  Map<String, String>? headers,
  Duration? timeout,
  int? redirects,
  int? retries,
  Encoding? encoding,
  Fetch? fetch,
}) => httpClient.send(
  method,
  url is Uri ? url : coerce(url.toString()),
  body: _coerceBody(body),
  headers: headers,
  timeout: timeout,
  redirects: redirects,
  retries: retries,
  encoding: encoding,
  fetch: fetch,
);

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

/// Runs [action] with [client] as the [httpClient] every call inside it sees.
///
/// Scoped to the async Zone [action] runs in, so a test or one stage of a
/// pipeline can swap the client without touching the process-wide default.
/// [client] is a [Fetcher] or a `package:http` `Client`.
///
/// ```dart
/// await withHttpClient(mockClient, () async {
///   final res = await get('https://example.test');
/// });
/// ```
Future<R> withHttpClient<R>(
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

/// Replaces the process-wide default [httpClient].
///
/// Closes the client being replaced unless [close] is false. Prefer
/// [withHttpClient] where a scoped swap will do.
Future<void> useHttpClient(Fetcher client, {bool close = true}) async {
  final previous = _shared;
  _shared = client;
  if (close && !identical(previous, client)) await previous.close();
}
