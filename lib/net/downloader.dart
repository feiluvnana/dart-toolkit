import 'dart:async';
import 'dart:io' hide HttpClient;

import 'package:http/http.dart' as http;

import '../concurrent/concurrent.dart';
import '../io/file.dart';
import '../util/console/console.dart';
import 'engine.dart';
import 'http.dart';
import 'pipeline.dart';

// ============================================================================
// DOWNLOADER & HTTP STREAMING DOWNLOADER
// ============================================================================

/// Event callback namespace for downloader lifecycle notifications (`downloader.on.*`).
class DownloaderEvents {
  void Function(Object req)? _start;
  void Function(int received, int total)? _progress;
  void Function(Object res)? _done;
  void Function(Object error, Object? req)? _error;

  /// Registers a callback triggered when a download begins.
  void start(void Function(Object req) handler) => _start = handler;

  /// Registers a callback triggered as streaming chunks arrive with received and total bytes.
  void progress(void Function(int received, int total) handler) =>
      _progress = handler;

  /// Registers a callback triggered when a download finishes successfully.
  void done(void Function(Object res) handler) => _done = handler;

  /// Registers a callback triggered when a download encounters an error.
  void error(void Function(Object error, Object? req) handler) =>
      _error = handler;
}

/// Abstract contract for downloading web pages and assets.
abstract class Downloader<T> {
  /// Back-reference to the parent [Engine].
  Engine<T>? engine;

  /// Base local directory for relative destination paths.
  String? base;

  /// Maximum number of concurrent worker loops.
  int concurrency;

  /// Delay between consecutive requests per worker to ensure polite crawling.
  Duration delay;

  /// Counter of newly saved assets during the lifetime of this downloader.
  int count = 0;

  /// Sub-namespace for download event callbacks.
  late final DownloaderEvents on = DownloaderEvents();

  /// Creates a [Downloader] instance.
  Downloader({this.concurrency = 1, this.delay = Duration.zero, this.base});

  /// Attaches this downloader to an [Engine].
  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  /// Downloader loop that requests tasks from [engine.serve()] and processes them (1-word).
  Future<void> work(Engine<T> engine) async {
    final workers = <Future<void>>[];
    final count = concurrency > 0 ? concurrency : 1;
    for (var i = 0; i < count; i++) {
      workers.add(_worker(engine));
    }
    await Future.wait(workers);
  }

  Future<void> _worker(Engine<T> engine) async {
    while (!engine.stopped) {
      final request = engine.serve();
      if (request == null) {
        if (engine.idle) break;
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }

      engine.active++;
      try {
        final response = await download(request);
        if (!engine.stopped) {
          await engine.process(response);
        }
      } catch (e, s) {
        engine.on.dispatch(e, s);
      } finally {
        engine.active--;
      }

      if (delay > Duration.zero && !engine.stopped) {
        await Future.delayed(delay);
      }
    }
  }

  /// Downloads [requestOrUrl] and returns a parsed [Response].
  Future<Response<T>> download(Object requestOrUrl);

  /// Performs an HTTP GET request for [url] and returns a [Response].
  Future<Response<T>> get(
    Object url, {
    Map<String, String>? headers,
    Map<String, Object?>? meta,
  }) {
    final req = url is Request<T>
        ? url
        : Request<T>.get(url, headers: headers, meta: meta);
    return download(req);
  }

