/// # Crawler Engine
///
/// The [Engine] owns the frontier: it schedules [Request]s, de-duplicates
/// them, hands them to a [Downloader], and routes each [Response] to a
/// handler that may schedule more.
library;

import 'dart:async';
import 'dart:collection';

import 'package:crypto/crypto.dart';

import 'downloader.dart';
import 'http.dart';
import 'pipeline.dart';
import 'robots.dart';

// ============================================================================
// ENGINE, STATS & DEDUPLICATION
// ============================================================================

/// Counters describing a completed or in-flight run.
class Stats {
  /// Requests accepted into the queue, after de-duplication.
  int scheduled = 0;

  /// Responses processed to completion.
  int completed = 0;

  /// Items emitted through [Engine.emit].
  int emitted = 0;

  /// Total response bytes seen.
  int bytes = 0;

  /// Requests that threw an error during fetch or handling.
  int failed = 0;

  /// Requests retried during fetch.
  int retried = 0;

  /// Requests dropped before fetching because `robots.txt` disallowed them.
  int skipped = 0;

  /// Items discarded because they were emitted before anything listened and
  /// the pre-listener buffer was full. See [Engine.emit].
  int dropped = 0;

  /// When [Engine.run] started.
  DateTime? start;

  /// When [Engine.run] finished, or `null` while running.
  DateTime? end;

  /// Why the run stopped early, if it did. See [Engine.stop].
  String? reason;

  /// Wall-clock duration so far, or of the whole run once finished.
  Duration get elapsed =>
      start == null
          ? Duration.zero
          : (end ?? DateTime.now()).difference(start!);

  @override
  String toString() =>
      'Stats(completed: $completed, failed: $failed, skipped: $skipped, '
      'retried: $retried, emitted: $emitted, dropped: $dropped, '
      'elapsed: $elapsed)';
}

/// Tracks which URLs a run has already seen.
///
/// URLs are normalised before comparison: the fragment is dropped, host is lowercased,
/// query parameters are sorted, and trailing slashes are ignored.
class Deduplicator {
  final Set<String> _seen;

  /// Creates a deduplicator, optionally seeded with [seen] keys.
  Deduplicator([Iterable<String>? seen])
    : _seen = seen != null ? seen.toSet() : <String>{};

  /// Restores a deduplicator from serialized keys.
  factory Deduplicator.fromJson(List<dynamic> json) =>
      Deduplicator(json.cast<String>());

  /// Serializes recorded keys to a JSON-compatible list.
  List<String> toJson() => _seen.toList();

  /// How many distinct requests or URLs have been recorded.
  int get length => _seen.length;

  /// Whether nothing has been recorded.
  bool get isEmpty => _seen.isEmpty;

  /// Whether anything has been recorded.
  bool get isNotEmpty => _seen.isNotEmpty;

  /// Whether [url] (with optional [method], [tag], and [body]) has been seen.
  bool seen(
    Uri url, {
    HttpMethod method = HttpMethod.get,
    String? tag,
    List<int>? body,
  }) => _seen.contains(_norm(url, method: method, tag: tag, body: body));

  /// Records [url] (with optional [method], [tag], and [body]); returns `false` when it was already present.
  bool add(
    Uri url, {
    HttpMethod method = HttpMethod.get,
    String? tag,
    List<int>? body,
  }) => _seen.add(_norm(url, method: method, tag: tag, body: body));

  /// Records [request]; returns `false` when it was already present.
  /// Always returns `true` if [Request.dedupe] is `false`.
  bool track(Request<dynamic> request) {
    if (!request.dedupe) return true;
    return add(
      request.url,
      method: request.method,
      tag: request.tag,
      body: request.body?.bytes(),
    );
  }

  /// Whether [request] has already been seen.
  bool tracked(Request<dynamic> request) => seen(
    request.url,
    method: request.method,
    tag: request.tag,
    body: request.body?.bytes(),
  );

  /// Forgets every recorded entry.
  void clear() => _seen.clear();

