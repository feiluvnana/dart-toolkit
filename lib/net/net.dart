/// # Net Domain (`net.*`)
///
/// HTTP requests and downloads (`net.http`), the frontier that crawls
/// (`net.crawl`) — and the other direction, a server that listens
/// (`net.serve`, `net.once`).
///
/// **This domain does not parse anything**, and since 6.0.0 that is true. A
/// crawler fetches JSON, sitemaps, archives and images as readily as it
/// fetches pages, so a [Reply] carries the bytes, the text and the headers,
/// and reading them is [Reply.parse] plus a codec from `format`:
///
/// ```dart
/// res.parse(Codec.html).$('h1').text;
/// res.parse(Codec.json).at('data.items');
/// Formats.robots(res.text).allowed(url);
/// Formats.sitemap(res.text);
/// ```
///
/// `net.robots(text)` and `net.sitemap(text)` were two parsers declared here
/// through 5.5.0, one paragraph under the sentence above; they are
/// `format.robots` and `format.sitemap` now. Reading a `<form>` went the same
/// way, and `net` keeps only the half that sends one — see `Sending`.
///
/// ## The three seams
///
/// The domain is built on seams the library already has, rather than classes
/// of its own:
///
/// | Seam | Was | Is |
/// | :--- | :--- | :--- |
/// | transport | `Downloader` / `HttpDownloader` / `MapDownloader` / `DownloaderEvents` | [Send], a `typedef` |
/// | document | `net.robots`, `net.sitemap`, `Reply.parse` | `Codec`, through [Reply.parse] |
/// | results | `run` / `items` / `gather` / `flow` / `save` / `sink` / `emit` / `on.*` | `Flow<Reply>` and the collection vocabulary |
///
/// Forty-one public types became fourteen, and three of the ones that went
/// moved to `format` rather than disappearing.
///
/// URLs are always [Uri] values, matching `package:http`; the [UrlString.url]
/// extension keeps call sites short.
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

/// Idiomatic alias for [Reply].
typedef Response = Reply;

/// Idiomatic alias for [Crawl].
typedef Crawler = Crawl;

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

Body? _coerceBody(Object? body) {
  if (body == null) return null;
  if (body is Body) return body;
  if (body is String) return Body.text(body);
  if (body is List<int>) return Body.bytes(body);
  if (body is Map<String, String>) return Body.form(body);
  if (body is Map || body is List) return Body.json(body);
  return Body.text(body.toString());
}

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

/// Creates and configures a web crawl from [seeds].
///
/// Accepts a list of [Uri], [String], or [Fetch] objects.
Crawl _crawl(
  Iterable<dynamic> seeds, [
  Iterable<dynamic> Function(Response res)? next,
]) {
  final fetchSeeds = seeds.map(
    (s) => s is Fetch ? s : Fetch(s is Uri ? s : coerce(s.toString())),
  );
  final nextFn =
      next == null
          ? null
          : (Reply res) {
            final result = next(res);
            return result.map(
              (r) =>
                  r is Fetch ? r : Fetch(r is Uri ? r : coerce(r.toString())),
            );
          };
  return Crawl(fetchSeeds, nextFn);
}

/// Creates and configures a web crawl from [seeds].
///
/// Accepts a list of [Uri], [String], or [Fetch] objects.
Crawl crawl(
  Iterable<dynamic> seeds, [
  Iterable<dynamic> Function(Response res)? next,
]) => _crawl(seeds, next);

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

/// Serves [port] until [handler] returns a non-null value, then replies and closes.
Future<R?> once<R extends Object>(
  int port,
  FutureOr<R?> Function(Asked req) handler, {
  String host = 'localhost',
  Served reply = const Served.text('Done. You can close this tab.'),
  Duration? timeout,
}) => serveOnce(
  port,
  handler,
  host: host,
  reply: reply,
  timeout: timeout,
);

// ============================================================================
// STATIC HELPER HUB: Http
// ============================================================================