  /// Performs an HTTP POST request for [url] with optional [body] and returns a [Response].
  Future<Response<T>> post(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? meta,
  }) {
    final req = url is Request<T>
        ? url
        : Request<T>.post(url, body: body, headers: headers, meta: meta);
    return download(req);
  }

  /// Checks whether a local asset already exists and is non-empty.
  bool has(String path, {bool match = true}) {
    final file = _resolve(path);
    return Fs.has(file, match: match);
  }

  /// Downloads an asset from a source URL and saves it to a local destination file.
  Future<void> save(
    Object targetOrRequest,
    Object sourceOrDestination, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  });

  /// Concurrently synchronizes a collection of download tasks into local files.
  Future<void> sync(
    Object tasks, {
    String? prefix,
    int concurrency = 4,
    bool match = true,
  }) async {
    final entries = <({String path, String url})>[];
    if (tasks is Map) {
      for (final e in tasks.entries) {
        var u = e.value.toString();
        if (prefix != null && !u.startsWith('http')) u = '$prefix$u';
        entries.add((path: e.key.toString(), url: u));
      }
    } else if (tasks is Iterable) {
      for (final item in tasks) {
        if (item is MapEntry) {
          var u = item.value.toString();
          if (prefix != null && !u.startsWith('http')) u = '$prefix$u';
          entries.add((path: item.key.toString(), url: u));
        } else if (item is ({String path, String url})) {
          var u = item.url;
          if (prefix != null && !u.startsWith('http')) u = '$prefix$u';
          entries.add((path: item.path, url: u));
        }
      }
    }

    final pool = Pool(concurrency);
    await pool.run(entries, (t) => save(t.path, t.url, match: match));
  }

  /// Closes underlying HTTP connections and resources.
  Future<void> close() async {}

  File _resolve(Object pathOrFile) {
    final pStr = pathOrFile is File ? pathOrFile.path : pathOrFile.toString();
    if (base != null && !pStr.startsWith(base!) && !File(pStr).isAbsolute) {
      return File('$base/$pStr');
    }
    return File(pStr);
  }
}

/// Standard HTTP streaming downloader implementation backed by [HttpClient].
class HttpDownloader<T> extends Downloader<T> {
  final HttpClient _client;

  /// Creates an [HttpDownloader] instance.
  HttpDownloader({
    http.Client? client,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    int retries = 2,
    Duration backoff = const Duration(milliseconds: 500),
    super.concurrency = 4,
    super.delay = Duration.zero,
    super.base,
  }) : _client = HttpClient(
         client: client,
         headers: headers,
         timeout: timeout,
         retries: retries,
         backoff: backoff,
         base: base,
       );

  /// Default headers sent with each request.
  Map<String, String> get headers => _client.headers;

  /// Request timeout duration.
  Duration get timeout => _client.timeout;

  /// Number of retry attempts on network or 5xx failures.
  int get retries => _client.retries;

  /// Delay between retry attempts.
  Duration get backoff => _client.backoff;

  @override
  Future<Response<T>> download(Object requestOrUrl) async {
    final Request<T> request = requestOrUrl is Request<T>
        ? requestOrUrl
        : Request<T>.get(requestOrUrl);

    on._start?.call(request);

    try {
      final res = await _client.send(
        request.method,
        request.url,
        headers: request.headers,
        body: request.body,
        timeout: timeout,
      );

      final response = Response<T>(
        request: request,
        status: res.status,
        headers: res.headers,
        bytes: res.bytes,
        engine: engine,
      );
      on._done?.call(response);
      return response;
    } catch (e) {
      on._error?.call(e, request);
      rethrow;
    }
  }

  @override
  Future<void> save(
    Object targetOrRequest,
    Object sourceOrDestination, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  }) async {
    File destination;
    Uri url;
    Map<String, String> extraHeaders = {};

    if (targetOrRequest is Request) {
      destination = sourceOrDestination is File
          ? sourceOrDestination
          : _resolve(sourceOrDestination);
      url = targetOrRequest.url;
      extraHeaders = targetOrRequest.headers;
    } else {
      destination = _resolve(targetOrRequest);
      if (sourceOrDestination is Request) {
        url = sourceOrDestination.url;
        extraHeaders = sourceOrDestination.headers;
      } else if (sourceOrDestination is Uri) {
        url = sourceOrDestination;
      } else {
        url = Uri.parse(sourceOrDestination.toString());
      }
    }

    if (Fs.has(destination, match: match)) {
      return;
    }

    Console.logger.info(
      'Downloading /${destination.path.replaceAll('\\', '/')}...',
    );

    try {
      await _client.download(
        url,
        destination,
        headers: extraHeaders,
        onProgress: onProgress ?? on._progress,
        part: part,
        match: match,
      );
      count++;
    } catch (e) {
      on._error?.call(e, url);
    }
  }

  @override
  Future<void> close() => _client.close();
}
