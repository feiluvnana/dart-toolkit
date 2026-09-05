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
///
/// Provides high-level entry points for web crawling, asset downloading,
/// and jQuery-style DOM parsing:
/// ```dart
/// // End-to-end crawling workflow
/// await crawl.run('https://example.com', (res) {
///   for (final link in res.$('a').links()) {
///     res.follow(link);
///   }
/// });
///
/// // Collect extracted models
/// final songs = await crawl.collect('https://example.com/album', (res) {
///   for (final title in res.$('.song-title').texts) {
///     res.emit(title);
///   }
/// });
///
/// // Declarative multi-stage crawler engine
/// final app = crawl.engine(concurrency: 4);
/// app.route(RegExp(r'/article/\d+'), (res) => ...);
/// await app.run(['https://example.com']);
/// ```
const CrawlAccessor crawl = CrawlAccessor();

/// Crawler namespace accessor (`crawl.run(...)`, `crawl.collect(...)`, `crawl.engine()`, `crawl.dl()`).
class CrawlAccessor {
  const CrawlAccessor();

  /// Creates a configurable, multi-stage crawler [Engine].
  ///
  /// The returned [Engine] manages concurrency, rate limiting, request scheduling,
  /// routing, and downloader pipelines.
  ///
  /// ```dart
  /// final app = crawl.engine(
  ///   concurrency: 4,
  ///   delay: Duration(milliseconds: 250),
  ///   base: 'downloads/',
  /// );
  ///
  /// app.tag('album', (res) {
  ///   res.follow(res.$('a.track').links(), tag: 'track');
  /// });
  ///
  /// app.tag('track', (res) {
  ///   res.save('audio.mp3', res.$('source').src());
  /// });
  ///
  /// app.get('https://music.example.com/albums', tag: 'album');
  /// await app.run();
  /// ```
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

  /// Runs an end-to-end crawling workflow on [urls] and returns [Stats].
  ///
  /// Automatically instantiates a temporary [Engine] and invokes [handler] for each
  /// response. Supports following additional URLs inside the handler via `res.follow(url)`
  /// or emitting items.
  ///
  /// ```dart
  /// final stats = await crawl.run(
  ///   ['https://example.com/page1', 'https://example.com/page2'],
  ///   (res) {
  ///     Console.info('Visited: ${res.url}');
  ///     for (final link in res.links(RegExp(r'/item/\d+'))) {
  ///       res.follow(link);
  ///     }
  ///   },
  ///   concurrency: 4,
  /// );
  /// print('Crawled ${stats.completed} pages in ${stats.elapsed.inSeconds}s');
  /// ```
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

  /// Crawls [urls] and returns a list of items emitted via `res.emit(item)`.
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

  /// Creates a standalone [HttpDownloader] instance with an optional base output directory.
  ///
  /// ```dart
  /// final dl = crawl.dl(base: 'downloads/');
  /// await dl.save('poster.jpg', 'https://example.com/img.jpg');
  /// ```
  HttpDownloader<T> dl<T>({String? base, http.Client? client}) =>
      HttpDownloader<T>(base: base, client: client);

  /// Performs a quick HTTP GET request and returns a parsed [Response].
  ///
  /// ```dart
  /// final res = await crawl.get('https://example.com/data.json');
  /// print(res.json['title']);
  /// ```
  Future<Response<T>> get<T>(
    dynamic url, {
    Map<String, String>? headers,
    http.Client? client,
  }) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return HttpDownloader<T>(client: client).get(uri, headers: headers);
  }

  /// Performs a quick HTTP POST request and returns a parsed [Response].
  ///
  /// ```dart
  /// final res = await crawl.post(
  ///   'https://httpbin.org/post',
  ///   body: {'username': 'alice'},
  /// );
  /// ```
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
  ///
  /// Returns the completed [Response] containing downloaded bytes and metadata.
  Future<Response<T>> download<T>(dynamic req, {http.Client? client}) {
    return HttpDownloader<T>(client: client).download(req);
  }

  /// Concurrently synchronizes a collection of download tasks into local files.
  ///
  /// [tasks] can be a `Map<String, String>` mapping local file paths to remote URLs,
  /// or an `Iterable` of `MapEntry` or records `({String path, String url})`.
  ///
  /// If [prefix] is provided, it is prepended to non-HTTP URLs.
  /// If [match] is true, existing non-empty files (or basename matches) are skipped.
  ///
  /// ```dart
  /// await crawl.sync(
  ///   {
  ///     'img/1.jpg': 'https://example.com/1.jpg',
  ///     'img/2.jpg': 'https://example.com/2.jpg',
  ///   },
  ///   concurrency: 4,
  /// );
  /// ```
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
  ///
  /// Returns a chainable [QueryResult] wrapping matched DOM elements.
  /// Equivalent to `$(target, context)`.
  QueryResult query(dynamic target, [dynamic context]) => sel.$(target, context);

  /// jQuery-like selector alias for [query].
  ///
  /// ```dart
  /// final headings = crawl.$('h1, h2', html).texts;
  /// ```
  QueryResult $(dynamic target, [dynamic context]) => sel.$(target, context);
}
