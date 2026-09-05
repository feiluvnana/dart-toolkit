import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http_lib;

import '../concurrent/concurrent.dart';
import '../io/file.dart';
import 'selector.dart';

// ============================================================================
// HTTP NETWORKING SUBSYSTEM (http.* / Http)
// ============================================================================

/// Top-level HTTP client and networking namespace accessor.
///
/// Provides strictly 1-word methods for web requests and streaming downloads:
/// ```dart
/// // Quick GET and JSON parsing
/// final res = await http.get('https://api.github.com/zen');
/// print(res.body);
///
/// // POST request
/// final created = await http.post('https://httpbin.org/post', body: {'title': 'Dart'});
///
/// // Streaming atomic download
/// await http.download('https://example.com/archive.zip', 'downloads/archive.zip');
/// HTTP response wrapper providing status, body, json, DOM query, and atomic file saving.
class HttpResponse {
  /// The request URL.
  final Uri url;

  /// HTTP status code (e.g. 200, 404).
  final int status;

  /// HTTP response headers.
  final Map<String, String> headers;

  /// Raw response payload bytes.
  final List<int> bytes;

  String? _body;
  Document? _doc;

  /// Creates an [HttpResponse].
  HttpResponse({
    required this.url,
    required this.status,
    required this.headers,
    required this.bytes,
  });

  /// Whether response status code indicates success (200..299).
  bool get ok => status >= 200 && status < 300;

  /// Decodes [bytes] as a UTF-8 string with malformed character tolerance.
  String get body => _body ??= utf8.decode(bytes, allowMalformed: true);

  /// Deserializes [body] as JSON.
  Object? get json => jsonDecode(body);

  /// Lazily parses [body] into an HTML [Document].
  Document get doc => _doc ??= html_parser.parse(body);

  /// Queries the parsed HTML document using a CSS selector with jQuery-like `$()`.
  QueryResult $(String selector) => QueryResult(doc.querySelectorAll(selector));

  /// Finds the first matching absolute URL from `<a>`, `<link>`, or `<area>` tags.
  String? link([Pattern? filter]) => links(filter).firstOrNull;

  /// Extracts all absolute URLs from `<a>`, `<link>`, and `<area>` tags.
  List<String> links([Pattern? filter]) {
    final root = doc.documentElement ?? doc.body ?? Element.tag('body');
    final raw = QueryResult([root]).links(filter);
    return raw.map((h) => url.resolve(h).toString()).toList();
  }

  /// Finds the first matching absolute source URL from `<img>`, media, or `<script>` tags.
  String? src([Pattern? filter]) => srcs(filter).firstOrNull;

  /// Extracts all absolute source URLs from media and script tags.
  List<String> srcs([Pattern? filter]) {
    final root = doc.documentElement ?? doc.body ?? Element.tag('body');
    final raw = QueryResult([root]).srcs(filter);
    return raw.map((s) => url.resolve(s).toString()).toList();
  }

  /// Extracts non-empty text lines from the document body.
  List<String> get lines =>
      QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')])
          .lines;

  /// Saves content atomically to [filePath] with temporary `.part` protection.
  ///
  /// If [sourceUrl] is provided, downloads the asset resolved against [url].
  /// Otherwise, writes response [bytes] directly.
  Future<File> save(
    Object filePath, [
    Object? sourceUrl,
    String part = '.part',
  ]) {
    final file = filePath is File ? filePath : File(filePath.toString());
    if (sourceUrl != null) {
      final resolved = url.resolve(sourceUrl.toString());
      return Fs.download(resolved, file, part: part);
    }
    return Fs.write(file, bytes, part: part);
  }

  @override
  String toString() => '$status $url (${bytes.length} bytes)';
}

/// Configured HTTP client and session with shared headers, timeouts, and atomic downloads.
class HttpClient {
  final http_lib.Client _client;
  final bool _ownsClient;

  /// Default headers sent with each request.
  final Map<String, String> headers;

  /// Request timeout duration.
  final Duration timeout;

  /// Number of retry attempts on 5xx or network errors.
  final int retries;

  /// Delay between retry attempts.
  final Duration backoff;

  /// Base directory for relative destination paths.
  final String? base;

  /// Counter of saved files.
  int count = 0;

  /// Creates a configured [HttpClient] session.
  HttpClient({
    http_lib.Client? client,
    Map<String, String>? headers,
    this.timeout = const Duration(seconds: 30),
    this.retries = 2,
    this.backoff = const Duration(milliseconds: 500),
    this.base,
  }) : _client = client ?? http_lib.Client(),
       _ownsClient = client == null,
       headers =
           headers ??
           {
             'User-Agent':
                 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                 '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
             'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
           };

