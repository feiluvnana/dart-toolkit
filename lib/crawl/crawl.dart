import 'dart:async';

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

/// Crawler namespace accessor (`crawl.run(...)`, `crawl.collect(...)`, `crawl.engine()`, `crawl.dl()`).
class CrawlAccessor {
  const CrawlAccessor();

  /// Create a new crawling engine (1-word).
  Engine<T> engine<T>({
    int concurrency = 1,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
    Process<T>? onResponse,
  }) =>
      Engine<T>(
        concurrency: concurrency,
        delay: delay,
        downloader: dl ?? HttpDownloader<T>(base: base),
        scheduler: scheduler ?? Scheduler<T>(dedupe: dedupe),
        onResponse: onResponse,
      );

  /// Run an end-to-end crawling workflow on URLs and return Stats (1-word).
  Future<Stats> run<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res) handler, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
  }) async {
    final eng = Engine<T>(
      concurrency: concurrency,
      delay: delay,
      downloader: dl ?? HttpDownloader<T>(base: base),
      scheduler: scheduler ?? Scheduler<T>(dedupe: dedupe),
      onResponse: (res, engine) => handler(res),
    );
    final list = urls is Iterable ? urls : [urls];
    return eng.run(list);
  }

  /// Run crawling workflow and collect all items emitted via res.emit(item) (1-word).
  Future<List<T>> collect<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res) handler, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
  }) async {
    final items = <T>[];
    final eng = Engine<T>(
      concurrency: concurrency,
      delay: delay,
      downloader: dl ?? HttpDownloader<T>(base: base),
      scheduler: scheduler ?? Scheduler<T>(dedupe: dedupe),
      onResponse: (res, engine) => handler(res),
    );
    eng.on.item((item) => items.add(item));
    final list = urls is Iterable ? urls : [urls];
    await eng.run(list);
    return items;
  }

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
