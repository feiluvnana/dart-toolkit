/// # Downloader & Worker Loop
///
/// A [Downloader] fetches requests and runs the engine's worker loop. Subclass
/// it to serve a crawl from somewhere other than the network — a fixture map,
/// a cache, a local directory — which is what makes pipelines testable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide HttpClient;

import 'package:http/http.dart' as http;

import '../src/fs.dart';
import 'net.dart';

// ============================================================================
// DOWNLOADER & HTTP STREAMING DOWNLOADER
// ============================================================================

/// Per-transfer handlers for a [Downloader], reachable as `downloader.on`.
///
/// These describe individual fetches; for pipeline-wide events use
/// [EngineEvents].
class DownloaderEvents {
  void Function(int received, int total)? _progress;
  void Function(Object error, Uri url)? _error;

  /// Called as bytes arrive during [Downloader.save].
  ///
  /// `total` is `-1` when the server sends no `Content-Length`.
  void progress(void Function(int received, int total) handler) =>
      _progress = handler;

  /// Called when a transfer fails.
  void error(void Function(Object error, Uri url) handler) => _error = handler;
}

/// Fetches requests for an [Engine] and drives its worker loop.
///
/// Implement [download] to source responses; [save] is only needed if your
/// pipeline streams binaries to disk.
abstract class Downloader<T> with PathResolver {
  /// The engine being served, set by [attach].
  Engine<dynamic>? engine;

  /// Base directory that relative destinations resolve against.
  @override
  String? base;

  /// Maximum concurrent workers. Values below one are treated as one.
  int concurrency;

  /// Pause after each request, for politeness against a server.
  Duration delay;

  /// Whether pause after request is enforced per-host rather than globally across all hosts.
  bool perhost;

  static const _hostTableLimit = 4096;

  final Map<String, DateTime> _nextHostAccess = {};

  /// Waits until at least [gap] has passed since the last request to [host].
  Future<void> _throttleHost(String host, Duration gap) async {
    if (gap <= Duration.zero) return;
    final now = DateTime.now();
    final scheduled = _nextHostAccess.remove(host);
    final targetTime =
        (scheduled != null && scheduled.isAfter(now)) ? scheduled : now;
    if (scheduled == null && _nextHostAccess.length >= _hostTableLimit) {
      // A broad crawl meets more hosts than it needs to remember. Removing and
      // reinserting above makes this map least-recently-used, so the entry
      // dropped here is the host longest untouched rather than merely the one
      // seen first — a busy host stays paced however long the crawl runs.
      _nextHostAccess.remove(_nextHostAccess.keys.first);
    }
    _nextHostAccess[host] = targetTime.add(gap);
    final waitDuration = targetTime.difference(now);
    if (waitDuration > Duration.zero) {
      await Future<void>.delayed(waitDuration);
    }
  }

  /// Number of retries for failed requests.
  int retries;

  /// Number of files successfully written by [save].
  int count = 0;

  /// Per-transfer handlers.
  late final DownloaderEvents on = DownloaderEvents();

  /// Creates a downloader.
  Downloader({
    this.concurrency = 1,
    this.delay = Duration.zero,
    this.perhost = false,
    this.base,
    this.retries = 0,
  });

  /// Binds this downloader to [engine].
  void attach(Engine<dynamic> engine) => this.engine = engine;

  /// Fetches [request] and returns its response.
  Future<Response<T>> download(Request<T> request);

