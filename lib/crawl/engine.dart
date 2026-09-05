import 'dart:async';

import 'downloader.dart';
import 'pipeline.dart';

// ============================================================================
// ENGINE & CRAWLER PIPELINE
// ============================================================================

/// Performance and progress statistics for a crawler [Engine] run.
class Stats {
  /// Total number of requests scheduled into the queue.
  int scheduled = 0;

  /// Total number of requests completed successfully.
  int completed = 0;

  /// Total number of items emitted via `res.emit(item)`.
  int emitted = 0;

  /// Total bytes downloaded during the crawl run.
  int bytes = 0;

  /// Timestamp when the crawl run started.
  DateTime? start;

  /// Timestamp when the crawl run finished.
  DateTime? end;

  /// Reason string if crawling was prematurely stopped.
  String? reason;

  /// Total elapsed duration of the crawl run.
  Duration get elapsed {
    if (start == null) return Duration.zero;
    return (end ?? DateTime.now()).difference(start!);
  }

  @override
  String toString() =>
      'Stats(completed: $completed, emitted: $emitted, elapsed: $elapsed)';
}

/// Request queue inspection and manipulation namespace (`engine.queue.*`).
class QueueAccess<T> {
  final Engine<T> _engine;

  /// Creates a queue accessor bound to the given [Engine].
  QueueAccess(this._engine);

  /// Number of pending requests currently queued in the scheduler.
  int get length => _engine.scheduler.length;

  /// Whether the request queue is currently empty.
  bool get isEmpty => _engine.scheduler.isEmpty;

  /// Whether the request queue contains pending requests.
  bool get isNotEmpty => _engine.scheduler.isNotEmpty;

  /// Clears all pending requests from the queue.
  void clear() => _engine.scheduler.clear();

  /// Enqueues a URL or [Request] into the engine.
  void add(dynamic requestOrUrl) => _engine.add(requestOrUrl);
}

/// Event subscription namespace for crawler lifecycle events (`engine.on.*`).
class EngineEvents<T> {
  /// The parent engine instance.
  final Engine<T> engine;

  /// Creates an event accessor bound to the given [Engine].
  EngineEvents(this.engine);

  void Function()? _start;
  void Function(Stats stats)? _done;
  void Function(T item)? _item;
  Process<T>? _response;
  void Function(Response<T> res)? _progress;
  void Function(Object error, StackTrace stack)? _error;

  /// Registers a callback triggered when the crawler engine starts.
  void start(void Function() handler) => _start = handler;

  /// Registers a callback triggered when the crawl finishes all tasks.
  void done(void Function(Stats stats) handler) => _done = handler;

  /// Registers a callback triggered each time an item is emitted via `res.emit(item)`.
  void item(void Function(T item) handler) => _item = handler;

  /// Registers a global response processor callback.
  void response(Process<T> handler) => _response = handler;

  /// Registers a callback triggered after each response is processed.
  void progress(void Function(Response<T> res) handler) => _progress = handler;

  /// Registers a callback triggered when a worker encounters an unhandled error.
  void error(void Function(Object error, StackTrace stack) handler) =>
      _error = handler;
}

/// Multi-stage, concurrent web crawler engine.
///
/// Features configurable concurrency, polite request rate-limiting, URL deduplication,
/// tag and regex routing, streaming item emission, and graceful shutdown.
///
/// ```dart
/// final app = Engine<Map<String, dynamic>>(concurrency: 4);
///
/// app.tag('list', (res) {
///   for (final link in res.$('.article-link').links()) {
///     res.follow(link, tag: 'detail');
///   }
/// });
///
/// app.tag('detail', (res) {
///   res.emit({
///     'title': res.$('h1').text,
///     'author': res.$('.author').text,
///   });
/// });
///
/// app.get('https://example.com/news', tag: 'list');
/// await app.run();
/// ```
class Engine<T> {
  /// The request scheduler managing queued requests and deduplication.
  final Scheduler<T> scheduler;

  /// The downloader component responsible for executing HTTP requests and saving files.
  final Downloader<T> downloader;

  /// Default response processor callback if no router match is found.
  final Process<T> processor;

  /// Maximum number of concurrent worker loops.
  final int concurrency;

  /// Delay inserted between consecutive requests per worker to ensure polite crawling.
  final Duration delay;

  final StreamController<T> _items = StreamController<T>.broadcast();
  final Stats _stats = Stats();

  bool _running = false;
  bool _stopped = false;
  int _active = 0;

  /// Sub-namespace for queue inspection and manipulation.
  late final QueueAccess<T> queue = QueueAccess<T>(this);

  /// Sub-namespace for crawler lifecycle event listeners (`engine.on.*`).
  late final EngineEvents<T> on = EngineEvents<T>(this);

  /// Sub-namespace for routing responses by URL pattern, tag, or status code.
  late final Router<T> router = Router<T>()..attach(this);

  /// Convenient getter for the configured [downloader].
  Downloader<T> get dl => downloader;

