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

  /// Starts a crawler builder for [urls].
  ///
  /// Configure execution options via fluent builder methods (`concurrent`, `delay`, `base`, `tag`):
  /// ```dart
  /// await crawl('https://example.com')
  ///   .concurrent(4)
  ///   .delay(Duration(milliseconds: 100))
  ///   .run((res) {
  ///     for (final link in res.links()) {
  ///       res.follow(link);
  ///     }
  ///   });
  /// ```
  CrawlBuilder<T> call<T>([
    dynamic urls,
    FutureOr<void> Function(Response<T> res)? process,
  ]) =>
      CrawlBuilder<T>(urls, process);

  /// Starts a crawler builder configured with maximum [count] concurrent workers (1-word).
  CrawlBuilder<T> concurrent<T>(int count) =>
      CrawlBuilder<T>().concurrent(count);

  /// Starts a crawler builder configured with polite request [delay] (1-word).
  CrawlBuilder<T> delay<T>(dynamic delay) => CrawlBuilder<T>().delay(delay);

  /// Starts a crawler builder configured with base storage directory (1-word).
  CrawlBuilder<T> base<T>(String baseFolder) =>
      CrawlBuilder<T>().base(baseFolder);

  /// Runs an end-to-end crawling workflow on [urls] and returns [Stats] (1-word).
  Future<Stats> run<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res)? process, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
    Map<String, FutureOr<void> Function(Response<T> res)>? tags,
    Map<dynamic, FutureOr<void> Function(Response<T> res)>? routes,
  }) {
    var b = call<T>(urls, process)
        .concurrent(concurrency)
        .delay(delay)
        .dedupe(dedupe);
    if (base != null) b.base(base);
    if (dl != null) b = b.dl(dl);
    if (scheduler != null) b = b.scheduler(scheduler);
    if (tags != null) b.tags(tags);
    if (routes != null) b.routes(routes);
    return b.run(process);
  }

  /// Runs a crawling session and collects all emitted items via `res.emit(item)` into a list.
  Future<List<T>> collect<T>(
    dynamic urls,
    FutureOr<void> Function(Response<T> res)? process, {
    int concurrency = 4,
    Duration delay = Duration.zero,
    String? base,
    bool dedupe = true,
    Downloader<T>? dl,
    Scheduler<T>? scheduler,
    Map<String, FutureOr<void> Function(Response<T> res)>? tags,
    Map<dynamic, FutureOr<void> Function(Response<T> res)>? routes,
  }) {
    var b = call<T>(urls, process)
        .concurrent(concurrency)
        .delay(delay)
        .dedupe(dedupe);
    if (base != null) b.base(base);
    if (dl != null) b = b.dl(dl);
    if (scheduler != null) b = b.scheduler(scheduler);
    if (tags != null) b.tags(tags);
    if (routes != null) b.routes(routes);
    return b.collect<T>(process);
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

/// Fluent builder for configuring and executing web crawling workflows.
///
/// Implements [Future<Stats>] so that configurations can be directly awaited:
/// ```dart
/// await crawl(url, (res) { ... });
/// ```
/// Or chained using builder pattern methods (`concurrent`, `delay`, `base`, `tag`)
/// where execution arguments are the function for process only:
/// ```dart
/// await crawl(url)
///   .concurrent(4)
///   .delay(Duration(milliseconds: 100))
///   .run((res) {
///     ...
///   });
/// ```
class CrawlBuilder<T> implements Future<Stats> {
  dynamic _urls;
  final FutureOr<void> Function(Response<T> res)? _process;
  int _concurrency = 4;
  Duration _delay = Duration.zero;
  String? _base;
  bool _dedupe = true;
  Downloader<T>? _dl;
  Scheduler<T>? _scheduler;
  final Map<String, FutureOr<void> Function(Response<T> res)> _tags = {};
  final Map<dynamic, FutureOr<void> Function(Response<T> res)> _routes = {};

  void Function()? _onStart;
  void Function(Stats stats)? _onDone;
  void Function(T item)? _onItem;
  void Function(Response<T> res)? _onProgress;
  void Function(Object error, StackTrace stack)? _onError;

  Future<Stats>? _executed;

  /// Creates a crawler builder for [urls] with optional default [process] function.
  CrawlBuilder([this._urls, this._process]);

  /// Sets or replaces the target URL(s) to crawl.
  CrawlBuilder<T> urls(dynamic urls) {
    _urls = urls;
    return this;
  }

  /// Sets maximum concurrent workers (1-word).
  CrawlBuilder<T> concurrent(int count) {
    _concurrency = count > 0 ? count : 1;
    return this;
  }

  /// Sets polite rate-limiting delay between requests (1-word).
  ///
  /// Accepts a [Duration] or integer milliseconds.
  CrawlBuilder<T> delay(dynamic delay) {
    if (delay is Duration) {
      _delay = delay;
    } else if (delay is num) {
      _delay = Duration(milliseconds: delay.toInt());
    }
    return this;
  }

  /// Sets base storage folder for relative file downloads (1-word).
  CrawlBuilder<T> base(String folder) {
    _base = folder;
    return this;
  }

  /// Sets custom [Downloader] instance (1-word).
  CrawlBuilder<R> dl<R>(Downloader<R> downloader) {
    final b = CrawlBuilder<R>(_urls, _process as FutureOr<void> Function(Response<R> res)?);
    b._concurrency = _concurrency;
    b._delay = _delay;
    b._base = _base;
    b._dedupe = _dedupe;
    b._dl = downloader;
    b._scheduler = _scheduler as Scheduler<R>?;
    b._tags.addAll(_tags.cast());
    b._routes.addAll(_routes.cast());
    b._onStart = _onStart;
    b._onDone = _onDone;
    b._onProgress = _onProgress as void Function(Response<R> res)?;
    b._onError = _onError;
    return b;
  }

  /// Sets custom [Scheduler] instance (1-word).
  CrawlBuilder<R> scheduler<R>(Scheduler<R> scheduler) {
    final b = CrawlBuilder<R>(_urls, _process as FutureOr<void> Function(Response<R> res)?);
    b._concurrency = _concurrency;
    b._delay = _delay;
    b._base = _base;
    b._dedupe = _dedupe;
    b._dl = _dl as Downloader<R>?;
    b._scheduler = scheduler;
    b._tags.addAll(_tags.cast());
    b._routes.addAll(_routes.cast());
    b._onStart = _onStart;
    b._onDone = _onDone;
    b._onProgress = _onProgress as void Function(Response<R> res)?;
    b._onError = _onError;
    return b;
  }

  /// Enables or disables URL deduplication (1-word).
  CrawlBuilder<T> dedupe([bool enabled = true]) {
    _dedupe = enabled;
    return this;
  }

  /// Registers a handler for requests tagged with [name] (1-word).
  CrawlBuilder<T> tag(String name, FutureOr<void> Function(Response<T> res) handler) {
    _tags[name] = handler;
    return this;
  }

  /// Registers multiple tag handlers (1-word).
  CrawlBuilder<T> tags(Map<String, FutureOr<void> Function(Response<T> res)> tags) {
    _tags.addAll(tags);
    return this;
  }

  /// Registers a handler matching URL [pattern] (1-word).
  CrawlBuilder<T> route(Pattern pattern, FutureOr<void> Function(Response<T> res) handler) {
    _routes[pattern] = handler;
    return this;
  }

  /// Registers multiple route handlers (1-word).
  CrawlBuilder<T> routes(Map<dynamic, FutureOr<void> Function(Response<T> res)> routes) {
    _routes.addAll(routes);
    return this;
  }

  /// Sub-namespace for crawler lifecycle event subscriptions (`builder.on.*`).
  late final CrawlEvents<T> on = CrawlEvents<T>(this);

  /// Executes the crawl. The argument is the function for process only.
  Future<Stats> run([FutureOr<void> Function(Response<T> res)? process]) {
    if (_executed != null) return _executed!;
    final handler = process ?? _process;
    final eng = Engine<T>(
      concurrency: _concurrency,
      delay: _delay,
      downloader: _dl ?? HttpDownloader<T>(base: _base),
      scheduler: _scheduler ?? Scheduler<T>(dedupe: _dedupe),
      onResponse: handler != null ? (res, engine) => handler(res) : null,
    );

    for (final entry in _tags.entries) {
      eng.tag(entry.key, entry.value);
    }
    for (final entry in _routes.entries) {
      eng.route(entry.key, entry.value);
    }

    if (_onStart != null) eng.on.start(_onStart!);
    if (_onDone != null) eng.on.done(_onDone!);
    if (_onItem != null) eng.on.item(_onItem!);
    if (_onProgress != null) eng.on.progress(_onProgress!);
    if (_onError != null) eng.on.error(_onError!);

    final reqs = Crawl._normalizeUrls<T>(_urls);
    return _executed = eng.run(reqs);
  }

  /// Alias for [run] where the argument is the function for process only.
  Future<Stats> process(FutureOr<void> Function(Response<T> res) process) =>
      run(process);

  /// Callable shortcut: `builder(process)`.
  Future<Stats> call([FutureOr<void> Function(Response<T> res)? process]) =>
      run(process);

  /// Executes the crawl and collects emitted items. The argument is the function for process only.
  Future<List<I>> collect<I>([FutureOr<void> Function(Response<T> res)? process]) async {
    final items = <I>[];
    final orig = _onItem;
    _onItem = (item) {
      if (item is I) items.add(item);
      orig?.call(item);
    };
    await run(process);
    return items;
  }

  // Future<Stats> implementation
  Future<Stats> get _future => run();

  @override
  Stream<Stats> asStream() => _future.asStream();

  @override
  Future<Stats> catchError(Function onError, {bool Function(Object error)? test}) =>
      _future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(Stats value) onValue, {Function? onError}) =>
      _future.then(onValue, onError: onError);

  @override
  Future<Stats> timeout(Duration timeLimit, {FutureOr<Stats> Function()? onTimeout}) =>
      _future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<Stats> whenComplete(FutureOr<void> Function() action) =>
      _future.whenComplete(action);
}

/// Event subscription namespace for crawler builder events (`builder.on.*`).
class CrawlEvents<T> {
  final CrawlBuilder<T> _builder;

  CrawlEvents(this._builder);

  /// Registers a callback triggered when crawling begins.
  void start(void Function() handler) => _builder._onStart = handler;

  /// Registers a callback triggered when all requests finish.
  void done(void Function(Stats stats) handler) => _builder._onDone = handler;

  /// Registers a callback triggered each time an item is emitted via `res.emit(item)`.
  void item(void Function(T item) handler) => _builder._onItem = handler;

  /// Registers a callback triggered after each response is processed.
  void progress(void Function(Response<T> res) handler) =>
      _builder._onProgress = handler;

  /// Registers a callback triggered when an error occurs.
  void error(void Function(Object error, StackTrace stack) handler) =>
      _builder._onError = handler;
}
