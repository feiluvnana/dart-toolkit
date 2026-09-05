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

class DownloaderEvents {
  void Function(dynamic req)? _start;
  void Function(int received, int total)? _progress;
  void Function(dynamic res)? _done;
  void Function(Object error, dynamic req)? _error;

  void start(void Function(dynamic req) handler) => _start = handler;
  void progress(void Function(int received, int total) handler) =>
      _progress = handler;
  void done(void Function(dynamic res) handler) => _done = handler;
  void error(void Function(Object error, dynamic req) handler) =>
      _error = handler;
}

abstract class Downloader<T> {
  Engine<T>? engine;
  String? base;
  int count = 0;
  late final DownloaderEvents on = DownloaderEvents();

  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  Future<Response<T>> download(dynamic requestOrUrl);

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

  bool has(String path, {bool match = true}) {
    final file = _resolve(path);
    return Fs.has(file, match: match);
  }

  Future<void> save(
    dynamic targetOrRequest,
    dynamic sourceOrDestination, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  });

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

class HttpDownloader<T> extends Downloader<T> {
  final http.Client _client;
  final bool _ownsClient;
  final Map<String, String> headers;
  final Duration timeout;

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
    Console.info('Downloading /${destination.path.replaceAll('\\', '/')}...');

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