  static String _norm(
    Uri url, {
    HttpMethod method = HttpMethod.get,
    String? tag,
    List<int>? body,
  }) {
    final bare = url.removeFragment();
    final host = bare.host.toLowerCase();
    var path = bare.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final sortedEntries =
        bare.queryParametersAll.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final queryParams = Map.fromEntries(sortedEntries);
    final normUrl =
        bare
            .replace(
              host: host.isNotEmpty ? host : null,
              path: path,
              queryParameters: queryParams.isEmpty ? null : queryParams,
            )
            .toString();

    final bodyHash =
        (method != HttpMethod.get && body != null && body.isNotEmpty)
            ? md5.convert(body).toString()
            : '';
    return '${method.wire}|$normUrl|${tag ?? ''}|$bodyHash';
  }
}

/// Read-only view of an engine's frontier, reachable as [Engine.queue].
class QueueAccess<T> {
  final Engine<T> _engine;

  /// Wraps [_engine]'s queue.
  const QueueAccess(this._engine);

  /// Requests waiting to be served.
  int get length => _engine._queue.length;

  /// Whether nothing is waiting.
  bool get isEmpty => _engine._queue.isEmpty;

  /// Whether anything is waiting.
  bool get isNotEmpty => _engine._queue.isNotEmpty;

  /// Discards everything waiting, without stopping in-flight work.
  void clear() => _engine._queue.clear();
}

/// Lifecycle handlers for an [Engine], reachable as `engine.on`.
class EngineEvents<T> {
  final List<void Function()> _startHandlers = [];
  final List<void Function(Stats stats)> _doneHandlers = [];
  final List<void Function(T item)> _itemHandlers = [];
  final List<void Function(Response<T> response)> _progressHandlers = [];
  final List<void Function(Object error, StackTrace stack)> _errorHandlers = [];

  /// Called once before the first request is served.
  void start(void Function() handler) => _startHandlers.add(handler);

  /// Called once after the run finishes, with the final [Stats].
  void done(void Function(Stats stats) handler) => _doneHandlers.add(handler);

  /// Called for each item passed to [Engine.emit].
  void item(void Function(T item) handler) => _itemHandlers.add(handler);

  /// Called after each response is processed.
  void progress(void Function(Response<T> response) handler) =>
      _progressHandlers.add(handler);

  /// Called when a request or its handler throws.
  ///
  /// Without a handler, errors are swallowed so one bad page cannot end the
  /// run; register this to see them.
  void error(void Function(Object error, StackTrace stack) handler) =>
      _errorHandlers.add(handler);
}

/// Drives a crawl: schedule, fetch, process, repeat.
///
/// Prefer the `net.crawl(...)` builder for ordinary use; construct an engine
/// High-performance bucketed FIFO priority frontier queue.
class _Frontier<T> {
  final SplayTreeMap<int, ListQueue<Request<T>>> _buckets =
      SplayTreeMap<int, ListQueue<Request<T>>>((a, b) => b.compareTo(a));
  int _count = 0;

  int get length => _count;
  bool get isEmpty => _count == 0;
  bool get isNotEmpty => _count > 0;

  void add(Request<T> request) {
    final queue = _buckets.putIfAbsent(
      request.priority,
      () => ListQueue<Request<T>>(),
    );
    queue.add(request);
    _count++;
  }

  Request<T>? serve() {
    while (_buckets.isNotEmpty) {
      final key = _buckets.firstKey();
      if (key == null) return null;
      final queue = _buckets[key];
      if (queue != null && queue.isNotEmpty) {
        _count--;
        return queue.removeFirst();
      }
      _buckets.remove(key);
    }
    return null;
  }

  void clear() {
    _buckets.clear();
    _count = 0;
  }
}

/// The crawling engine.
///
/// Drives the download-parse-emit loop, de-duplicates requests, manages
/// concurrency, and routes responses through a [Router].
class Engine<T> {
  /// The downloader driving transfers.
  final Downloader<T> downloader;
  final bool _ownsDownloader;

  /// Frontier de-duplicator. Defaults to an in-memory [Deduplicator].
  final Deduplicator deduplicator;

  /// Whether de-duplication is active. Defaults to true.
  final bool dedupe;

  /// Maximum number of items to crawl before stopping.
  final int? limit;

  /// Maximum link follow depth.
  final int? depth;

  /// Allowed URL patterns. If not empty, URLs must match at least one.
  final List<Pattern> allow;

  /// Denied URL patterns. URLs matching any are dropped.
  final List<Pattern> deny;

  /// Whether to restrict crawling to the host of the initial seed URL.
  final bool samehost;

  /// Whether to obey `robots.txt` rules before fetching URLs.
  final bool obey;

  /// User-agent to match against `robots.txt`.
  final String agent;

