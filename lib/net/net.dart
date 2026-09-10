/// # Net Domain (`net.*`)
///
/// HTTP requests and downloads (`net.http`), the crawler engine
/// (`net.crawl`), the forms a page carries ([Form]), and jQuery-like CSS
/// selectors (the top-level [$]).
///
/// URLs are always [Uri] values, matching `package:http`; the [UrlString.url]
/// extension keeps call sites short.
library;

import 'dart:async';

import 'crawl.dart';
import 'http.dart';
import 'robots.dart';
import 'selector.dart' as selector_impl;
import 'selector.dart';
import 'sitemap.dart';

export 'cache.dart';
export 'crawl.dart';
export 'downloader.dart';
export 'engine.dart';
export 'form.dart';
export 'http.dart';
export 'pipeline.dart';
export 'robots.dart';
export 'selector.dart' hide $, $xpath, JQuerySelector;
export 'sitemap.dart';

// ============================================================================
// NET DOMAIN (net.*) - HTTP, Crawler Engine & Selectors
// ============================================================================

HttpClient _shared = HttpClient();

/// The `net` domain: HTTP, crawling and selectors.
const NetAccessor net = NetAccessor();

/// Entry point for networking and scraping.
///
/// Requests go through [http], a shared [HttpClient]; crawls through [crawl].
/// Selectors can be run via [net.$] or [net.$xpath], on response bodies with
/// `res.$`, or by importing `package:dart_toolkit/selector.dart`.
/// For a client of your own, construct an [HttpClient] and hand it to [use].
///
/// ```dart
/// final res = await net.http.get('https://example.com'.url);
/// for (final title in res.$('h2.title').texts) print(title);
/// ```
class NetAccessor {
  /// Creates the accessor. Prefer the shared [net] instance.
  const NetAccessor();

  /// The shared HTTP client: requests, downloads and [HttpClient.sync].
  HttpClient get http => _shared;

  /// The crawler entry point. See [Crawl].
  Crawl get crawl => const Crawl();

  /// Parses [markup] into a queryable [QueryResult].
  QueryResult $(String markup, [String? selector]) =>
      selector_impl.$(markup, selector);

  /// Parses [markup] into a queryable [QueryResult] for XPath queries.
  QueryResult $xpath(String markup, [String? query]) =>
      selector_impl.$xpath(markup, query);

  /// Parses robots.txt content into a [Robots] evaluator.
  Robots robots(String content) => Robots.parse(content);

  /// Parses a sitemap XML or text content into a list of [Uri]s.
  List<Uri> sitemap(String content) => Sitemap.parse(content);

  /// Replaces the client returned by [http], closing the previous one.
  ///
  /// Useful in tests, and for applying one set of headers process-wide. Pass
  /// `close: false` to keep the old client open.
  Future<void> use(HttpClient client, {bool close = true}) async {
    final previous = _shared;
    _shared = client;
    if (close && !identical(previous, client)) await previous.close();
  }
}
