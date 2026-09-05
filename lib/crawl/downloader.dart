import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../console/console.dart';
import '../fs/fs.dart';
import '../parallel/parallel.dart';
import 'engine.dart';
import 'pipeline.dart';

// ============================================================================
// DOWNLOADER & HTTP STREAMING DOWNLOADER
// ============================================================================

/// Event callback namespace for downloader lifecycle notifications (`downloader.on.*`).
class DownloaderEvents {
  void Function(dynamic req)? _start;
  void Function(int received, int total)? _progress;
  void Function(dynamic res)? _done;
  void Function(Object error, dynamic req)? _error;

  /// Registers a callback triggered when a download begins.
  void start(void Function(dynamic req) handler) => _start = handler;

  /// Registers a callback triggered as streaming chunks arrive with received and total bytes.
  void progress(void Function(int received, int total) handler) =>
      _progress = handler;

  /// Registers a callback triggered when a download finishes successfully.
  void done(void Function(dynamic res) handler) => _done = handler;

  /// Registers a callback triggered when a download encounters an error.
  void error(void Function(Object error, dynamic req) handler) =>
      _error = handler;
}

/// Abstract contract for downloading web pages and assets.
abstract class Downloader<T> {
  /// Back-reference to the parent [Engine].
  Engine<T>? engine;

  /// Base local directory for relative destination paths.
  String? base;

  /// Counter of newly saved assets during the lifetime of this downloader.
  int count = 0;

  /// Sub-namespace for download event callbacks.
  late final DownloaderEvents on = DownloaderEvents();

  /// Attaches this downloader to an [Engine].
  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  /// Downloads [requestOrUrl] and returns a parsed [Response].
  Future<Response<T>> download(dynamic requestOrUrl);

  /// Performs an HTTP GET request for [url] and returns a [Response].
  Future<Response<T>> get(
    dynamic url, {
    Map<String, String>? headers,
    Map<String, dynamic>? meta,
  }) {
    final req = url is Request<T>
        ? url
        : Request<T>.get(url, headers: headers, meta: meta);
    return download(req);
  }

  /// Performs an HTTP POST request for [url] with optional [body] and returns a [Response].
  Future<Response<T>> post(
    dynamic url, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? meta,
  }) {
    final req = url is Request<T>
        ? url
        : Request<T>.post(url, body: body, headers: headers, meta: meta);
    return download(req);
  }

  /// Checks whether a local asset already exists and is non-empty.
  ///
  /// If [match] is true, checks for existing files with matching basenames ignoring
  /// common prefix/suffix differences.
  bool has(String path, {bool match = true}) {
    final file = _resolve(path);
    return Fs.has(file, match: match);
  }

  /// Downloads an asset from a source URL and saves it to a local destination file.
  ///
  /// Uses atomic `.part` writing and skips existing files if [match] is true.
  Future<void> save(
    dynamic targetOrRequest,
    dynamic sourceOrDestination, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  });

  /// Concurrently synchronizes a collection of download tasks into local files.
  ///
  /// [tasks] can be a `Map<String, String>`, an `Iterable` of `MapEntry`, or
  /// record tuples `({String path, String url})`.
  ///
  /// If [prefix] is supplied, it is prepended to relative URLs.
  Future<void> sync(
    dynamic tasks, {
    String? prefix,
    int concurrency = 4,
    bool match = true,
  }) async {
    final entries = <({String path, String url})>[];

    if (tasks is Map) {
      for (final e in tasks.entries) {
        var u = e.value.toString();
        if (prefix != null && !u.startsWith('http')) {
          u = '$prefix$u';
        }
        entries.add((path: e.key.toString(), url: u));
      }
    } else if (tasks is Iterable) {
      for (final item in tasks) {
        if (item is MapEntry) {
          var u = item.value.toString();
          if (prefix != null && !u.startsWith('http')) {
            u = '$prefix$u';
          }
          entries.add((path: item.key.toString(), url: u));
        } else if (item is ({String path, String url})) {
          var u = item.url;
          if (prefix != null && !u.startsWith('http')) {
            u = '$prefix$u';
          }
          entries.add((path: item.path, url: u));
        }
      }
    }

    final pool = Pool(concurrency);
    await pool.run(entries, (t) => save(t.path, t.url, match: match));
  }

  /// Closes underlying HTTP connections and resources.
  Future<void> close() async {}

  File _resolve(dynamic pathOrFile) {
    if (pathOrFile is File) return pathOrFile;
    final pStr = pathOrFile.toString();
    if (base != null && !pStr.startsWith(base!) && !File(pStr).isAbsolute) {
      return File('$base/$pStr');
    }
    return File(pStr);
  }
}

/// Standard HTTP streaming downloader implementation with custom headers, timeouts, and atomic writes.
class HttpDownloader<T> extends Downloader<T> {
  final http.Client _client;
  final bool _ownsClient;

  /// Default headers sent with each request (e.g. User-Agent).
  final Map<String, String> headers;

  /// Request timeout duration.
  final Duration timeout;

  /// Creates an [HttpDownloader] instance.
  HttpDownloader({
    http.Client? client,
    Map<String, String>? defaultHeaders,
    this.timeout = const Duration(seconds: 30),
    String? base,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        headers = defaultHeaders ??
            {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            } {
    this.base = base;
  }

  @override
  Future<Response<T>> download(dynamic requestOrUrl) async {
    final Request<T> request = requestOrUrl is Request<T>
        ? requestOrUrl
        : Request<T>.get(requestOrUrl);

    on._start?.call(request);

    final req = http.Request(request.method, request.url);
    req.headers.addAll(headers);
    req.headers.addAll(request.headers);

    if (request.body != null) {
      if (request.body is String) {
        req.body = request.body as String;
      } else if (request.body is List<int>) {
        req.bodyBytes = request.body as List<int>;
      } else if (request.body is Map) {
        req.bodyFields = (request.body as Map).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
      }
    }

    try {
      final streamed = await _client.send(req).timeout(timeout);
      final res = await http.Response.fromStream(streamed);

      final response = Response<T>(
        request: request,
        status: res.statusCode,
        headers: res.headers,
        bytes: res.bodyBytes,
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
    dynamic targetOrRequest,
    dynamic sourceOrDestination, {
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

    final merged = Map<String, String>.from(headers)..addAll(extraHeaders);
    Console.logger.info('Downloading /${destination.path.replaceAll('\\', '/')}...');

    try {
      await Fs.download(
        url,
        destination,
        client: _client,
        headers: merged,
        onProgress: onProgress ?? on._progress,
        part: part,
      );
      count++;
    } catch (e) {
      on._error?.call(e, url);
    }
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}
