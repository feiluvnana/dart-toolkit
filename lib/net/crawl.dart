/// # Crawler Builder (`net.crawl`)
///
/// The declarative front end to [Engine]. `net.crawl(url)` returns a
/// [CrawlBuilder] you configure by chaining, then finish with [CrawlBuilder.run],
/// [CrawlBuilder.collect] or [CrawlBuilder.stream].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'downloader.dart';
import 'engine.dart';
import 'pipeline.dart';
import 'sitemap.dart';

// ============================================================================
// CRAWLER BUILDER (net.crawl)
// ============================================================================

/// Entry point for crawling, reachable as `net.crawl`.
///
/// ```dart
/// final titles = await net.crawl<String>('https://news.example.com')
///     .concurrent(4)
///     .collect((res) {
///       for (final t in res.$('.title').texts) res.emit(t);
///     });
/// ```
class Crawl {
  /// Creates the accessor. Prefer the shared `net.crawl` instance.
  const Crawl();

  /// Starts a crawl seeded with a single [target] string (e.g. URL, raw HTML, or task string).
  ///
  /// [T] is the type of item handlers [Response.emit]. Pass a [process]
  /// function here, or hand one to [CrawlBuilder.run] at the end.
  CrawlBuilder<T> call<T>(String target, [Process<T>? process]) =>
      CrawlBuilder<T>([target], process);

  /// Starts a crawl seeded with several [targets] strings.
  CrawlBuilder<T> all<T>(Iterable<String> targets, [Process<T>? process]) =>
      CrawlBuilder<T>(targets, process);

  /// Starts a crawl seeded with raw HTML [markup].
  CrawlBuilder<T> html<T>(String markup, [Process<T>? process]) {
    final uri = Uri.dataFromString(
      markup,
      mimeType: 'text/html',
      encoding: utf8,
    );
    return seed<T>([Request<T>(uri)], process);
  }

  /// Starts a crawl seeded with a local file [path].
  CrawlBuilder<T> file<T>(String path, [Process<T>? process]) {
    final uri = Uri.file(File(path).absolute.path);
    return seed<T>([Request<T>(uri)], process);
  }

  /// Starts a crawl seeded with all URLs discovered in [sitemapUrl].
  CrawlBuilder<T> sitemap<T>(Uri sitemapUrl, [Process<T>? process]) {
    final builder = CrawlBuilder<T>(const [], process);
    builder.sitemap(sitemapUrl);
    return builder;
  }

  /// Starts a crawl seeded with fully-formed [requests].
  ///
  /// Use this when seeds need their own headers, tags, priority or method.
  CrawlBuilder<T> seed<T>(
    Iterable<Request<T>> requests, [
    Process<T>? process,
  ]) {
    final builder = CrawlBuilder<T>(const [], process);
    builder._seeds.addAll(requests);
    return builder;
  }
}

/// A chainable crawl configuration.
///
/// Every setter returns the builder, so configuration reads as one expression.
/// Nothing runs until [run], [collect] or [stream] is called.
class CrawlBuilder<T> {
  final List<String> _urls;
  final List<Request<T>> _seeds = [];
  final Process<T>? _process;

  int? _concurrency;
  Duration? _delay;
  bool? _perHost;
  String? _base;
  int? _retries;
  bool _dedupe = true;
  Downloader<T>? _downloader;
  Deduplicator? _deduplicator;
  int? _limit;
  int? _depth;
  final List<Pattern> _allow = [];
  final List<Pattern> _deny = [];
  bool _sameHost = false;
  bool _robots = false;
  String _robotsUserAgent = '*';
  Uri? _sitemapUrl;
  Map<String, String>? _headers;
  Duration? _timeout;

  final List<({Pattern pattern, Process<T> handler})> _routes = [];
  final List<({String name, Process<T> handler})> _tags = [];

  final List<void Function()> _startHandlers = [];
  final List<void Function(Stats stats)> _doneHandlers = [];
  final List<void Function(T item)> _itemHandlers = [];
  final List<void Function(Response<T> response)> _progressHandlers = [];
  final List<void Function(Object error, StackTrace stack)> _errorHandlers = [];

  /// Creates a builder seeded with [urls] and an optional [_process].
  ///
  /// Prefer `net.crawl(...)` over calling this directly.
  CrawlBuilder(Iterable<String> urls, [this._process]) : _urls = urls.toList();

  /// Sets the maximum number of concurrent fetches. Minimum one.
  CrawlBuilder<T> concurrent(int count) {
    _concurrency = count > 0 ? count : 1;
    return this;
  }

  /// Sets a pause after each fetch, for politeness against a server.
  ///
  /// Set [perhost] to `true` to enforce delays per-host rather than globally.
  CrawlBuilder<T> delay(Duration duration, {bool? perhost}) {
    _delay = duration;
    if (perhost != null) _perHost = perhost;
    return this;
  }