  /// Streams [source] to [path], resolved against [base].
  ///
  /// Implementations should skip work when the destination already exists and
  /// let failures propagate.
  Future<File> save(
    Uri source,
    String path, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = false,
  }) async {
    throw UnsupportedError(
      'This downloader ($runtimeType) does not support save()',
    );
  }

  /// Releases any resources held by this downloader.
  Future<void> close() async {}

  /// Runs [concurrency] workers until the engine's frontier drains.
  Future<void> work(Engine<dynamic> engine) async {
    final workers = [
      for (var i = 0; i < (concurrency > 0 ? concurrency : 1); i++)
        _worker(engine),
    ];
    await Future.wait(workers);
  }

  /// Pulls requests from [engine] until it stops or runs dry.
  ///
  /// Waits on [Engine.waiting] rather than polling, so an idle worker costs
  /// nothing while a sibling is still discovering links.
  Future<void> _worker(Engine<dynamic> engine) async {
    while (!engine.stopped) {
      final request = engine.serve();
      if (request == null) {
        // Nothing queued: either the run is finished, or a busy sibling may
        // still schedule more work.
        if (engine.idle) break;
        await engine.waiting();
        continue;
      }

      var robotsDelay = Duration.zero;
      if (engine.obey &&
          request.url.hasScheme &&
          (request.url.scheme == 'http' || request.url.scheme == 'https')) {
        final r = await engine.robots(request.url);
        if (!r.allowed(request.url, agent: engine.agent)) {
          engine.skip(request);
          continue;
        }
        robotsDelay = r.delay(agent: engine.agent) ?? Duration.zero;
      }

      // A Crawl-delay the site asked for is honoured per-host whether or not
      // perhost pacing was requested; it is a floor, not a replacement.
      final hostGap = _max(perhost ? delay : Duration.zero, robotsDelay);
      if (hostGap > Duration.zero && !engine.stopped) {
        await _throttleHost(request.url.host, hostGap);
      }

      engine.enter();
      try {
        final response = await download(request as Request<T>);
        if (!engine.stopped) await engine.process(response);
      } catch (error, stack) {
        engine.fail(error, stack, request);
      } finally {
        engine.leave();
      }

      if (!perhost && delay > Duration.zero && !engine.stopped) {
        await Future<void>.delayed(delay);
      }
    }
  }

  static Duration _max(Duration a, Duration b) => a > b ? a : b;
}

/// A test/fixture downloader backed by an in-memory map of URLs to responses.
///
/// Keys are matched most specific first: `'POST https://host/login'`, then
/// `'POST /login'`, then `'https://host/login'`, then `'/login'`. Prefixing a
/// key with a method is what lets a multi-step form crawl be fixtured — the
/// same URL can answer differently to a `GET` and a `POST`:
///
/// ```dart
/// final downloader = MapDownloader<String>({
///   '/login': '<form action="/login" method="post">...</form>',
///   'POST /login': '<p class="welcome">Signed in</p>',
/// });
/// ```
///
/// Everything it served is recorded in [requests], so a test can assert on the
/// method, headers and body a pipeline actually sent.
class MapDownloader<T> extends Downloader<T> {
  /// The response body map, keyed by URL string or URL path, either optionally
  /// prefixed with an HTTP method and a space.
  final Map<String, String> responses;

  /// Default HTTP status to return for matching responses. Defaults to 200.
  final int status;

  /// Default headers to return with responses.
  final Map<String, String> headers;

  /// Every request served, in the order it was served.
  final List<Request<T>> requests = [];

  /// Creates a fixture-backed downloader.
  MapDownloader(
    this.responses, {
    this.status = 200,
    this.headers = const {'content-type': 'text/html; charset=utf-8'},
    super.concurrency = 1,
    super.delay = Duration.zero,
    super.perhost = false,
    super.base,
    super.retries = 0,
  });

  /// The most specific key [request] matches, or `null` when none do.
  String? _key(Request<T> request) {
    final wire = request.method.wire;
    final url = request.url.toString();
    final path = request.url.path;
    for (final key in ['$wire $url', '$wire $path', url, path]) {
      if (responses.containsKey(key)) return key;
    }
    return null;
  }

  @override
  Future<Response<T>> download(Request<T> request) async {
    requests.add(request);
    final key = _key(request);
    return Response<T>(
      request: request,
      url: request.url,
      status: key != null ? status : 404,
      headers: headers,
      bytes: utf8.encode(responses[key] ?? ''),
      engine: engine,
    );
  }
}

/// Fetches requests over HTTP, backed by an [HttpClient].
class HttpDownloader<T> extends Downloader<T> {
  final HttpClient _client;
  final bool _ownsClient;

