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

/// URL deduplication filter.
class Deduplicator {
  final Set<String> _visited = <String>{};

  /// Creates a [Deduplicator].
  Deduplicator();

  /// Number of unique URLs tracked.
  int get length => _visited.length;

  /// Whether no URLs have been tracked yet.
  bool get isEmpty => _visited.isEmpty;

  /// Whether URLs have been tracked.
  bool get isNotEmpty => _visited.isNotEmpty;

  /// Checks whether [url] has already been seen (1-word).
  bool has(Object url) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return _visited.contains(_norm(uri));
  }

  /// Adds [url] to the deduplicator. Returns `true` if newly added, `false` if already seen (1-word).
  bool add(Object url) {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    return _visited.add(_norm(uri));
  }

  /// Clears the history of visited URLs (1-word).
  void clear() => _visited.clear();

  static String _norm(Uri uri) {
    final n = uri.removeFragment();
    var p = n.path;
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return n.replace(path: p).toString();
  }
}

/// Request queue inspection and manipulation namespace (`engine.queue.*`).
class QueueAccess<T> {
  final Engine<T> _engine;

  /// Creates a queue accessor bound to the given [Engine].
  QueueAccess(this._engine);

  /// Number of pending requests currently queued.
  int get length => _engine.queueLength;

  /// Whether the request queue is currently empty.
  bool get isEmpty => _engine.queueLength == 0;

  /// Whether the request queue contains pending requests.
  bool get isNotEmpty => _engine.queueLength > 0;

  /// Clears all pending requests from the queue (1-word).
  void clear() => _engine.clearQueue();

  /// Enqueues a URL or [Request] into the engine (1-word).
  void add(Object requestOrUrl) => _engine.add(requestOrUrl);
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

  /// Internal dispatch for unhandled worker errors.
  void dispatch(Object error, StackTrace stack) => _error?.call(error, stack);
}

/// Multi-stage, concurrent web crawler engine.
///
/// Coordinates requests, deduplication, downloader workers, and response processing.
/// The downloader controls concurrency and rate-limiting delays, pulling requests
/// from the engine as needed.
class Engine<T> {
  /// The downloader component responsible for executing HTTP requests and saving files.
  final Downloader<T> downloader;

  /// The URL deduplication tracker.
  final Deduplicator deduplicator;

  /// Default response processor callback if no router match is found.
  final Process<T> processor;

  /// Whether URL deduplication is enabled.
  final bool dedupe;

  final List<Request<T>> _queue = [];
  final StreamController<T> _items = StreamController<T>.broadcast();
  final Stats _stats = Stats();

  bool _running = false;
  bool _stopped = false;
  int active = 0;

  /// Sub-namespace for queue inspection and manipulation.
  late final QueueAccess<T> queue = QueueAccess<T>(this);

  /// Sub-namespace for crawler lifecycle event listeners (`engine.on.*`).
  late final EngineEvents<T> on = EngineEvents<T>(this);

  /// Sub-namespace for routing responses by URL pattern, tag, or status code.
  late final Router<T> router = Router<T>()..attach(this);

  /// Concurrency level determined by the [downloader].
  int get concurrency => downloader.concurrency;

  /// Rate-limiting delay determined by the [downloader].
  Duration get delay => downloader.delay;

  /// Creates a new crawler [Engine].
  Engine({
    Downloader<T>? downloader,
    Deduplicator? deduplicator,
    Process<T>? onResponse,
    Router<T>? processor,
    int? concurrency,
    Duration? delay,
    String? base,
    this.dedupe = true,
  }) : downloader =
           downloader ??
           HttpDownloader<T>(
             concurrency: concurrency ?? 1,
             delay: delay ?? Duration.zero,
             base: base,
           ),
       deduplicator = deduplicator ?? Deduplicator(),
       processor = processor != null
           ? processor.call
           : (onResponse ?? ((res, eng) async {})) {
    if (concurrency != null) {
      this.downloader.concurrency = concurrency;
    }
    if (delay != null) {
      this.downloader.delay = delay;
    }
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

  /// Whether all workers are idle and the queue is empty.
  bool get idle => active == 0 && _queue.isEmpty;

  /// Current number of pending requests in queue.
  int get queueLength => _queue.length;

  /// Clears pending requests from queue (1-word).
  void clearQueue() => _queue.clear();

  /// Serves the next pending request from the queue, or `null` if empty (1-word).
  Request<T>? serve() {
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }

  /// Enqueues a URL or [Request] into the engine queue (1-word).
  void add(Object requestOrUrl) {
    final req = requestOrUrl is Request<T>
        ? requestOrUrl
        : Request<T>.get(requestOrUrl);

    if (dedupe && !deduplicator.add(req.url)) {
      return;
    }

    req.engine = this;
    _queue.add(req);
    _stats.scheduled++;
  }

  /// Schedules a GET request with an optional [tag] and [meta] context payload (1-word).
  void get(Object url, {String? tag, Map<String, Object?>? meta}) =>
      add(Request<T>.get(url, tag: tag, meta: meta));

  /// Schedules a POST request with an optional [body], [tag], and [meta] payload (1-word).
  void post(
    Object url, {
    Object? body,
    String? tag,
    Map<String, Object?>? meta,
  }) => add(Request<T>.post(url, body: body, tag: tag, meta: meta));

  /// Downloads a [Request] or URL directly using the engine's downloader (1-word).
  Future<Response<T>> download(Object req) => downloader.download(req);

  /// Downloads [source] URL and saves it directly to local [dest] path (1-word).
  Future<void> save(Object dest, Object source) =>
      downloader.save(dest, source);

  /// Registers a URL pattern route matching regular expressions or substrings (1-word).
  void route(
    Pattern pattern,
    FutureOr<void> Function(Response<T> res) handler,
  ) {
    router.on(pattern, (res, engine) => handler(res));
  }

  /// Registers a tagged route handler (1-word).
  void tag(String name, FutureOr<void> Function(Response<T> res) handler) {
    router.tag(name, (res, engine) => handler(res));
  }

  /// Processes a downloaded [response] through routing rules or processor.
  Future<void> process(Response<T> response) async {
    _stats.bytes += response.bytes.length;
    response.engine = this;

    if (on._response != null) {
      await on._response!(response, this);
    } else if (router.isNotEmpty) {
      final matched = await router.handle(response, this);
      if (!matched) {
        await processor(response, this);
      }
    } else {
      await processor(response, this);
    }
    _stats.completed++;
    on._progress?.call(response);
  }

  /// Emits an extracted [item] to the broadcast stream and `engine.on.item` listeners (1-word).
  void emit(T item) {
    _items.add(item);
    _stats.emitted++;
    on._item?.call(item);
  }

  /// Signals all active workers to stop crawling (1-word).
  void stop([String reason = 'Stopped by user']) {
    _stopped = true;
    _stats.reason = reason;
  }

  /// Starts the crawler engine, processing [initialUrls] if supplied (1-word).
  Future<Stats> run([Iterable<Object>? initialUrls]) async {
    if (_running) throw StateError('Engine is already running');
    _running = true;
    _stopped = false;
    _stats.start = DateTime.now();

    downloader.attach(this);

    if (initialUrls != null) {
      for (final u in initialUrls) {
        add(u);
      }
    }

    on._start?.call();

    // Downloader manages workers and pulls requests from engine.serve()
    await downloader.work(this);

    _stats.end = DateTime.now();
    _running = false;

    on._done?.call(_stats);
    await _items.close();
    await downloader.close();

    return _stats;
  }
}