  /// Whether politeness delay is enforced per-host rather than globally across all hosts.
  CrawlBuilder<T> perhost([bool enabled = true]) {
    _perHost = enabled;
    return this;
  }

  /// Seeds the crawl with all URLs discovered in [sitemapUrl].
  CrawlBuilder<T> sitemap(Uri sitemapUrl) {
    _sitemapUrl = sitemapUrl;
    return this;
  }

  /// Whether to obey `robots.txt` rules before fetching URLs from each host.
  CrawlBuilder<T> robots([bool enabled = true, String agent = '*']) {
    _robots = enabled;
    _robotsUserAgent = agent;
    return this;
  }

  /// Sets the base directory that relative save paths resolve against.
  CrawlBuilder<T> base(String folder) {
    _base = folder;
    return this;
  }

  /// Sets how many times a failed fetch is retried.
  CrawlBuilder<T> retry(int count) {
    _retries = count >= 0 ? count : 0;
    return this;
  }

  /// Enables or disables URL de-duplication. Enabled by default.
  CrawlBuilder<T> dedupe([bool enabled = true]) {
    _dedupe = enabled;
    return this;
  }

  /// Supplies a pre-seeded [Deduplicator], e.g. one restored from disk.
  CrawlBuilder<T> deduplicator(Deduplicator deduplicator) {
    _deduplicator = deduplicator;
    return this;
  }

  /// Supplies the [Downloader] that fetches requests.
  ///
  /// Pass a fixture-backed downloader to test a pipeline without network
  /// access.
  CrawlBuilder<T> downloader(Downloader<T> downloader) {
    _downloader = downloader;
    return this;
  }

  /// Limits the total number of pages crawled before stopping.
  CrawlBuilder<T> limit(int count) {
    _limit = count > 0 ? count : 1;
    return this;
  }

  /// Limits the maximum link depth to crawl.
  CrawlBuilder<T> depth(int depth) {
    _depth = depth >= 0 ? depth : 0;
    return this;
  }

  /// Adds an allowed URL pattern. If specified, only matching URLs are crawled.
  CrawlBuilder<T> allow(Pattern pattern) {
    _allow.add(pattern);
    return this;
  }

  /// Adds a denied URL pattern. Matching URLs are ignored.
  CrawlBuilder<T> deny(Pattern pattern) {
    _deny.add(pattern);
    return this;
  }

  /// Restricts link following to the host of the initial seed URL.
  CrawlBuilder<T> samehost([bool enabled = true]) {
    _sameHost = enabled;
    return this;
  }

  /// Sets headers sent with every request in this crawl.
  CrawlBuilder<T> headers(Map<String, String> headers) {
    _headers = headers;
    return this;
  }

  /// Sets the request timeout for this crawl.
  CrawlBuilder<T> timeout(Duration timeout) {
    _timeout = timeout;
    return this;
  }

  /// Routes responses whose URL matches [pattern] to [handler].
  CrawlBuilder<T> route(Pattern pattern, Process<T> handler) {
    _routes.add((pattern: pattern, handler: handler));
    return this;
  }

  /// Routes responses tagged [name] to [handler].
  ///
  /// Tags are how a multi-stage crawl keeps its stages apart:
  /// `res.follow(href, tag: 'detail')` sends that page to `tag('detail', ...)`.
  CrawlBuilder<T> tag(String name, Process<T> handler) {
    _tags.add((name: name, handler: handler));
    return this;
  }

  /// Lifecycle handlers for the run.
  late final CrawlEvents<T> on = CrawlEvents<T>(this);

  /// Builds the configured engine without running it.
  ///
  /// Useful when you want to inspect [Engine.stats] or drive the engine
  /// yourself; [run] and [collect] call this for you.
  Engine<T> engine([Process<T>? process]) {
    final Downloader<T> dl;
    final bool owns;

    if (_downloader != null) {
      dl = _downloader!;
      owns = false;
      if (_concurrency != null) dl.concurrency = _concurrency!;
      if (_delay != null) dl.delay = _delay!;
      if (_perHost != null) dl.perhost = _perHost!;
      if (_base != null) dl.base = _base;
      if (_retries != null) dl.retries = _retries!;
    } else {
      owns = true;
      dl = HttpDownloader<T>(
        headers: _headers,
        timeout: _timeout,
        concurrency: _concurrency ?? 4,
        delay: _delay ?? Duration.zero,
        perhost: _perHost ?? false,
        base: _base,
        retries: _retries ?? 2,
      );
    }

    final engine = Engine<T>(
      downloader: dl,
      owns: owns,
      deduplicator: _deduplicator,
      dedupe: _dedupe,
      process: process ?? _process,
      limit: _limit,
      depth: _depth,
      allow: _allow,
      deny: _deny,
      samehost: _sameHost,
      obey: _robots,
      agent: _robotsUserAgent,
    );

    for (final route in _routes) {
      engine.router.on(route.pattern, route.handler);
    }
    for (final tag in _tags) {
      engine.router.tag(tag.name, tag.handler);
    }

    for (final h in _startHandlers) {
      engine.on.start(h);
    }
    for (final h in _doneHandlers) {
      engine.on.done(h);
    }
    for (final h in _itemHandlers) {
      engine.on.item(h);
    }
    for (final h in _progressHandlers) {
      engine.on.progress(h);
    }
    for (final h in _errorHandlers) {
      engine.on.error(h);
    }

    for (final seed in _seeds) {
      engine.add(seed);
    }
    return engine;
  }