  /// Creates a downloader over an [HttpClient].
  ///
  /// Pass [client] to share an [HttpClient] you own: this downloader then uses
  /// it without taking ownership, so [close] leaves it open. With [pool],
  /// [headers] or [timeout] a client is built here and closed on [close].
  /// With none of them the shared `net.http` client is used, and left open.
  HttpDownloader({
    HttpClient? client,
    http.Client? pool,
    Map<String, String>? headers,
    Duration? timeout,
    int? cap,
    HttpCache? cache,
    super.retries = 2,
    Duration backoff = const Duration(milliseconds: 500),
    super.concurrency = 4,
    super.delay = Duration.zero,
    super.perhost = false,
    super.base,
  }) : // Only a client constructed here is ours to close. One handed in by the
       // caller, and the process-wide net.http, both outlive this downloader.
       _ownsClient =
           client == null &&
           (pool != null ||
               headers != null ||
               timeout != null ||
               cap != null ||
               cache != null),
       _client =
           client ??
           ((pool != null ||
                   headers != null ||
                   timeout != null ||
                   cap != null ||
                   cache != null)
               ? HttpClient(
                 pool: pool,
                 headers: headers ?? net.http.headers,
                 timeout: timeout ?? net.http.timeout,
                 retries: retries,
                 backoff: backoff,
                 base: base,
                 cap: cap,
                 cache: cache,
               )
               : net.http);

  /// The underlying HTTP client.
  HttpClient get client => _client;

  /// Headers sent with every request.
  Map<String, String> get headers => _client.headers;

  /// Per-request timeout.
  Duration get timeout => _client.timeout;

  /// Base delay for retry backoff.
  Duration get backoff => _client.backoff;

  /// Largest response body accepted, in bytes, or `null` for no limit.
  int? get cap => _client.cap;

  /// Responses kept between runs, or `null` to always fetch.
  HttpCache? get cache => _client.cache;

  @override
  Future<Response<T>> download(Request<T> request) async {
    final uri = request.url;
    if (uri.scheme == 'data') {
      final bytes =
          uri.data?.contentAsBytes() ??
          utf8.encode(uri.data?.contentAsString() ?? '');
      return Response<T>(
        request: request,
        status: 200,
        headers: {'content-type': uri.data?.mimeType ?? 'text/html'},
        bytes: bytes,
        engine: engine,
      );
    }
    if (uri.scheme == 'file') {
      final file = File(uri.toFilePath());
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        return Response<T>(
          request: request,
          status: 200,
          headers: {'content-type': 'text/html'},
          bytes: bytes,
          engine: engine,
        );
      }
      // A path that is not there is a miss, not a page whose body is its own
      // URL: report it the way a 404 from the network would arrive.
      return Response<T>(
        request: request,
        status: 404,
        headers: const {'content-type': 'text/plain'},
        bytes: const [],
        engine: engine,
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      final content =
          uri.scheme == 'string'
              ? Uri.decodeComponent(uri.path)
              : (uri.hasScheme ? uri.toString() : uri.path);
      return Response<T>(
        request: request,
        status: 200,
        headers: {'content-type': 'text/plain'},
        bytes: utf8.encode(content),
        engine: engine,
      );
    }
    try {
      final res = await _client.send(
        request.method,
        request.url,
        headers: request.headers.isEmpty ? null : request.headers,
        body: request.body,
        retries: retries,
        retry: request.method == HttpMethod.get ? null : true,
        onretry: (url, attempt) => engine?.retry(),
      );
      return Response<T>(
        request: request,
        url: res.url,
        requested: res.requested,
        status: res.status,
        headers: res.headers,
        bytes: res.bytes,
        encoding: res.encoding,
        engine: engine,
      );
    } catch (error) {
      on._error?.call(error, request.url);
      rethrow;
    }
  }

  @override
  Future<File> save(
    Uri source,
    String path, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = false,
  }) async {
    if (source.scheme == 'data') {
      final bytes =
          source.data?.contentAsBytes() ??
          utf8.encode(source.data?.contentAsString() ?? '');
      final file = await Fs.save(resolve(path), bytes, part: part);
      count++;
      return file;
    }
    if (source.scheme == 'string') {
      final bytes = utf8.encode(Uri.decodeComponent(source.path));
      final file = await Fs.save(resolve(path), bytes, part: part);
      count++;
      return file;
    }
    if (source.scheme == 'file') {
      final srcFile = File(source.toFilePath());
      final bytes = await srcFile.readAsBytes();
      final file = await Fs.save(resolve(path), bytes, part: part);
      count++;
      return file;
    }
    try {
      // Resolve here: the client has a base of its own (often none, when the
      // shared net.http client is reused), so handing it a bare relative path
      // would quietly ignore this downloader's base.
      final file = await _client.download(
        source,
        resolve(path),
        onProgress: onProgress ?? on._progress,
        part: part,
        match: match,
      );
      count++;
      return file;
    } catch (error) {
      on._error?.call(error, source);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_ownsClient) await _client.close();
  }
}