  /// Creates a new crawler [Engine].
  Engine({
    Scheduler<T>? scheduler,
    Downloader<T>? downloader,
    Process<T>? onResponse,
    Router<T>? processor,
    this.concurrency = 1,
    this.delay = Duration.zero,
  })  : scheduler = scheduler ?? Scheduler<T>(),
        downloader = downloader ?? HttpDownloader<T>(),
        processor = processor != null
            ? processor.call
            : (onResponse ?? ((res, eng) async {})) {
    this.scheduler.attach(this);
    this.downloader.attach(this);
    if (processor != null) {
      processor.attach(this);
    }
  }

  /// Crawler execution statistics.
  Stats get stats => _stats;

  /// Broadcast stream of items emitted via `res.emit(item)` or `engine.emit(item)`.
  Stream<T> get items => _items.stream;

  /// Whether the crawler is currently executing.
  bool get isRunning => _running;

  /// Whether the crawler has been stopped.
  bool get stopped => _stopped;

  /// Whether all workers are idle and the scheduler queue is empty.
  bool get isIdle => _active == 0 && scheduler.isEmpty;

  /// Registers a URL pattern route matching regular expressions or substrings.
  ///
  /// ```dart
  /// app.route(RegExp(r'/posts/\d+'), (res) {
  ///   print('Matched post: ${res.url}');
  /// });
  /// ```
  void route(Pattern pattern, FutureOr<void> Function(Response<T> res) handler) {
    router.on(pattern, (res, engine) => handler(res));
  }

  /// Registers a tagged route handler.
  ///
  /// Requests scheduled with a matching `tag` are routed directly to this handler.
  ///
  /// ```dart
  /// app.tag('album', (res) {
  ///   print('Processing album: ${res.url}');
  /// });
  /// ```
  void tag(String name, FutureOr<void> Function(Response<T> res) handler) {
    router.tag(name, (res, engine) => handler(res));
  }

  /// Enqueues a URL or [Request] into the crawl scheduler.
  void add(dynamic requestOrUrl) {
    scheduler.attach(this);
    downloader.attach(this);
    scheduler.add(requestOrUrl);
    _stats.scheduled++;
  }

  /// Alias for [add] to enqueue a URL.
  void url(dynamic url) => add(url);

  /// Schedules a GET request with an optional [tag] and [meta] context payload.
  ///
  /// ```dart
  /// app.get('https://example.com/item/1', tag: 'item', meta: {'category': 'books'});
  /// ```
  void get(dynamic url, {String? tag, Map<String, dynamic>? meta}) =>
      add(Request<T>.get(url, tag: tag, meta: meta));

  /// Schedules a POST request with an optional [body], [tag], and [meta] payload.
  void post(dynamic url, {Object? body, String? tag, Map<String, dynamic>? meta}) =>
      add(Request<T>.post(url, body: body, tag: tag, meta: meta));

  /// Downloads a [Request] or URL directly using the engine's downloader.
  Future<Response<T>> download(dynamic req) => downloader.download(req);

  /// Downloads [source] URL and saves it directly to local [dest] path.
  Future<void> save(dynamic dest, dynamic source) =>
      downloader.save(dest, source);

  /// Emits an extracted [item] to the broadcast stream and `engine.on.item` listeners.
  void emit(T item) {
    _items.add(item);
    _stats.emitted++;
    on._item?.call(item);
  }

  /// Signals all active workers to stop crawling.
  void stop([String reason = 'Stopped by user']) {
    _stopped = true;
    _stats.reason = reason;
  }

  /// Starts the crawler engine and workers, processing [initialUrls] if supplied.
  ///
  /// Blocks until the queue is exhausted or [stop] is called, returning the final [Stats].
  Future<Stats> run([Iterable<dynamic>? initialUrls]) async {
    if (_running) throw StateError('Engine is already running');
    _running = true;
    _stopped = false;
    _stats.start = DateTime.now();

    scheduler.attach(this);
    downloader.attach(this);

    if (initialUrls != null) {
      for (final u in initialUrls) {
        add(u);
      }
    }

    on._start?.call();

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(_worker());
    }

    await Future.wait(workers);

    _stats.end = DateTime.now();
    _running = false;

    on._done?.call(_stats);
    await _items.close();
    await downloader.close();

    return _stats;
  }

  Future<void> _worker() async {
    while (!_stopped) {
      final request = scheduler.next();
      if (request == null) {
        if (_active == 0) break;
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }

      _active++;
      try {
        final response = await downloader.download(request);
        _stats.bytes += response.bytes.length;
        response.engine = this;

        if (on._response != null) {
          await on._response!(response, this);
        } else if (router.isNotEmpty) {
          await router(response, this);
        } else {
          await processor(response, this);
        }
        _stats.completed++;
        on._progress?.call(response);
      } catch (e, s) {
        on._error?.call(e, s);
      } finally {
        _active--;
      }

      if (delay > Duration.zero && !_stopped) {
        await Future.delayed(delay);
      }
    }
  }
}