  Future<List<String>> _resolveUrls() async {
    final urls = List<String>.from(_urls);
    if (_sitemapUrl != null) {
      final sitemapUrls = await Sitemap.load(_sitemapUrl!);
      urls.addAll(sitemapUrls.map((u) => u.toString()));
    }
    return urls;
  }

  /// Runs the crawl and returns its [Stats].
  ///
  /// [process] handles responses no [route] or [tag] matched, overriding any
  /// function given to `net.crawl(...)`.
  Future<Stats> run([Process<T>? process]) async {
    final urls = await _resolveUrls();
    return engine(process).run(urls);
  }

  /// Runs the crawl and collects everything handlers emitted.
  ///
  /// Items arrive in emission order. For a large crawl prefer [stream], which
  /// does not hold every item in memory.
  Future<List<T>> collect([Process<T>? process]) async {
    final items = <T>[];
    final engine = this.engine(process);
    final subscription = engine.items.listen(items.add);
    try {
      final urls = await _resolveUrls();
      await engine.run(urls);
    } finally {
      await subscription.cancel();
    }
    return items;
  }

  /// Runs the crawl and writes emitted items to [sinkOrPath] as they arrive.
  ///
  /// Accepts a file path string or an [IOSink]. Maps and Lists are written as
  /// JSON lines. Nothing is held in memory, so this is what a long crawl wants
  /// where [collect] would not fit.
  Future<Stats> save(Object sinkOrPath, [Process<T>? process]) async {
    final IOSink sink;
    final bool ownsSink;
    if (sinkOrPath is String) {
      final file = File(sinkOrPath);
      sink = file.openWrite();
      ownsSink = true;
    } else if (sinkOrPath is IOSink) {
      sink = sinkOrPath;
      ownsSink = false;
    } else {
      throw ArgumentError.value(
        sinkOrPath,
        'sinkOrPath',
        'Must be a String path or IOSink',
      );
    }

    final engine = this.engine(process);
    engine.on.item((item) {
      if (item is Map || item is List) {
        sink.writeln(jsonEncode(item));
      } else {
        sink.writeln(item.toString());
      }
    });

    try {
      final stats = await engine.run(await _resolveUrls());
      await sink.flush();
      return stats;
    } finally {
      if (ownsSink) await sink.close();
    }
  }

  /// Runs the crawl and yields items as handlers emit them.
  ///
  /// The stream closes when the crawl finishes. Use this instead of [collect]
  /// when the result set is large or you want to process items as they arrive.
  Stream<T> stream([Process<T>? process]) {
    final engine = this.engine(process);
    late final StreamController<T> controller;
    controller = StreamController<T>(
      // A consumer that stops listening ends the crawl instead of leaving it
      // fetching pages nothing will read.
      onCancel: () => engine.stop('Stream cancelled'),
    );
    final subscription = engine.items.listen(controller.add);
    _resolveUrls().then((urls) {
      engine
          .run(urls)
          .then((_) => null, onError: controller.addError)
          .whenComplete(() async {
            await subscription.cancel();
            if (!controller.isClosed) await controller.close();
          });
    }, onError: controller.addError);
    return controller.stream;
  }
}

/// Lifecycle handlers for a [CrawlBuilder], reachable as `builder.on`.
class CrawlEvents<T> {
  final CrawlBuilder<T> _builder;

  /// Wraps [_builder].
  const CrawlEvents(this._builder);

  /// Called once before the first request is fetched.
  void start(void Function() handler) => _builder._startHandlers.add(handler);

  /// Called once after the crawl finishes, with the final [Stats].
  void done(void Function(Stats stats) handler) =>
      _builder._doneHandlers.add(handler);

  /// Called for each item a handler emits.
  void item(void Function(T item) handler) =>
      _builder._itemHandlers.add(handler);

  /// Called after each response is processed.
  void progress(void Function(Response<T> response) handler) =>
      _builder._progressHandlers.add(handler);

  /// Called when a fetch or handler throws.
  ///
  /// Without a handler, errors are swallowed so one bad page cannot end the
  /// crawl; register this to see them.
  void error(void Function(Object error, StackTrace stack) handler) =>
      _builder._errorHandlers.add(handler);
}
