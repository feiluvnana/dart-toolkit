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
/// res.parse(format.html).$('h1').text;
/// res.parse(format.json).at('data.items');
/// res.parse(format.robots).allowed(url);
/// res.parse(format.sitemap);
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

import '../collection/sequence.dart';

import 'crawl.dart';
import 'fetch.dart';
import 'http.dart';
import 'serve.dart';
import 'serve.dart' as serve_impl;

export 'cache.dart';
export 'crawl.dart';
export 'fetch.dart';
export 'form.dart';
export 'http.dart';
export 'serve.dart' hide onceOn, serveOn;

// ============================================================================
// NET DOMAIN (net.*) - HTTP, Crawling & Listening
// ============================================================================

Fetcher _shared = Fetcher();

/// The `net` domain: HTTP, crawling and listening.
const NetAccessor net = NetAccessor();

/// Entry point for networking and scraping.
///
/// Requests go through [http], a shared [Fetcher]; crawls through [crawl].
/// Reading what comes back is `format`, through [Reply.parse]. For a client
/// of your own, construct a [Fetcher] and hand it to [use] — or to
/// [Crawl.using], which needs no singleton at all.
///
/// ```dart
/// final res = await net.http.send(.get, 'https://example.com'.url);
/// res.parse(format.html).$('h2.title').texts.collect(.foreach(print));
/// ```
class NetAccessor {
  /// Creates the accessor. Prefer the shared [net] instance.
  const NetAccessor();

  /// The shared HTTP client: requests, downloads and [Fetcher.sync].
  ///
  /// A [Send], so it is also the default transport of every [Crawl].
  Fetcher get http => _shared;

  /// A crawl over [seeds], following whatever [next] returns.
  ///
  /// See [Crawl]. The five entry points of 5.5.0 — `crawl(uri)`, `.all`,
  /// `.seed`, `.html`, `.file`, `.sitemap` — are this one, because a seed is
  /// a [Fetch] and a [Fetch] takes any URL the library can answer:
  ///
  /// ```dart no-compile
  /// net.crawl([Fetch(url)].seq, next);                     // was crawl(uri)
  /// net.crawl(urls.map(Fetch.new), next);              // was .all(uris)
  /// net.crawl([Fetch(coerce(markup))].seq, next);          // was .html(markup)
  /// net.crawl([Fetch(Uri.file(path))].seq, next);          // was .file(path)
  /// ```
  ///
  /// A sitemap is a crawl of its own, which is what deleted `Sitemap.load`
  /// and its hand-rolled depth limit — see the `format.sitemap` library doc.
  Crawl crawl(
    Sequence<Fetch> seeds, [
    Sequence<Fetch> Function(Reply res)? next,
  ]) => Crawl(seeds, next);

  /// Binds [port] and answers every request with [handler].
  ///
  /// The mirror of [http]: the client half reads a URL and returns a [Reply],
  /// so the server half takes an [Asked] and returns a [Served]. Nothing more
  /// — see the `net/serve.dart` library doc for what is deliberately absent.
  ///
  /// ```dart
  /// final server = await net.serve(8080, (req) async => switch (req.path) {
  ///   '/health' => Served.json({'ok': true}),
  ///   _ => Served.status(404),
  /// });
  /// await server.close();
  /// ```
  ///
  /// Pass `port: 0` to let the OS pick a free one and read [Server.port]
  /// back. [host] defaults to `localhost`, so nothing is exposed off the
  /// machine until a script asks for it — pass `'0.0.0.0'` when it should be.
  Future<Server> serve(
    int port,
    FutureOr<Served> Function(Asked req) handler, {
    String host = 'localhost',
  }) => serve_impl.serveOn(port, handler, host: host);

  /// Serves [port] until [handler] returns a value, then replies and closes.
  ///
  /// An OAuth callback is not a server, it is a single answer a script waits
  /// for, and writing it as one means writing the shutdown too:
  ///
  /// ```dart
  /// final code = await net.once(8080, (req) => req.query['code']);
  /// ```
  ///
  /// Requests that hand back `null` are answered `404` and the wait goes on.
  /// [reply] is what the request that *does* answer sees, and [timeout] gives
  /// up and returns `null` rather than waiting for a redirect that is never
  /// coming.
  ///
  /// `once` beside [serve] is the same pairing as `io.async.csv.write` beside
  /// `io.csv.write`: different behaviour, not an alias.
  Future<R?> once<R extends Object>(
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

  /// Replaces the client returned by [http], closing the previous one.
  ///
  /// **The one process-wide mutable singleton in the library**, kept
  /// deliberately and against the reasoning that deleted `io.store` in 5.1.0.
  /// One set of auth headers process-wide is a real thing scripts do, and
  /// threading a [Fetcher] through every call is worse for them. Everything
  /// else has a way not to need it: [Crawl.using] takes a [Send], `Fetcher`
  /// is one, and `Sending.send` takes one too — so a program that would
  /// rather be explicit never has to touch this.
  ///
  /// Pass `close: false` to keep the old client open.
  Future<void> use(Fetcher client, {bool close = true}) async {
    final previous = _shared;
    _shared = client;
    if (close && !identical(previous, client)) await previous.close();
  }
}