  String? _seedHost;

  final Process<T>? _process;
  final _Frontier<T> _queue = _Frontier<T>();
  final Map<String, Future<Robots>> _robotsCache = {};
  final ListQueue<T> _bufferedItems = ListQueue<T>();
  bool _hasItemListener = false;
  late final StreamController<T> _items;
  final Stats _stats = Stats();
  final Set<Completer<void>> _waiting = {};
  bool _running = false;
  bool _stopped = false;
  bool _finished = false;
  int _active = 0;

  /// Read-only view of the frontier.
  late final QueueAccess<T> queue = QueueAccess<T>(this);

  /// Lifecycle handlers.
  late final EngineEvents<T> on = EngineEvents<T>();

  /// Per-URL, per-tag and per-status routing.
  ///
  /// When any rule is registered the router handles every response, falling
  /// back to the constructor's `process` only for responses no rule matched.
  final Router<T> router = Router<T>();

  /// Creates an engine.
  ///
  /// [process] handles responses no [router] rule matched. Without a
  /// [downloader] an [HttpDownloader] is created with [concurrency] and
  /// [delay].
  Engine({
    Downloader<T>? downloader,
    bool? owns,
    Deduplicator? deduplicator,
    Process<T>? process,
    int concurrency = 1,
    Duration delay = Duration.zero,
    String? base,
    this.dedupe = true,
    this.limit,
    this.depth,
    Iterable<Pattern>? allow,
    Iterable<Pattern>? deny,
    this.samehost = false,
    this.obey = false,
    this.agent = '*',
  }) : downloader =
           downloader ??
           HttpDownloader<T>(
             concurrency: concurrency,
             delay: delay,
             base: base,
           ),
       _ownsDownloader = owns ?? (downloader == null),
       deduplicator = deduplicator ?? Deduplicator(),
       allow = allow?.toList() ?? const [],
       deny = deny?.toList() ?? const [],
       _process = process {
    this.downloader.attach(this);
    _items = StreamController<T>.broadcast(
      onListen: () {
        _hasItemListener = true;
        for (final item in _bufferedItems) {
          _items.add(item);
        }
        _bufferedItems.clear();
        if (_finished && !_items.isClosed) {
          _items.close();
        }
      },
    );
  }

  static const _robotsCacheLimit = 1024;

  /// Retrieves the cached or newly-loaded [Robots] document for [url].
  ///
  /// The pending fetch is cached, not just its result, so the workers that
  /// arrive at a new host together share one `robots.txt` request instead of
  /// each issuing their own.
  Future<Robots> robots(Uri url) {
    final origin =
        '${url.scheme}://${url.host.toLowerCase()}'
        '${url.hasPort ? ':${url.port}' : ''}';
    final cached = _robotsCache[origin];
    if (cached != null) return cached;

    if (_robotsCache.length >= _robotsCacheLimit) {
      _robotsCache.remove(_robotsCache.keys.first);
    }
    final dl = downloader;
    final client = dl is HttpDownloader<T> ? dl.client : null;
    return _robotsCache[origin] = Robots.load(url, client: client);
  }

  /// Counters for the current or last run.
  Stats get stats => _stats;

  /// Items emitted through [emit], as a broadcast stream.
  ///
  /// Emitted items before the first listener attaches are buffered and delivered
  /// upon listen. Closed when [run] finishes.
  Stream<T> get items => _items.stream;

  /// Whether a run is in progress.
  bool get running => _running;

  /// Whether [stop] has been called.
  bool get stopped => _stopped;

  /// Requests currently in flight.
  int get active => _active;

  /// Whether nothing is queued and nothing is in flight.
  bool get idle => _active == 0 && _queue.isEmpty;

  /// Pushes [request] into the frontier.
  ///
  /// Silently drops the request when [dedupe] is enabled and this URL was
  /// already queued or completed, or if the request violates scope rules
  /// ([depth], [allow], [deny], [samehost]).
  void add(Request<T> request) {
    if (_stopped) return;

    if (limit != null && _stats.scheduled >= limit!) return;

    if (_seedHost == null && request.url.host.isNotEmpty) {
      _seedHost = request.url.host.toLowerCase();
    }

    if (depth != null && request.depth > depth!) return;

    if (samehost && _seedHost != null && request.url.host.isNotEmpty) {
      if (request.url.host.toLowerCase() != _seedHost) return;
    }

    final urlStr = request.url.toString();
    if (deny.any((p) => p.allMatches(urlStr).isNotEmpty)) return;
    if (allow.isNotEmpty &&
        !allow.any((p) => p.allMatches(urlStr).isNotEmpty)) {
      return;
    }

    if (dedupe && !deduplicator.track(request)) return;
    request.engine = this;

    _queue.add(request);
    _stats.scheduled++;
    _signal();
  }

