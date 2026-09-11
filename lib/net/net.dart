/// # Net Domain (`net.*`)
///
/// HTTP requests and downloads (`net.http`), the crawler engine
/// (`net.crawl`), the forms a page carries ([Form]) — and the other
/// direction, a server that listens (`net.serve`, `net.once`).
///
/// **This domain does not parse anything.** A crawler fetches JSON, sitemaps,
/// archives and images as readily as it fetches pages, so a [Reply] carries
/// the bytes, the text and the headers, and reading them is [Reply.parse]
/// plus a codec from `format`:
///
/// ```dart
/// res.parse(format.html).find('h1').text;
/// res.parse(format.json).at('data.items');
/// ```
///
/// URLs are always [Uri] values, matching `package:http`; the [UrlString.url]
/// extension keeps call sites short.
library;

import 'dart:async';

import '../collection/sequence.dart';
import 'crawl.dart';
import 'http.dart';
import 'robots.dart';
import 'serve.dart';
import 'serve.dart' as serve_impl;
import 'sitemap.dart';

export 'cache.dart';
export 'crawl.dart';
export 'downloader.dart';
export 'engine.dart';
export 'form.dart';
export 'http.dart';
export 'pipeline.dart';
export 'robots.dart';
export 'serve.dart' hide onceOn, serveOn;
export 'sitemap.dart';

// ============================================================================
// NET DOMAIN (net.*) - HTTP, Crawler Engine & Selectors
// ============================================================================

Fetcher _shared = Fetcher();

/// The `net` domain: HTTP, crawling and listening.
const NetAccessor net = NetAccessor();

/// Entry point for networking and scraping.
///
/// Requests go through [http], a shared [Fetcher]; crawls through [crawl].
/// Reading what comes back is `format`, through [Reply.parse]. For a client of
/// your own, construct a [Fetcher] and hand it to [use].
///
/// ```dart
/// final res = await net.http.get('https://example.com'.url);
/// for (final title in res.parse(format.html).find('h2.title').texts.list) {
///   print(title);
/// }
/// ```
class NetAccessor {
  /// Creates the accessor. Prefer the shared [net] instance.
  const NetAccessor();

  /// The shared HTTP client: requests, downloads and [Fetcher.sync].
  Fetcher get http => _shared;

  /// The crawler entry point. See [Crawl].
  Crawl get crawl => const Crawl();

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
  /// Pass `port: 0` to let the OS pick a free one and read [Server.port] back.
  /// [host] defaults to `localhost`, so nothing is exposed off the machine
  /// until a script asks for it — pass `'0.0.0.0'` when it should be.
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
  /// `once` beside [serve] is the same pairing as `io.csv.pipe` beside
  /// `write`: different behaviour, not an alias.
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

  /// Parses robots.txt content into a [Robots] evaluator.
  Robots robots(String content) => Robots.parse(content);

  /// Parses a sitemap XML or text content into the [Uri]s it names.
  Sequence<Uri> sitemap(String content) => Sitemap.parse(content);

  /// Replaces the client returned by [http], closing the previous one.
  ///
  /// Useful in tests, and for applying one set of headers process-wide. Pass
  /// `close: false` to keep the old client open.
  Future<void> use(Fetcher client, {bool close = true}) async {
    final previous = _shared;
    _shared = client;
    if (close && !identical(previous, client)) await previous.close();
  }
}
