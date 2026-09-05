import 'package:http/http.dart' as http;

import 'downloader.dart';
import 'engine.dart';
import 'pipeline.dart';
import 'selector.dart';
import 'selector.dart' as sel;

export 'downloader.dart';
export 'engine.dart';
export 'pipeline.dart';
export 'selector.dart';

// ============================================================================
// CRAWLER & SCRAPER SUBSYSTEM (crawl.* / $())
// ============================================================================

/// Top-level web crawling and scraping accessor singleton.
const CrawlAccessor crawl = CrawlAccessor();

/// Crawler namespace accessor (`crawl.get(...)`, `crawl.sync(...)`, `crawl.engine()`, `crawl.dl()`).
class CrawlAccessor {
  const CrawlAccessor();

  /// Create a new crawling engine (1-word).
  Engine<T> engine<T>() => Engine<T>();

  /// Create a new HTTP downloader with optional base directory (1-word).
  HttpDownloader<T> dl<T>({String? base, http.Client? client}) =>
      HttpDownloader<T>(base: base, client: client);

  /// Perform a quick HTTP GET request and return Response (1-word).
  Future<Response<T>> get<T>(
    dynamic url, {
    Map<String, String>? headers,
    http.Client? client,
  }) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return HttpDownloader<T>(client: client).get(uri, headers: headers);
  }

  /// Perform a quick HTTP POST request and return Response (1-word).
  Future<Response<T>> post<T>(
    dynamic url, {
    Map<String, String>? headers,
    Object? body,
    http.Client? client,
  }) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return HttpDownloader<T>(client: client).post(uri, headers: headers, body: body);
  }

  /// Download a request or URL using default downloader (1-word).
  Future<Response<T>> download<T>(dynamic req, {http.Client? client}) {
    return HttpDownloader<T>(client: client).download(req);
  }

  /// Concurrently synchronize a map or list of assets with optional prefix & base folder (1-word).
  Future<void> sync(
    dynamic tasks, {
    String? base,
    String? prefix,
    int concurrency = 4,
    bool match = true,
  }) {
    final downloader = HttpDownloader(base: base);
    return downloader.sync(
      tasks,
      prefix: prefix,
      concurrency: concurrency,
      match: match,
    );
  }

  /// Direct jQuery-like DOM query function (1-word).
  QueryResult query(dynamic target, [dynamic context]) => sel.$(target, context);

  /// jQuery-like selector alias.
  QueryResult $(dynamic target, [dynamic context]) => sel.$(target, context);
}
