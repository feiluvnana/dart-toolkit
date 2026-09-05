import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../fs/fs.dart';
import 'downloader.dart';
import 'engine.dart';
import 'selector.dart';

// ============================================================================
// PIPELINE REQUEST, RESPONSE, SCHEDULER & ROUTER
// ============================================================================

/// HTTP request model representing a queued or in-flight crawl task.
class Request<T> {
  /// Target URI of the request.
  final Uri url;

  /// HTTP method (e.g. `GET`, `POST`, `HEAD`).
  final String method;

  /// Request HTTP headers.
  final Map<String, String> headers;

  /// Optional payload for POST or PUT requests.
  final Object? body;

  /// Priority score used by [Priority] scheduler. Higher values are dequeued earlier.
  final int priority;

  /// Routing tag used to map requests to specific `app.tag(...)` handlers.
  final String? tag;

  /// Arbitrary context metadata passed along with the request.
  final Map<String, dynamic> meta;

  /// Back-reference to the parent [Engine], if scheduled.
  Engine<T>? engine;

  /// Creates a [Request] instance.
  Request(
    dynamic url, {
    this.method = 'GET',
    Map<String, String>? headers,
    this.body,
    this.priority = 0,
    this.tag,
    Map<String, dynamic>? meta,
    this.engine,
  })  : url = url is Uri ? url : Uri.parse(url.toString()),
        headers = headers ?? {},
        meta = meta ?? {};

  /// Creates a GET request.
  factory Request.get(
    dynamic url, {
    Map<String, String>? headers,
    int priority = 0,
    String? tag,
    Map<String, dynamic>? meta,
  }) =>
      Request(
        url,
        method: 'GET',
        headers: headers,
        priority: priority,
        tag: tag,
        meta: meta,
      );

  /// Creates a POST request with an optional payload.
  factory Request.post(
    dynamic url, {
    Object? body,
    Map<String, String>? headers,
    int priority = 0,
    String? tag,
    Map<String, dynamic>? meta,
  }) =>
      Request(
        url,
        method: 'POST',
        body: body,
        headers: headers,
        priority: priority,
        tag: tag,
        meta: meta,
      );

  @override
  String toString() => '$method $url';
}

/// HTTP response received from downloading a [Request].
///
/// Provides HTML parsing, jQuery-like selection, relative URL resolution,
/// JSON deserialization, and pipeline flow controls (`follow`, `emit`, `save`, `stop`).
class Response<T> {
  /// The originating request.
  final Request<T> request;

  /// HTTP status code (e.g. 200, 404, 500).
  final int status;

  /// HTTP response headers.
  final Map<String, String> headers;

  /// Raw response payload bytes.
  final List<int> bytes;

  /// Reference to the active [Engine].
  Engine<T>? engine;

  String? _body;
  Document? _doc;

  /// Creates a [Response] instance.
  Response({
    required this.request,
    this.status = 200,
    Map<String, String>? headers,
    List<int>? bytes,
    this.engine,
  })  : headers = headers ?? {},
        bytes = bytes ?? const [];

  /// Whether the response status code indicates success (200..299).
  bool get ok => status >= 200 && status < 300;

  /// Decodes [bytes] as a UTF-8 string with malformed character tolerance.
  String get body => _body ??= utf8.decode(bytes, allowMalformed: true);

  /// Deserializes [body] as JSON.
  dynamic get json => jsonDecode(body);

  /// Lazily parses [body] into an HTML [Document].
  Document get doc => _doc ??= html_parser.parse(body);

  /// Queries the parsed HTML document using a CSS selector.
  ///
  /// Returns a chainable [QueryResult] wrapping matched elements:
  /// ```dart
  /// final titles = res.$('h2.title').texts;
  /// ```
  QueryResult $(String selector) => QueryResult(doc.querySelectorAll(selector));

  /// Finds the first matching absolute URL from `<a>`, `<link>`, or `<area>` tags.
  String? link([Pattern? filter]) => links(filter).firstOrNull;