  /// Sends an HTTP request with automatic retry and backoff (1-word).
  Future<HttpResponse> send(
    String method,
    Object url, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    final merged = Map<String, String>.from(this.headers);
    if (headers != null) merged.addAll(headers);

    var attempts = 0;
    final maxAttempts = retries > 0 ? retries + 1 : 1;
    final effectiveTimeout = timeout ?? this.timeout;

    while (true) {
      attempts++;
      final req = http_lib.Request(method, uri);
      req.headers.addAll(merged);

      if (body != null) {
        if (body is String) {
          req.body = body;
        } else if (body is List<int>) {
          req.bodyBytes = body;
        } else if (body is Map) {
          req.bodyFields = body.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }
      }

      try {
        final streamed = await _client.send(req).timeout(effectiveTimeout);
        final res = await http_lib.Response.fromStream(streamed);

        if ((res.statusCode >= 500 || res.statusCode == 429) &&
            attempts < maxAttempts) {
          await Future.delayed(backoff * attempts);
          continue;
        }

        return HttpResponse(
          url: uri,
          status: res.statusCode,
          headers: res.headers,
          bytes: res.bodyBytes,
        );
      } catch (e) {
        if (attempts < maxAttempts) {
          await Future.delayed(backoff * attempts);
          continue;
        }
        rethrow;
      }
    }
  }

  /// Performs an HTTP GET request (1-word).
  Future<HttpResponse> get(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => send('GET', url, headers: headers, timeout: timeout);

  /// Performs an HTTP POST request (1-word).
  Future<HttpResponse> post(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => send('POST', url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP PUT request (1-word).
  Future<HttpResponse> put(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => send('PUT', url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP DELETE request (1-word).
  Future<HttpResponse> delete(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => send('DELETE', url, headers: headers, timeout: timeout);

  /// Performs an HTTP PATCH request (1-word).
  Future<HttpResponse> patch(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => send('PATCH', url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP HEAD request (1-word).
  Future<HttpResponse> head(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => send('HEAD', url, headers: headers, timeout: timeout);

  /// Streams a remote file download directly to [dest] with atomic `.part` protection (1-word).
  Future<File> download(
    Object url,
    Object dest, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  }) async {
    final uri = url is Uri ? url : Uri.parse(url.toString());
    final file = _resolve(dest);
    if (Fs.has(file, match: match)) return file;

    final merged = Map<String, String>.from(this.headers);
    if (headers != null) merged.addAll(headers);

    var attempts = 0;
    final maxAttempts = retries > 0 ? retries + 1 : 1;

    while (true) {
      attempts++;
      try {
        final saved = await Fs.download(
          uri,
          file,
          client: _client,
          headers: merged,
          onProgress: onProgress,
          part: part,
        );
        count++;
        return saved;
      } catch (e) {
        if (attempts < maxAttempts) {
          await Future.delayed(backoff * attempts);
          continue;
        }
        rethrow;
      }
    }
  }

  /// Checks whether a local asset already exists and is non-empty (1-word).
  bool has(Object target, {bool match = true}) =>
      Fs.has(_resolve(target), match: match);

  /// Concurrently synchronizes a collection of download tasks into local files (1-word).
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
    await pool.run(entries, (t) => download(t.url, t.path, match: match));
  }

  /// Closes underlying HTTP client connections (1-word).
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }

  File _resolve(Object pathOrFile) {
    if (pathOrFile is File) return pathOrFile;
    final pStr = pathOrFile.toString();
    if (base != null && !pStr.startsWith(base!) && !File(pStr).isAbsolute) {
      return File('$base/$pStr');
    }
    return File(pStr);
  }
}

/// HTTP namespace accessor providing concise 1-word methods for web requests.
class HttpAccessor {
  final HttpClient _defaultClient = HttpClient();

  /// Creates an [HttpAccessor].
  HttpAccessor();

  /// Creates a configured [HttpClient] session with custom headers, timeout, or base folder (1-word).
  HttpClient client({
    http_lib.Client? client,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    int retries = 2,
    Duration backoff = const Duration(milliseconds: 500),
    String? base,
  }) => HttpClient(
    client: client,
    headers: headers,
    timeout: timeout,
    retries: retries,
    backoff: backoff,
    base: base,
  );

  /// Performs an HTTP GET request (1-word).
  Future<HttpResponse> get(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _defaultClient.get(url, headers: headers, timeout: timeout);

  /// Performs an HTTP POST request (1-word).
  Future<HttpResponse> post(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _defaultClient.post(url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP PUT request (1-word).
  Future<HttpResponse> put(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _defaultClient.put(url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP DELETE request (1-word).
  Future<HttpResponse> delete(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _defaultClient.delete(url, headers: headers, timeout: timeout);

  /// Performs an HTTP PATCH request (1-word).
  Future<HttpResponse> patch(
    Object url, {
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _defaultClient.patch(url, body: body, headers: headers, timeout: timeout);

  /// Performs an HTTP HEAD request (1-word).
  Future<HttpResponse> head(
    Object url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _defaultClient.head(url, headers: headers, timeout: timeout);

  /// Downloads a remote URL directly to [dest] with atomic `.part` protection (1-word).
  Future<File> download(
    Object url,
    Object dest, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  }) => _defaultClient.download(
    url,
    dest,
    headers: headers,
    onProgress: onProgress,
    part: part,
    match: match,
  );

  /// Concurrently synchronizes a collection of download tasks into local files (1-word).
  Future<void> sync(
    Object tasks, {
    String? prefix,
    String? base,
    int concurrency = 4,
    bool match = true,
  }) {
    final c = HttpClient(base: base);
    return c.sync(
      tasks,
      prefix: prefix,
      concurrency: concurrency,
      match: match,
    );
  }
}