  /// Takes the next request, or `null` when the queue is empty.
  ///
  /// Called by the [Downloader]'s workers.
  Request<T>? serve() => _queue.serve();

  /// Marks a request as in flight. Called by the [Downloader]'s workers.
  void enter() => _active++;

  /// Marks a request as settled, waking idle workers when the run drains.
  ///
  /// Called by the [Downloader]'s workers. Waking on drain is what lets an
  /// idle worker notice the run is over instead of waiting forever.
  void leave() {
    _active--;
    if (idle) _signal();
  }

  /// Waits until work is queued, the run drains, or the engine stops.
  ///
  /// Used by worker loops instead of polling. Returns immediately when work is
  /// already available, nothing is left to wait for, or the engine stopped.
  Future<void> waiting() {
    if (_queue.isNotEmpty || _stopped || idle) return Future.value();
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  /// Releases every worker waiting on [waiting] so they re-check their state.
  void _signal() {
    if (_waiting.isEmpty) return;
    final released = _waiting.toList();
    _waiting.clear();
    for (final completer in released) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  // A crawl whose results nobody is listening for would otherwise accumulate
  // every item in memory. Past this many the oldest are discarded and counted
  // in Stats.dropped; collect, stream and to all listen before the run starts,
  // so they never reach it.
  static const _emitBufferLimit = 4096;

  /// Emits [item] to [items] and the [EngineEvents.item] handlers.
  void emit(T item) {
    if (_finished) return;
    _stats.emitted++;
    for (final h in on._itemHandlers) {
      h(item);
    }
    if (!_hasItemListener) {
      if (_bufferedItems.length >= _emitBufferLimit) {
        _bufferedItems.removeFirst();
        _stats.dropped++;
      }
      _bufferedItems.add(item);
    } else if (!_items.isClosed) {
      _items.add(item);
    }
  }

  /// Processes [response] through [router], then the constructor's process.
  ///
  /// Called by the [Downloader]'s workers.
  Future<void> process(Response<T> response) async {
    _stats.bytes += response.bytes.length;
    response.engine = this;

    final routed = router.isNotEmpty && await router.handle(response);
    if (!routed) await _process?.call(response);

    _stats.completed++;
    for (final h in on._progressHandlers) {
      h(response);
    }

    if (limit != null && _stats.completed >= limit!) {
      stop('Limit of $limit pages reached');
    }
  }

  /// Records a request dropped before fetching. Called by the [Downloader].
  void skip() {
    _stats.skipped++;
    if (idle) _signal();
  }

  /// Reports [error] to the [EngineEvents.error] handlers.
  ///
  /// Called by the [Downloader]'s workers when a fetch or handler throws.
  void fail(Object error, StackTrace stack) {
    _stats.failed++;
    for (final h in on._errorHandlers) {
      h(error, stack);
    }
  }

  /// Stops the run once in-flight work settles, recording [reason].
  void stop([String reason = 'Stopped by user']) {
    _stopped = true;
    _stats.reason = reason;
    _signal();
  }

  /// Runs until the frontier drains, seeding it with [urls].
  ///
  /// Throws [StateError] if the engine is already running or has already completed a run.
  Future<Stats> run([Iterable<String> urls = const []]) async {
    if (_running) throw StateError('Engine is already running');
    if (_finished) {
      throw StateError(
        'Engine has already completed a run and cannot be reused',
      );
    }
    _running = true;
    _stopped = false;
    _stats.start = DateTime.now();

    downloader.attach(this);
    for (final url in urls) {
      add(Request<T>(coerce(url)));
    }

    for (final h in on._startHandlers) {
      h();
    }
    await downloader.work(this);

    _stats.end = DateTime.now();
    _running = false;
    _finished = true;
    for (final h in on._doneHandlers) {
      h(_stats);
    }
    if (_hasItemListener) {
      await _items.close();
    }
    if (_ownsDownloader) {
      await downloader.close();
    }
    return _stats;
  }
}