  /// Extracts all absolute URLs from `<a>`, `<link>`, and `<area>` tags, optionally filtered.
  List<String> links([Pattern? filter]) {
    final raw = QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')]).links(filter);
    return raw.map((h) => request.url.resolve(h).toString()).toList();
  }

  /// Finds the first matching absolute source URL from `<img>`, `<audio>`, `<video>`, `<source>`, or `<script>` tags.
  String? src([Pattern? filter]) => srcs(filter).firstOrNull;

  /// Extracts all absolute source URLs from media and script tags, optionally filtered.
  List<String> srcs([Pattern? filter]) {
    final raw = QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')]).srcs(filter);
    return raw.map((s) => request.url.resolve(s).toString()).toList();
  }

  /// Target URL of the request.
  Uri get url => request.url;

  /// Request metadata payload.
  Map<String, dynamic> get meta => request.meta;

  /// Request routing tag.
  String? get tag => request.tag;

  /// Downloader component associated with this response's crawl engine.
  Downloader<T>? get dl => engine?.dl;

  /// Extracts non-empty text lines from the document body, stripping HTML tags and splitting on breaks.
  List<String> get lines => QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')]).lines;

  /// Emits an item to the crawler engine stream.
  void emit(T item) {
    if (engine == null) throw StateError('No engine attached to this response');
    engine!.emit(item);
  }

  /// Adds a new URL or [Request] to the crawler engine queue.
  void add(dynamic urlOrReq) {
    if (engine == null) throw StateError('No engine attached to this response');
    engine!.add(urlOrReq);
  }

  /// Resolves [url] against the current response URL and schedules a GET request.
  ///
  /// ```dart
  /// res.follow('/next-page', tag: 'listing');
  /// ```
  void follow(
    dynamic url, {
    String? tag,
    Map<String, dynamic>? meta,
    int priority = 0,
  }) {
    if (engine == null) throw StateError('No engine attached to this response');
    final target = url is Uri ? url : request.url.resolve(url.toString());
    engine!.add(Request<T>.get(target, tag: tag, meta: meta, priority: priority));
  }

  /// Signals the crawler engine to stop processing further requests.
  void stop([String reason = 'Stopped']) => engine?.stop(reason);

  /// Saves downloaded content to a local file path.
  ///
  /// If [sourceUrl] is provided, downloads the asset from [sourceUrl] (resolved against
  /// the current response URL) directly to [filePath].
  /// Otherwise, writes the response's own [bytes] to [filePath].
  /// Uses atomic `.part` writing and skips already existing files.
  ///
  /// ```dart
  /// await res.save('covers/album.jpg', res.$('img.cover').src());
  /// ```
  Future<void> save(
    dynamic filePath, [
    dynamic sourceUrl,
    String part = '.part',
  ]) async {
    if (sourceUrl != null) {
      final resolved = request.url.resolve(sourceUrl.toString());
      if (engine != null) {
        await engine!.downloader.save(filePath, resolved, part: part);
      } else {
        await Fs.download(resolved, filePath is File ? filePath : File(filePath.toString()), part: part);
      }
    } else {
      final file = filePath is File ? filePath : File(filePath.toString());
      await Fs.write(file, bytes, part: part);
    }
  }

  @override
  String toString() => '$status ${request.url} (${bytes.length} bytes)';
}

/// Request scheduler queue with built-in deduplication and optional priority sorting.
class Scheduler<T> {
  final List<Request<T>> _queue = [];
  final Set<String> _visited = <String>{};

  /// Whether identical URLs should be automatically ignored after being scheduled once.
  final bool dedupe;

  /// Whether requests are ordered by [Request.priority] descending.
  final bool priority;

  /// Back-reference to the parent [Engine].
  Engine<T>? engine;

  /// Creates a [Scheduler].
  Scheduler({this.dedupe = true, this.priority = false});