/// Static helper hub for HTTP requests, downloads, and web servers.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// final res = await Http.get('https://api.github.com/users/octocat');
/// if (res.ok) {
///   print(res.text);
/// }
/// ```
abstract final class Http {
  Http._();

  /// The shared HTTP client.
  static Fetcher get client => httpClient;

  /// Sends a GET request to [url].
  static Future<Response> get(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) =>
      httpClient.get(
        url is Uri ? url : coerce(url.toString()),
        headers: headers,
        timeout: timeout,
        redirects: redirects,
        retries: retries,
        encoding: encoding,
        fetch: fetch,
      );

  /// Sends a POST request to [url].
  static Future<Response> post(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) =>
      httpClient.post(
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
  static Future<Response> put(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) =>
      httpClient.put(
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
  static Future<Response> delete(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) =>
      httpClient.delete(
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
  static Future<Response> patch(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) =>
      httpClient.patch(
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
  static Future<Response> head(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Fetch? fetch,
  }) =>
      httpClient.head(
        url is Uri ? url : coerce(url.toString()),
        headers: headers,
        timeout: timeout,
        redirects: redirects,
        retries: retries,
        fetch: fetch,
      );

  /// Downloads [url] to [path] atomically.
  static Future<FileSystemEntry> download(
    Object url,
    String path, {
    void Function(int received, int total)? onProgress,
    Map<String, String>? headers,
    int? retries,
  }) =>
      httpClient.download(
        url is Uri ? url : coerce(url.toString()),
        path,
        onprogress: onProgress,
        headers: headers,
        retries: retries,
      );

  /// Creates and configures a web crawl from [seeds].
  static Crawl crawl(
    Iterable<dynamic> seeds, [
    Iterable<dynamic> Function(Response res)? next,
  ]) =>
      _crawl(seeds, next);

  /// Binds [port] and answers incoming HTTP requests with [handler].
  static Future<Server> serve(
    int port,
    FutureOr<Served> Function(Asked req) handler, {
    String host = 'localhost',
  }) =>
      serve_impl.serveOn(port, handler, host: host);

  /// Sends a request with arbitrary [method] to [url].
  static Future<Response> send(
    HttpMethod method,
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? redirects,
    int? retries,
    Encoding? encoding,
    Fetch? fetch,
  }) =>
      httpClient.send(
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

  /// Serves [port] until [handler] returns a non-null value, then replies and closes.
  static Future<R?> serveOnce<R extends Object>(
    int port,
    FutureOr<R?> Function(Asked req) handler, {
    String host = 'localhost',
    Served reply = const Served.text('Done. You can close this tab.'),
    Duration? timeout,
  }) =>
      serve_impl.onceOn(
        port,
        handler,
        host: host,
        reply: reply,
        timeout: timeout,
      );

  /// Serves [port] until [handler] returns a non-null value, then replies and closes.
  static Future<R?> once<R extends Object>(
    int port,
    FutureOr<R?> Function(Asked req) handler, {
    String host = 'localhost',
    Served reply = const Served.text('Done. You can close this tab.'),
    Duration? timeout,
  }) =>
      serveOnce(
        port,
        handler,
        host: host,
        reply: reply,
        timeout: timeout,
      );

  /// Runs [action] within an async Zone where [httpClient] resolves to [client].
  static Future<R> withClient<R>(Object client, FutureOr<R> Function() action) async {
    final fetcher = client is Fetcher
        ? client
        : client is pkg_http.Client
            ? Fetcher(client: client)
            : throw ArgumentError(
                'Expected Fetcher or http.Client, got ${client.runtimeType}',
              );
    return runZoned(action, zoneValues: {#_netClient: fetcher});
  }

  /// Replaces the default shared HTTP client.
  static Future<void> use(Fetcher client, {bool close = true}) async {
    final previous = _shared;
    _shared = client;
    if (close && !identical(previous, client)) await previous.close();
  }
}

