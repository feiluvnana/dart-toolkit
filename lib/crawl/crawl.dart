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

/// Top-level web crawling and scraping function & namespace.
///
/// Can be invoked directly as a function for end-to-end crawling:
/// ```dart
/// // Single handler workflow
/// await crawl('https://example.com', (res) {
///   for (final link in res.$('a').links()) {
///     res.follow(link);
///   }
/// });
///
/// // Multi-stage workflow with routes and tags
/// await crawl(
///   'https://example.com',
///   tag: 'home',
///   tags: {
///     'home': (res) => res.follow('/news', tag: 'news'),
///     'news': (res) => print(res.$('h1').text),
///   },
///   concurrency: 4,
/// );
/// ```
///
/// Also provides functional sub-actions like `crawl.collect(...)`, `crawl.get(...)`,
/// `crawl.post(...)`, `crawl.sync(...)`, and `crawl.dl()`.
const Crawl crawl = Crawl();

/// Function-based crawler API callable directly as `crawl(...)`.
class Crawl {
  const Crawl();

  /// Runs an end-to-end web crawling session on [urls].
  ///
  /// Supports either a single [handler] or declarative [tags] and [routes] mappings:
  /// ```dart
  /// await crawl('https://news.ycombinator.com', (res) {
  ///   for (final a in res.$('.titleline > a')) {
  ///     print(a.text);
  ///   }
  /// });
  /// ```
  Future<Stats> call<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res)? handler, {
    String? tag,
    Map<String, dynamic>? meta,
    Map<String, FutureOr<void> Function(Response<T> res)>? tags,
    Map<dynamic, FutureOr<void> Function(Response<T> res)>? routes,
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
    void Function()? onStart,
    void Function(Stats stats)? onDone,
    void Function(T item)? onItem,
    void Function(Response<T> res)? onProgress,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    final eng = Engine<T>(
      concurrency: concurrency,
      delay: delay,
      downloader: dl ?? HttpDownloader<T>(base: base),
      scheduler: scheduler ?? Scheduler<T>(dedupe: dedupe),
      onResponse: handler != null ? (res, engine) => handler(res) : null,
    );

    if (tags != null) {
      for (final entry in tags.entries) {
        eng.tag(entry.key, entry.value);
      }
    }
    if (routes != null) {
      for (final entry in routes.entries) {
        eng.route(entry.key, entry.value);
      }
    }

    if (onStart != null) eng.on.start(onStart);
    if (onDone != null) eng.on.done(onDone);
    if (onItem != null) eng.on.item(onItem);
    if (onProgress != null) eng.on.progress(onProgress);
    if (onError != null) eng.on.error(onError);

    final reqs = _normalizeUrls<T>(urls, tag: tag, meta: meta);
    return eng.run(reqs);
  }

  /// Alias for [call] (1-word).
  Future<Stats> run<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res)? handler, {
    String? tag,
    Map<String, dynamic>? meta,
    Map<String, FutureOr<void> Function(Response<T> res)>? tags,
    Map<dynamic, FutureOr<void> Function(Response<T> res)>? routes,
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
    void Function()? onStart,
    void Function(Stats stats)? onDone,
    void Function(T item)? onItem,
    void Function(Response<T> res)? onProgress,
    void Function(Object error, StackTrace stack)? onError,
  }) =>
      call<T>(
        urls,
        handler,
        tag: tag,
        meta: meta,
        tags: tags,
        routes: routes,
        concurrency: concurrency,
        delay: delay,
        base: base,
        dedupe: dedupe,
        dl: dl,
        scheduler: scheduler,
        onStart: onStart,
        onDone: onDone,
        onItem: onItem,
        onProgress: onProgress,
        onError: onError,
      );

  /// Runs a crawling session and collects all items emitted via `res.emit(item)` into a list.
  ///
  /// ```dart
  /// final titles = await crawl.collect<String>(
  ///   'https://news.ycombinator.com',
  ///   (res) {
  ///     for (final item in res.$('.titleline > a').texts) {
  ///       res.emit(item);
  ///     }
  ///   },
  /// );
  /// ```
  Future<List<T>> collect<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res)? handler, {
    String? tag,
    Map<String, dynamic>? meta,
    Map<String, FutureOr<void> Function(Response<T> res)>? tags,
    Map<dynamic, FutureOr<void> Function(Response<T> res)>? routes,
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
    void Function()? onStart,
    void Function(Stats stats)? onDone,
    void Function(Response<T> res)? onProgress,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    final items = <T>[];
    await call<T>(
      urls,
      handler,
      tag: tag,
      meta: meta,
      tags: tags,
      routes: routes,
      concurrency: concurrency,
      delay: delay,
      base: base,
      dedupe: dedupe,
      dl: dl,
      scheduler: scheduler,
      onStart: onStart,
      onDone: onDone,
      onItem: (item) => items.add(item),
      onProgress: onProgress,
      onError: onError,
    );
    return items;
  }

  /// Creates a configurable crawler [Engine] instance.
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

  /// Creates a standalone [HttpDownloader] instance with an optional base output directory.
  HttpDownloader<T> dl<T>({String? base, http.Client? client}) =>
      HttpDownloader<T>(base: base, client: client);

  /// Performs a quick HTTP GET request and returns a parsed [Response].
  Future<Response<T>> get<T>(
    dynamic url, {
    Map<String, String>? headers,
    http.Client? client,
  }) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return HttpDownloader<T>(client: client).get(uri, headers: headers);
  }

  /// Performs a quick HTTP POST request and returns a parsed [Response].
  Future<Response<T>> post<T>(
    dynamic url, {
    Map<String, String>? headers,
    Object? body,
    http.Client? client,
  }) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return HttpDownloader<T>(client: client).post(uri, headers: headers, body: body);
  }

  /// Downloads a [Request] or URL using the default [HttpDownloader].
  Future<Response<T>> download<T>(dynamic req, {http.Client? client}) {
    return HttpDownloader<T>(client: client).download(req);
  }

  /// Concurrently synchronizes a collection of download tasks into local files.
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

  /// Queries an HTML document, element, or string using a CSS selector.
  QueryResult query(dynamic target, [dynamic context]) => sel.$(target, context);

  /// jQuery-like selector alias for [query].
  QueryResult $(dynamic target, [dynamic context]) => sel.$(target, context);

  static List<dynamic> _normalizeUrls<T>(
    dynamic urls, {
    String? tag,
    Map<String, dynamic>? meta,
  }) {
    if (urls == null) return [];
    final list = urls is Iterable ? urls.toList() : [urls];
    if (tag != null || meta != null) {
      return list.map((u) {
        if (u is Request<T>) {
          return Request<T>(
            u.url,
            method: u.method,
            headers: u.headers,
            body: u.body,
            tag: tag ?? u.tag,
            meta: meta != null ? ({...u.meta, ...meta}) : u.meta,
            priority: u.priority,
          );
        }
        return Request<T>.get(u, tag: tag, meta: meta);
      }).toList();
    }
    return list;
  }
}