  /// Binds the scheduler to a parent [Engine].
  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  /// Adds a URL or [Request] to the schedule queue if not already visited.
  void add(dynamic requestOrUrl) {
    final req = requestOrUrl is Request<T>
        ? requestOrUrl
        : Request<T>.get(requestOrUrl);

    final key = '${req.method}:${_norm(req.url)}';
    if (!dedupe || _visited.add(key)) {
      if (engine != null) {
        req.engine = engine;
      }
      _queue.add(req);
      if (priority && _queue.length > 1) {
        _queue.sort((a, b) => b.priority.compareTo(a.priority));
      }
    }
  }

  /// Pops and returns the next pending request, or `null` if the queue is empty.
  Request<T>? next() {
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }

  /// Number of pending requests currently queued.
  int get length => _queue.length;

  /// Whether the queue is currently empty.
  bool get isEmpty => _queue.isEmpty;

  /// Whether the queue contains pending requests.
  bool get isNotEmpty => _queue.isNotEmpty;

  /// Clears all pending requests from the queue.
  void clear() => _queue.clear();

  /// Clears the history of visited URLs, allowing previously scheduled URLs to be queued again.
  void reset() => _visited.clear();

  static String _norm(Uri uri) {
    final n = uri.removeFragment();
    var p = n.path;
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return n.replace(path: p).toString();
  }
}

/// A priority-based [Scheduler] where requests with higher [Request.priority] are dequeued first.
class Priority<T> extends Scheduler<T> {
  /// Creates a priority scheduler.
  Priority({super.dedupe = true}) : super(priority: true);
}

/// Handler signature for processing crawler responses.
typedef Process<T> = FutureOr<void> Function(
  Response<T> response,
  Engine<T> engine,
);

/// Declarative response router matching requests by URL patterns, tags, or status codes.
class Router<T> {
  final List<_Rule<T>> _rules = [];
  Process<T>? _fallback;

  /// Back-reference to the parent [Engine].
  Engine<T>? engine;

  /// Binds the router to an [Engine].
  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  /// Whether the router contains any matching rules or a fallback handler.
  bool get isNotEmpty => _rules.isNotEmpty || _fallback != null;

  /// Whether the router is completely empty.
  bool get isEmpty => !isNotEmpty;

  /// Number of defined routing rules.
  int get length => _rules.length;

  /// Registers a route matching URL string patterns or regular expressions.
  ///
  /// ```dart
  /// router.on(RegExp(r'/item/\d+'), (res, app) async {
  ///   ...
  /// });
  /// ```
  Router<T> on(Pattern pattern, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) => pattern.allMatches(res.request.url.toString()).isNotEmpty,
        handler: handler,
      ),
    );
    return this;
  }

  /// Registers a route matching requests scheduled with [name] as their tag.
  ///
  /// ```dart
  /// router.tag('profile', (res, app) async {
  ///   ...
  /// });
  /// ```
  Router<T> tag(String name, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) => res.request.tag == name,
        handler: handler,
      ),
    );
    return this;
  }

  /// Registers a route matching a specific HTTP response [code].
  ///
  /// ```dart
  /// router.status(404, (res, app) => print('Page not found: ${res.url}'));
  /// ```
  Router<T> status(int code, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) => res.status == code,
        handler: handler,
      ),
    );
    return this;
  }

  /// Registers a default fallback handler invoked when no rules match the response.
  Router<T> fallback(Process<T> handler) {
    _fallback = handler;
    return this;
  }

  /// Evaluates routing rules against [response] and invokes the first matching handler.
  /// Returns `true` if a matching rule or explicit fallback handled the response, `false` otherwise.
  Future<bool> handle(Response<T> response, Engine<T> engine) async {
    for (final rule in _rules) {
      if (rule.test(response)) {
        await rule.handler(response, engine);
        return true;
      }
    }
    if (_fallback != null) {
      await _fallback!(response, engine);
      return true;
    }
    return false;
  }

  /// Evaluates routing rules against [response] and invokes the first matching handler.
  Future<void> call(Response<T> response, Engine<T> engine) async {
    await handle(response, engine);
  }
}

class _Rule<T> {
  final bool Function(Response<T> res) test;
  final Process<T> handler;

  _Rule({required this.test, required this.handler});
}
